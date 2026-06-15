-module(gs_tracer).

-behaviour(gen_server).

-include("ddtrace.hrl").

-export([start_link/2]).
-export([init/1, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2, handle_continue/2]).

start_link(Worker, WorkerPid) ->
    gen_server:start_link(?MODULE, {Worker, WorkerPid}, []).

init({Worker, WorkerPid}) ->
    process_flag(priority, ?PROCESS_PRIORITY),

    TraceSession = init_trace(WorkerPid),
    process_flag(trap_exit, true),
    erlang:monitor(process, WorkerPid),

    Monitor = mon_reg:mon_of(Worker),

    State = 
     #{worker => Worker,
       worker_pid => WorkerPid,
       monitor => Monitor,
       trace_session => TraceSession,
       requests => #{},
       lock => undefined
      },
    {ok, State}.

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

terminate(_Reason, State) ->
    stop_tracing(State),
    ok.

%%%======================
%%% handle_call: Stop tracer
%%%======================

%% Stop tracer
handle_call(stop, From, State) ->
    stop_tracing(State),
    {reply, From, State}.

%%%======================
%%% handle_cast: Ignore
%%%======================

handle_cast(_Msg, State) ->
    {noreply, State}.

%%%======================
%%% handle_info: Process exit
%%%======================

handle_info({'DOWN', _Ref, process, _Pid, _Reason}, State) ->
    stop_tracing(State),
    {noreply, State};

%% Catch exit signals from linked processes (i.e., the parent ddtrace orchestrator)
handle_info({'EXIT', _ParentPid, Reason}, _State) ->
    {stop, Reason};

%%%======================
%%% handle_info: Translating traces to RPC events
%%%======================

%% Casts are ignored. This needs to be explicit, otherwise we get a match with
%% call responses.
handle_info({trace, _Worker, 'receive', {'$gen_cast', _}}, State) ->
    {noreply, State};
handle_info({trace, _Worker, 'send', {'$gen_cast', _}, _To}, State) ->
    {noreply, State};

%% Send query (we are the sender)
handle_info({trace, _Worker, 'send', ?GS_CALL(ReqId), To}, State) ->
    %% Save the target PID so we can check its monitor status later
    #{requests := Requests} = State,
    State1 = State#{requests => Requests#{ReqId => To}},

    {noreply, State1, {continue, ?SEND_INFO(To, ?QUERY_INFO(ReqId))}};

%% Send response (alias-based) - lookup the actual destination PID from requests map
handle_info({trace, _Worker, 'send', ?GS_RESP_ALIAS_MSG(ReqId, _Msg), _AliasRef}, State) ->
    #{requests := Requests} = State,
    case maps:get([alias|ReqId], Requests, undefined) of
        undefined ->
            {noreply, State};
        ToPid ->
            {noreply, State, {continue, ?SEND_INFO(ToPid, ?RESP_INFO([alias|ReqId]))}}
    end;

%% Send response (plain ReqId)
handle_info({trace, _Worker, 'send', ?GS_RESP(ReqId), To}, State) ->
    {noreply, State, {continue, ?SEND_INFO(To, ?RESP_INFO(ReqId))}};

%% Receive query (we are the receiver) - store the sender for later reply lookup
handle_info({trace, _Worker, 'receive', ?GS_CALL_FROM(From, ReqId)}, State) ->
    %% Store the sender's PID for later reply destination lookup
    #{ requests   := Requests,
       worker_pid := _WorkerPid
     } = State,
    State1 = State#{requests => Requests#{ReqId => From}},
    
    case mon_reg:mon_of(From) of
        undefined ->
            %% If the sender is not being monitored, we fake monitor herald
            ?DDT_DBG_HERALD("~p: Injecting fake herald for unmonitored sender (~p)", [_WorkerPid, From]),
            FakeNotif = ?HERALD(From, ?QUERY_INFO(ReqId)),
            Monitor = maps:get(monitor, State),
            gen_statem:cast(Monitor, FakeNotif);
        _Pid -> ok
    end,
    
    %% Trigger state refresh to retry postponed events
    {noreply, State1, {continue, ?RECV_INFO(?QUERY_INFO(ReqId))}};

%% Receive response (alias-based) - preserve the full [alias|ReqId] format
handle_info({trace, _Worker, 'receive', ?GS_RESP_ALIAS_MSG(ReqId, _Msg)}, State) ->
    %% Keep the full [alias|ReqId] format for state matching
    {noreply, State, {continue, ?RECV_INFO(?RESP_INFO([alias|ReqId]))}};

%% Receive response (plain ReqId)
handle_info({trace, _Worker, 'receive', ?GS_RESP(ReqId)}, State) ->
    {noreply, State, {continue, ?RECV_INFO(?RESP_INFO(ReqId))}};

