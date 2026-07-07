-module(ddt_tracer).

-include("ddtrace.hrl").

-export([ init/1
        , stop/1
        , handle_trace/2
        ]).

-record(state, 
    { worker_pid :: pid()
    , trace_session :: term()
    , requests = #{} :: map()
    , lock :: gen_server:request_id() | undefined
    }).

-opaque state() :: #state{}.
-export_type([state/0]).

%%%======================
%%% Public API
%%%======================

-spec init(pid()) -> state().
init(WorkerPid) ->
    TraceSession = init_trace(WorkerPid),
    #state{worker_pid = WorkerPid, trace_session = TraceSession, lock = undefined}.

-spec stop(state()) -> ok.
stop(#state{trace_session = TraceSession}) ->
    trace:session_destroy(TraceSession),
    ok.

%% @doc Parses a raw trace and returns a list of internal events to queue, plus updated state.
-spec handle_trace(tuple(), state()) -> {[tuple()], state()}.

%% Casts are ignored. This needs to be explicit, otherwise we get a match with
%% call responses.
handle_trace({trace, _Worker, 'receive', {'$gen_cast', _}}, State) ->
    {[], State};
handle_trace({trace, _Worker, 'send', {'$gen_cast', _}, _To}, State) ->
    {[], State};

%% Send query (we are the sender)
handle_trace({trace, _Worker, 'send', ?GS_CALL(RawReqId), To}, State = #state{requests = Requests}) ->
    ReqId = strip_alias(RawReqId),
    ?DDT_DBG_TRACER("~p: '|->' sent call ~p (Locked!)", [State#state.worker_pid, ReqId]),
    %% Save the target PID so we can check its monitor status later
    State1 = State#state{requests = Requests#{ReqId => To}, lock = ReqId},
    {[?SEND_INFO(To, ?QUERY_INFO(ReqId))], State1};

%% Send response (alias-based) - lookup the actual destination PID from requests map
handle_trace({trace, _Worker, 'send', ?GS_RESP_ALIAS_MSG(ReqId, _Msg), _AliasRef}, State = #state{requests = Requests}) ->
    ?DDT_DBG_TRACER("~p: '<-|' sent response ~p)", [State#state.worker_pid, ReqId]),
    case maps:get(ReqId, Requests, undefined) of
        undefined ->
            {[], State};
        ToPid ->
            State1 = State#state{requests = maps:remove(ReqId, Requests)},
            {[?SEND_INFO(ToPid, ?RESP_INFO(ReqId))], State1}
    end;

%% Send response (plain ReqId)
handle_trace({trace, _Worker, 'send', ?GS_RESP(RawReqId), To}, State = #state{requests = Requests}) ->
    ReqId = strip_alias(RawReqId),
    ?DDT_DBG_TRACER("~p: '<-|' sent reply ~p", [State#state.worker_pid, ReqId]),
    State1 = State#state{requests = maps:remove(ReqId, Requests)},
    {[?SEND_INFO(To, ?RESP_INFO(ReqId))], State1};

%% Receive query (we are the receiver) - store the sender for later reply lookup
handle_trace({trace, _Worker, 'receive', ?GS_CALL_FROM(From, RawReqId)}, State = #state{requests = Requests}) ->
    ReqId = strip_alias(RawReqId),
    ?DDT_DBG_TRACER("~p: '->|' received call ~p", [State#state.worker_pid, ReqId]),
    %% Store the sender's PID for later reply destination lookup
    State1 = State#state{requests = Requests#{ReqId => From}},
    
    %% If the sender is unmonitored, fake a herald
    Events = case mon_reg:mon_of(From) of
        undefined -> [?HERALD(From, ?QUERY_INFO(ReqId)), ?RECV_INFO(?QUERY_INFO(ReqId))];
        _ -> [?RECV_INFO(?QUERY_INFO(ReqId))]
    end,
    {Events, State1};

%% Receive response (alias-based) - preserve the full [alias|ReqId] format
handle_trace({trace, _Worker, 'receive', ?GS_RESP_ALIAS_MSG(ReqId, _Msg)}, State) ->
    resolve_recv_response(?RECV_INFO(?RESP_INFO(ReqId)), ReqId, State);

%% Receive response (plain ReqId)
handle_trace({trace, _Worker, 'receive', ?GS_RESP(RawReqId)}, State) ->
    ReqId = strip_alias(RawReqId),
    resolve_recv_response(?RECV_INFO(?RESP_INFO(ReqId)), ReqId, State);

%% Call exception - we treat it as a call timeout, which is what the gen_server would do.
%% This is important to unstuck the state machine when the server handles the timeout without crashing.
handle_trace({trace, _Worker, 'exception_from', {_, call, _}, {exit, {timeout, _}}},
             State = #state{lock = ReqId, requests = Requests}) when ReqId =/= undefined ->
    ?DDT_DBG_TRACER("~p: '|??' call timed out ~p (Unlocked!)", [_Worker, ReqId]),
    To = maps:get(ReqId, Requests),
    State1 = State#state{requests = maps:remove(ReqId, Requests), lock = undefined},
    {[?TIMEOUT_SEND(To, ReqId)], State1};

%% The gen_server is either gonna crash or handle this somehow. It definitely
%% won't change its SRPC state.
handle_trace({trace, Worker, 'send_to_non_existing_process', _, To}, State) ->
    logger:warning("~p: send_to_non_existing_process (~p) trace ignored", [Worker, To], #{module => ?MODULE, subsystem => ddtrace}),
    {[], State};

%% Other traces are ignored
handle_trace(Trace, State) when element(1, Trace) =:= trace ->
    % Currently known frequently ignored trace is return_from that is deeply tied to exception handling                                             
    {[], State};

%% We postpone unexpected events naively trusting that no one is trolling us.
handle_trace(_Trace, State) ->
    logger:warning("~p: Received unexpected trace ~p, discarding(!)", [State#state.worker_pid, _Trace], #{module => ?MODULE, subsystem => ddtrace}),
    {[], State}.

%%%======================
%%% Internal Helpers
%%%======================

strip_alias([alias | ReqId]) -> ReqId;
strip_alias(ReqId) -> ReqId.

init_trace(WorkerPid) ->
    TraceOpts = ['send', 'receive', 'call'],
    TracingSession = trace:session_create(deadlock_tracer, self(), []),
    trace:process(TracingSession, WorkerPid, true, TraceOpts),
    
    % Trace sent calls and responses (to sent calls)
    trace:send(
      TracingSession,
      [ {['_', {'$gen_call', '_', '_'}], [], []} % gen_server call
      , {['_', {['alias' | '$1'], '_'}], [{is_reference, '$1'}], []}
      , {['_', {'$1', '_'}], [{is_reference, '$1'}], []}
      ],
      []
     ),

    % Trace received calls and replies (to received calls)
    trace:recv(
      TracingSession,
      [ {['_', '_', {'$gen_call', '_', '_'}], [], []} % gen_server call
      , {['_', '_', {['alias' | '$1'], '_'}], [{is_reference, '$1'}], []}
      , {['_', '_', {'$1', '_'}], [{is_reference, '$1'}], []}
      ],
      []
     ),
    
    % Trace call exceptions to detect crashes during call handling. We need this because if a gen_server crashes
    % while handling a call, we won't see the response trace, but we can still infer that the call failed.
    trace:function(
      TracingSession,
      {gen_server, call, '_'},
      [ {'_', [], [{message, false}, {exception_trace}]} ],
      []
     ),
    trace:function(
      TracingSession,
      {gen_statem, call, '_'},
      [ {'_', [], [{message, false}, {exception_trace}]} ],
      []
     ),

    trace:function(
      TracingSession,
      {'Elixir.GenServer', call, '_'},
      [ {'_', [], [{message, false}, {exception_trace}]} ],
      []
     ),
    trace:function(
      TracingSession,
      {'Elixir.GenStateMachine', call, '_'},
      [ {'_', [], [{message, false}, {exception_trace}]} ],
      []
     ),

    TracingSession.

resolve_recv_response(Ev, ReqId, State = #state{requests = Requests}) ->
    ?DDT_DBG_TRACER("~p: '|<-'received response ~p (Unlocked!)", [State#state.worker_pid, ReqId]),

    case maps:get(ReqId, Requests, undefined) of
        undefined ->
            {[], State#state{lock = undefined}};
        To ->
            State1 = State#state{requests = maps:remove(ReqId, Requests), lock = undefined},
            %% If the sender of the response is unmonitored, fake a herald
            Events = case mon_reg:mon_of(To) of
                undefined -> [?HERALD(To, ?RESP_INFO(ReqId)), Ev];
                _ -> [Ev]
            end,
            {Events, State1}
    end.
