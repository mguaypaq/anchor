-module(anchor).
-include("anchor.hrl").

-export([
    get/1,
    get/2,
    set/2,
    set/3,
    set/4,
    start_link/0
]).

-behaviour(gen_server).
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    code_change/3,
    terminate/2
]).

-record(state, {
    ip          = undefined,
    port        = undefined,
    socket      = undefined,
    queue       = queue:new(),
    req_counter = 0,
    buffer      = <<>>,
    from        = undefined,
    response    = undefined
}).

%% public
-spec get(binary()) -> {ok, binary()} | {error, atom()}.
get(Key) ->
    get(Key, ?TIMEOUT).

-spec get(binary(), pos_integer()) -> {ok, binary()} | {error, atom()}.
get(Key, Timeout) ->
    case call({get, Key}, Timeout) of
        {ok, Resp} ->
            case Resp#response.status of
                0 ->
                    {ok, Resp#response.value};
                _ ->
                    {error, not_found}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

-spec set(binary(), binary()) -> ok | {error, atom()}.
set(Key, Value) ->
    set(Key, Value, ?TTL).

-spec set(binary(), binary(), non_neg_integer()) -> ok | {error, atom()}.
set(Key, Value, TTL) ->
    set(Key, Value, TTL, ?TIMEOUT).

-spec set(binary(), binary(), non_neg_integer(), pos_integer()) -> ok | {error, atom()}.
set(Key, Value, TTL, Timeout) ->
    case call({set, Key, Value, TTL}, Timeout) of
        {ok, _Resp} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% gen_server callbacks
init([]) ->
    Ip = application:get_env(?MODULE, ip, ?DEFAULT_IP),
    Port = application:get_env(?MODULE, port, ?DEFAULT_PORT),

    self() ! newsocket,

    {ok, #state {
        ip = Ip,
        port = Port
    }}.

handle_call(_Request, _From, #state{
        socket = undefined
    } = State) ->

    {reply, {error, no_socket}, State};
handle_call(Request, From, #state {
        socket = Socket,
        queue = Queue,
        req_counter = ReqCounter
    } = State) ->

    ReqId = (ReqCounter + 1) rem ?MAX_32_BIT_INT,
    {ok, Packet} = anchor_protocol:generate(ReqId, Request),
    case gen_tcp:send(Socket, Packet) of
        {error, Reason} ->
            error_msg("tcp send error: ~p", [Reason]),
            gen_tcp:close(Socket),
            reply_all(Queue, {error, tcp_closed}),
            {reply, {error, Reason}, State#state {
                socket = undefined,
                queue = queue:new(),
                buffer = <<>>,
                from = undefined,
                response = undefined
            }};
        ok ->
            {noreply, State#state {
                queue = queue:in({ReqId, From}, Queue),
                req_counter = ReqCounter + 1
            }}
    end;
handle_call(Call, _From, State) ->
    warning_msg("unexpected call: ~p~n", [Call]),
    {noreply, State}.

handle_cast(Cast, State) ->
    warning_msg("unexpected cast: ~p~n", [Cast]),
    {noreply, State}.

handle_info(newsocket, #state {
        ip = Ip,
        port = Port
    } = State) ->

    Opts = [binary, {active, once}, {packet, raw}],
    case gen_tcp:connect(Ip, Port, Opts) of
        {ok, Socket} ->
            {noreply, State#state {
                socket = Socket
            }};
        {error, Reason} ->
            error_msg("tcp connect error: ~p", [Reason]),
            erlang:send_after(?RECONNECT_AFTER, self(), newsocket),
            {noreply, State}
    end;
handle_info({tcp, Socket, Data}, #state {
        socket = Socket,
        buffer = Buffer
    } = State) ->

    inet:setopts(Socket, [{active, once}]),
    loop_data(<<Buffer/binary, Data/binary>>, State);
handle_info({tcp_closed, Socket}, #state {
        socket = Socket,
        queue = Queue
    } = State) ->

    reply_all(Queue, {error, tcp_closed}),
    {noreply, State#state {
        socket = undefined,
        queue = queue:new(),
        buffer = <<>>,
        from = undefined,
        response = undefined
    }};
handle_info({tcp_error, Socket, Reason}, #state {
        socket = Socket
    } = State) ->

    error_msg("tcp error: ~p", [Reason]),
    {noreply, State};
handle_info(Info, State) ->
    warning_msg("unexpected info: ~p~n", [Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, _State) ->
    ok.

%% private
call(Msg, Timeout) ->
    try gen_server:call(?MODULE, Msg, Timeout) of
        Reply ->
            Reply
    catch
        exit:{noproc, _} ->
            {error, not_started};
        exit:{timeout, _} ->
            {error, timeout}
    end.

loop_data(<<>>, State) ->
    {noreply, State};
loop_data(Data, #state {
        queue = Queue,
        from = undefined
    } = State) ->

    case queue:out(Queue) of
        {{value, {ReqId, From}}, Queue2} ->
            {ok, Rest, Resp} = anchor_protocol:parse(ReqId, Data, #response {}),
            case Resp#response.extras of
                undefined ->
                    {noreply, State#state {
                        queue = Queue2,
                        buffer = Rest,
                        from = From,
                        response = Resp#response {
                            opaque = ReqId
                        }
                    }};
                _Extras ->
                    reply(From, {ok, Resp}),
                    loop_data(Rest, State#state {
                        queue = Queue2,
                        buffer = <<>>
                    })
            end;
        {empty, Queue} ->
            warning_msg("empty queue", []),
            {noreply, State}
    end;
loop_data(Data, #state {
        from = From,
        response = #response {
            opaque = ReqId
        } = Resp
    } = State) ->

    {ok, Rest, Resp2} = anchor_protocol:parse(ReqId, Data, Resp),
    case Resp2#response.extras of
        undefined ->
            {noreply, State#state {
                buffer = Rest,
                response = Resp2
            }};
        _Extras ->
            reply(From, {ok, Resp2}),
            loop_data(Rest, State#state {
                from = undefined,
                buffer = <<>>,
                response = undefined
            })
    end.

reply(From, Msg) ->
    gen_server:reply(From, Msg).

reply_all(Queue, Msg) ->
    [gen_server:reply(From, Msg) || From <- queue:to_list(Queue)].

%% logging
error_msg(Format, Data) ->
    error_logger:error_msg(Format, Data).

warning_msg(Format, Data) ->
    error_logger:warning_msg(Format, Data).