%% The gen_server is either gonna crash or handle this somehow. It definitely
%% won't change its SRPC state.
handle_info({trace, Worker, 'send_to_non_existing_process', _, To}, State) ->
    logger:warning("~p: send_to_non_existing_process (~p) trace ignored", [Worker, To], #{module => ?MODULE, subsystem => ddtrace}),
    {noreply, State};

%% Call exception - we treat it as a call timeout, which is what the gen_server would do.
%% This is important to unstuck the state machine when the server handles the timeout without crashing.
handle_info({trace, _Worker, 'exception_from', {_, call, _}, {exit, {timeout, _}}}, State = #{lock := ReqId}) ->
    ?DDT_DBG_TRACER("~p: Unlocked! (Request ~p timed out)", [_Worker, ReqId]),
    #{requests := Requests} = State,

    To = maps:get(ReqId, Requests),
    gen_statem:cast(maps:get(monitor, State), ?TIMEOUT_SEND(To, ReqId)),

    State1 = State#{requests => maps:remove(ReqId, Requests), lock => undefined},
    {noreply, State1};

%% Other traces are ignored
handle_info(Trace, State) when element(1, Trace) =:= trace ->
    % Currently known frequently ignored trace is return_from that is deeply tied to exception handling                                             
    {noreply, State};

%% We postpone unexpected events naively trusting that no one is trolling us.
handle_info(_Trace, State) ->
    logger:warning("~p: Received unexpected trace ~p, discarding(!)", [maps:get(worker_pid, State), _Trace], #{module => ?MODULE, subsystem => ddtrace}),
    {noreply, State}.

%%%======================
%%% handle_continue: Further trace processing
%%%======================

%% Send query
handle_continue(Ev = ?SEND_INFO(_To, ?QUERY_INFO(ReqId)), State) ->
    ?DDT_DBG_TRACER("~p: Locked! (Sending request ~p)", [maps:get(worker_pid, State), ReqId]),
    gen_statem:cast(maps:get(monitor, State), Ev),
    {noreply, State#{lock => ReqId}};

%% Send response
handle_continue(Ev = ?SEND_INFO(_To, ?RESP_INFO(ReqId)), State) ->
    #{requests := Requests} = State,
    case maps:get(ReqId, Requests, undefined) of
        undefined -> 
            {noreply, State};
        _ ->
            gen_statem:cast(maps:get(monitor, State), Ev),
            State1 = State#{requests => maps:remove(ReqId, Requests)},
            {noreply, State1}
    end;

%% Receive query
handle_continue(Ev = ?RECV_INFO(?QUERY_INFO(_ReqId)), State) ->
    gen_statem:cast(maps:get(monitor, State), Ev),
    {noreply, State};

%% Receive response (alias-based)
handle_continue(Ev = ?RECV_INFO(?RESP_INFO([alias|ReqId])), State = #{lock := ReqId}) ->
    handle_recv_response(Ev, ReqId, State#{lock => undefined});

%% Receive response (standard)
handle_continue(Ev = ?RECV_INFO(?RESP_INFO(ReqId)), State = #{lock := ReqId}) ->
    handle_recv_response(Ev, ReqId, State#{lock => undefined});

%% Receive response (not matching the lock)
handle_continue(Ev = ?RECV_INFO(?RESP_INFO(ReqId)), State) ->
    % logger:warning(
    %     "~p: Received unexpected response ~p! (ReqId does not match lock! This is either an unsupported multi_call or another unexpected function)",
    %     [maps:get(worker_pid, State), Ev],
    %     #{module => ?MODULE, subsystem => ddtrace}
    % ),
    handle_recv_response(Ev, ReqId, State).

%%%======================
%%% Internal functions
%%%======================

handle_recv_response(Ev, ReqId, State) ->
    #{ monitor    := Monitor,
       requests   := Requests,
       worker_pid := _WorkerPid
     } = State,
    ?DDT_DBG_TRACER("~p: Unlocked! (Got response for request ~p)", [_WorkerPid, ReqId]),

    case maps:get(ReqId, Requests, undefined) of
        undefined ->
            {noreply, State};
        To ->
            gen_statem:cast(Monitor, Ev),
            %% Clean up our 'send' request 
            State1 = State#{requests => maps:remove(ReqId, Requests)},
            %% If the receiver is not being monitored, we fake monitor herald
            case mon_reg:mon_of(To) of
                undefined ->
                    ?DDT_DBG_HERALD("~p: Injecting fake herald for unmonitored receiver (~p)", [_WorkerPid, To]),
                    FakeNotif = ?HERALD(To, ?RESP_INFO(ReqId)),
                    gen_statem:cast(Monitor, FakeNotif);
                _MonPid -> ok
            end,
            {noreply, State1}
    end.

stop_tracing(State) ->
    #{trace_session := TraceSession} = State,
    trace:session_destroy(TraceSession),
    ok.

