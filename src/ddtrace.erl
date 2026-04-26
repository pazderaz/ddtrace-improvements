-module(ddtrace).
-behaviour(gen_statem).

-include("ddtrace.hrl").

%% API
-export([ start/1, start/2, start/3
        , start_link/1, start_link/2, start_link/3
        ]).

%% gen_statem callbacks
-export([init/1, callback_mode/0]).
-export([terminate/2,terminate/3]).

-export([handle_event/4]).

%% DDTrace API
-export([subscribe_deadlocks/1, unsubscribe_deadlocks/1, stop_tracer/1]).

%%%======================
%%% Types
%%%======================

-type process_name() ::
        pid()
      | atom()
      | {global, term()}
      | {via, module(), term()}.

-record(data,
    { worker               :: process_name() % the traced worker process (name/global/pid)
    , worker_pid           :: pid()          % the resolved PID for tracing
    , erl_monitor          :: reference()    % the Erlang monitor reference
    , mon_state            :: process_name() % the process holding the monitor state
    , tracer               :: process_name() % the srpc_tracer process
    %% Queue and map data structures for efficient herald-trace matching.
    , message_q            :: queue:queue()  % queue of messages to be processed upon syncing
    , message_map          :: map()          % map of queued messages by ReqId
    , sync_timeout         :: non_neg_integer() % timeout for waiting for synchronisation (matching RECV with herald)
    , sync_timeout_panic   :: non_neg_integer() % additive timeout for triggering panic and stopping the tracer
    }).


%%%======================
%%% API Functions
%%%======================

start(Worker) ->
    start(Worker, [], []).
start(Worker, Opts) ->
    start(Worker, Opts, []).
start(Worker, Opts, GenOpts) ->
    gen_statem:start(?MODULE, {Worker, Opts}, GenOpts).

start_link(Worker) ->
    start_link(Worker, [], []).
start_link(Worker, Opts) ->
    start_link(Worker, Opts, []).
start_link(Worker, Opts, GenOpts) ->
    gen_statem:start_link(?MODULE, {Worker, Opts}, GenOpts).

%%%======================
%%% gen_statem Callbacks
%%%======================

init({Worker, Opts}) ->
    process_flag(priority, low),
    process_flag(trap_exit, true),

    mon_reg:ensure_started(),

    TracerMod = proplists:get_value(tracer_mod, Opts, srpc_tracer),
    StateMod = proplists:get_value(state_mod, Opts, ddtrace_detector),
    
    %% Resolve worker to PID for Erlang monitoring and tracing
    WorkerPid = resolve_to_pid(Worker),
    ErlMon = erlang:monitor(process, WorkerPid),

    %% Register monitor under both the original name and the PID
    %% - Original name: for application-level lookups
    %% - PID: for trace-level lookups (trace events contain PIDs, not names)
    mon_reg:set_mon(Worker, self()),
    case Worker of
        WorkerPid -> ok;
        _ -> mon_reg:set_mon(WorkerPid, self())
    end,

    %% Start detector and tracer
    {ok, MonState} = StateMod:start_link(Worker),
    {ok, Tracer} = TracerMod:start_link(Worker, WorkerPid),

    %% First timeout that logs a warning that we're waiting unusually long for synchronisation (matching RECV with herald).
    SyncTimeout = proplists:get_value(sync_timeout, Opts, ?SYNC_TIMEOUT),
    %% Second timeout that triggers panic and stops the tracer to avoid potential performance issues if we're waiting for synchronisation for way too long.
    %% The total time until panic will be sync_timeout + sync_timeout_panic, so it should be set accordingly (e.g. panic timeout could be the same as the initial warning timeout).
    SyncTimeoutPanic = proplists:get_value(sync_timeout_panic, Opts, ?SYNC_TIMEOUT_PANIC),

    Data = #data{ worker = Worker
                , worker_pid = WorkerPid
                , erl_monitor = ErlMon
                , mon_state = MonState
                , tracer = Tracer
                , message_q = queue:new()
                , message_map = #{}
                , sync_timeout = SyncTimeout
                , sync_timeout_panic = SyncTimeoutPanic
                },

    {ok, ?synced, Data, []}.

callback_mode() ->
    %% We use `state_enter` to debug major state transitions via tracing. Leave
    %% it unless it causes performance issues.
    [handle_event_function, state_enter].

terminate(State, Data) ->
    terminate(shutdown, State, Data).
terminate(Reason, _State, Data) ->
    if Reason =:= normal; Reason =:= shutdown; element(1, Reason) =:= shutdown ->
            ok;
         true ->
            Worker = Data#data.worker,
            logger:error("~p: Monitored process ~p died abnormally: ~w", [self(), Worker, Reason], #{module => ?MODULE, subsystem => ddtrace})
    end,
    ErlMon = Data#data.erl_monitor,
    erlang:demonitor(ErlMon, [flush]),
    ok.

%%%======================
%%% handle_event: All-time interactions
%%%======================

%% Debug state transitions & set timeout when entering wait states.
handle_event(enter, _OldState, ?synced, _Data) ->
    ?DDT_DBG_STATE("[~p@~p] ~p -> synced", [_Data#data.worker, node(), _OldState]),
    keep_state_and_data;
handle_event(enter, _OldState, _NewState, Data) ->
    ?DDT_DBG_STATE("[~p@~p] ~p -> ~p", [Data#data.worker, node(), _OldState, _NewState]),
    TimeoutAction = {state_timeout, Data#data.sync_timeout, synchronisation},
    {keep_state_and_data, [TimeoutAction]};

handle_event(state_timeout, synchronisation, State, Data) ->
    {WaitingFor, MsgInfo} =
        case State of
            ?wait_mon(Info) -> {"herald", Info};
            ?wait_proc(_From, Info) -> {"own process", Info};
            ?wait_mon_proc(Info, _FromProc, _MsgInfoProc) -> {"herald (and own process)", Info}
        end,

    Worker = Data#data.worker,
    ?DDT_WARN_TIMEOUT("~p: Waiting for ~s too long (>~p ms): ~w", [Worker, WaitingFor, Data#data.sync_timeout, MsgInfo]),

    TimeoutAction = {state_timeout, Data#data.sync_timeout_panic, sync_panic},
    {keep_state_and_data, [TimeoutAction]};

%% We were waiting for way too long. Time to panic and stop the tracer to avoid potential performance issues.
handle_event(state_timeout, sync_panic, _State, Data) ->
    PanicTimeout = Data#data.sync_timeout + Data#data.sync_timeout_panic,
    ?DDT_WARN_TIMEOUT("~p: Synchronisation too long (>~p ms)! Crashing in panic!", [Data#data.worker, PanicTimeout]),
    unset_mon(Data),
    {stop, timeout_panic};

handle_event({call, From}, subscribe, _State, Data) ->
    cast_mon_state({subscribe, From}, Data),
    keep_state_and_data;

handle_event({call, From}, unsubscribe, _State, Data) ->
    cast_mon_state({unsubscribe, From}, Data),
    keep_state_and_data;

handle_event({call, From}, stop_tracer, _State, Data) ->
    %% Unregister from mon_reg before stopping
    unset_mon(Data),

    Tracer = Data#data.tracer,
    gen_statem:call(Tracer, stop),
    {keep_state_and_data, {reply, From, ok}};

%% The worker has attempted a call to itself. When this happens, no actual
%% message is sent. We fake the call message to "detect" the deadlock.
handle_event(info, {'DOWN', _ErlMon, process, Pid, {calling_self, _Reason}}, _State, Data = #data{worker_pid = Pid}) ->
    handle_recv(Data#data.worker, ?QUERY_INFO(make_ref()), Data),
    keep_state_and_data;
%% The worker process has died.
handle_event(info, {'DOWN', ErlMon, process, Pid, Reason}, _State, Data = #data{worker_pid = Pid}) ->
    case is_self_loop(Reason) of
        true ->
            handle_recv(Data#data.worker, ?QUERY_INFO(make_ref()), Data),
            keep_state_and_data;
        false ->
            erlang:demonitor(ErlMon, [flush]),
            {stop, normal, Data}
    end;

%%%======================
%%% handle_event: Internal Queue Processing
%%%======================

handle_event(internal, process_queue, ?synced, Data = #data{message_q = MQ, message_map = MMap}) ->
    case queue:peek(MQ) of
        empty ->
            keep_state_and_data;
        {value, {sync, ReqId}} ->
            MQ1 = queue:drop(MQ),
            case maps:take(ReqId, MMap) of
                error ->
                    %% Tombstone: this event was resolved out-of-band while in a wait state.
                    %% Ignore it and immediately process the next item in the queue.
                    {keep_state, Data#data{message_q = MQ1}, [{next_event, internal, process_queue}]};
                {SyncEvents, MMap1} ->
                    %% Standard path: event(s) found, process it.
                    {keep_state, Data#data{message_q = MQ1, message_map = MMap1}, [{next_event, internal, SyncEvents}]}
            end;
        {value, {other, EventType, Msg}} ->
            MQ1 = queue:drop(MQ),
            % Handle the event immediately, then continue processing the queue.
            % If this somehow changes state, process_queue will do nothing when not synced.
            {keep_state, Data#data{message_q = MQ1}, [{next_event, EventType, Msg}, {next_event, internal, process_queue}]}
    end;

%% We ended up here while not being synced. This is actually valid and simply ignore this case.
%% The matching sync message should not have arrived yet.
handle_event(internal, process_queue, _State, _Data) ->
    keep_state_and_data;

%% Check the map for receive trace right after we matched a herald.
%% This fills the gap in the logic when we end up in wait_mon_proc,
%% which enforces waiting for a herald first, and wait_proc handling is postponed.
handle_event(internal, check_proc, ?wait_proc(From, MsgInfo), Data = #data{message_map = MMap}) ->
    ReqId = resolve_sync_reqid(?RECV_INFO(MsgInfo)),
    case maps:take(ReqId, MMap) of
        error ->
            %% Not here yet. Safe to just sit in ?wait_proc and wait.
            keep_state_and_data;
        {_, MMap1} ->
            %% It arrived while we were busy!
            %% We don't bother popping it from the queue (it will just be an empty 
            %% {sync, ReqId} marker that process_queue handles later), but we must update the map.
            Data1 = Data#data{message_map = MMap1},
            
            %% Since we found the trace, we have the match! Process it and go back to synced.
            Data2 = handle_recv(From, MsgInfo, Data1),
            {next_state, ?synced, Data2, [{next_event, internal, process_queue}]}
    end;

%% Process the synchronization events for a request while synced.
handle_event(internal, SyncEvents, ?synced, Data) ->
    case SyncEvents of
        % Only one event, so we can directly match it and transition to the appropriate state.
        ?RECV_INFO(MsgInfo) ->
            {next_state, ?wait_mon(MsgInfo), Data};
        ?HERALD(From, MsgInfo) ->
            {next_state, ?wait_proc(From, MsgInfo), Data};
        % We found both matching events, we remain synced and perform necessary actions.
        {?RECV_INFO(MsgInfo), ?HERALD(From, MsgInfo)} ->
            Data1 = handle_recv(From, MsgInfo, Data),
            {keep_state, Data1, [{next_event, internal, process_queue}]};
        {?HERALD(From, MsgInfo), ?RECV_INFO(MsgInfo)} ->
            Data1 = handle_recv(From, MsgInfo, Data),
            {keep_state, Data1, [{next_event, internal, process_queue}]};
        _ ->
            error({unexpected_sync_events, SyncEvents})
    end;

%%%======================
%%% handle_event: Deadlock propagation
%%%======================

handle_event(cast, ?DEADLOCK_PROP(DL), _State, Data) ->
    state_deadlock(DL, Data),
    keep_state_and_data;

%%%======================
%%% handle_event: Monitor operation
%%%======================

%%%======================
%% Send trace

%% Handle send trace in synced state
handle_event(cast, ?SEND_INFO(To, MsgInfo), ?synced, Data) ->
    Data1 = handle_send(To, MsgInfo, Data),
    send_herald(To, MsgInfo, Data),
    {keep_state, Data1};

%% Handle send trace while awaiting process trace
handle_event(cast, ?SEND_INFO(To, MsgInfo), ?wait_proc(_From, _ProcMsgInfo), Data) ->
    Data1 = handle_send(To, MsgInfo, Data),
    send_herald(To, MsgInfo, Data),
    {keep_state, Data1};

%% Awaiting herald: postpone
handle_event(cast, ?SEND_INFO(_To, _MsgInfo), _State, Data) ->
    Data1 = postpone_event(cast, ?SEND_INFO(_To, _MsgInfo), Data),
    {keep_state, Data1};

%%%======================
%% Receive trace

%% We were synced, so now we wait for monitor herald
handle_event(cast, ?RECV_INFO(MsgInfo), ?synced, _Data) ->
    {next_state, ?wait_mon(MsgInfo), _Data};

%% Awaited process receive-trace
handle_event(cast, ?RECV_INFO(MsgInfo), ?wait_proc(From, MsgInfo), Data0) ->
    Data1 = handle_recv(From, MsgInfo, Data0),
    {next_state, ?synced, Data1, [{next_event, internal, process_queue}]};

%% Unwanted process receive-trace. We wait for herald first, and then
%% resume waiting for the process trace.
handle_event(cast, ?RECV_INFO(MsgInfoNotif), ?wait_proc(From, MsgInfo), Data) when MsgInfoNotif =/= MsgInfo ->
    {next_state, ?wait_mon_proc(MsgInfoNotif, From, MsgInfo), Data};

%% Awaiting herald: postpone
handle_event(cast, ?RECV_INFO(_MsgInfo), _State, Data) ->
    Data1 = postpone_event(cast, ?RECV_INFO(_MsgInfo), Data),
    {keep_state, Data1};

%%%======================
%%% Call timeout

handle_event(cast, ?TIMEOUT_SEND(To), ?synced, Data) ->
    ?DDT_INFO_TIMEOUT("~p: Call to ~p timed out!", [Data#data.worker, To]),

    NormalizedTo = resolve_to_pid(To),
    case mon_of(Data, NormalizedTo) of
        undefined -> ok;
        MonPid ->
            % Inform the monitor about our timeout. The monitor may or may not know
            % about us after a timeout, but if it knows, we must tell it to stop waiting
            % for us, otherwise it will get confused with subsequent requests.
            Worker = Data#data.worker,
            Msg = ?TIMEOUT_WAITEE(Worker),
            gen_statem:cast(MonPid, Msg),
            ok
    end,

    % Our process just timed out waiting for a response.
    % This is effectively an unlock (if handled) or a crash and we're about to die anyway.
    state_unlock(Data),
    keep_state_and_data;

handle_event(cast, ?TIMEOUT_SEND(_To), _State, Data) ->
    Data1 = postpone_event(cast, ?TIMEOUT_SEND(_To), Data),
    {keep_state, Data1};

handle_event(cast, ?TIMEOUT_WAITEE(Who), _State, Data) ->
    ?DDT_INFO_TIMEOUT("~p: Waitee ~p timed out waiting for us!", [Data#data.worker, Who]),

    state_unwait_if_waiting(Who, Data),
    keep_state_and_data;

%%%======================
%% Monitor herald
    
%% We were synced, so now we wait for process trace
handle_event(cast, ?HERALD(From, MsgInfo), ?synced, _Data) ->
    {next_state, ?wait_proc(From, MsgInfo), _Data};

%% Awaited herald
handle_event(cast, ?HERALD(From, MsgInfo), ?wait_mon(MsgInfo), Data0) ->
    Data1 = handle_recv(From, MsgInfo, Data0),
    {next_state, ?synced, Data1, [{next_event, internal, process_queue}]};

handle_event(cast, ?HERALD(From, MsgInfo), ?wait_mon_proc(MsgInfo, FromProc, MsgInfoProc), Data0) ->
    Data1 = handle_recv(From, MsgInfo, Data0),
    {next_state, ?wait_proc(FromProc, MsgInfoProc), Data1, [{next_event, internal, check_proc}]};

%% Unwanted herald: postpone
handle_event(cast, ?HERALD(_From, _MsgInfoOther), _State, Data) ->
    Data1 = postpone_event(cast, ?HERALD(_From, _MsgInfoOther), Data),
    {keep_state, Data1};

%%%======================
%% Probe

%% Handle probe in synced state
handle_event(cast, ?PROBE(Probe, L), ?synced, Data) ->
    ?DDT_DBG_PROBE("~p: Received probe ~p with path ~p in synced state", [Data#data.worker, Probe, L]),
    call_mon_state(?PROBE(Probe, L), Data),
    keep_state_and_data;

%% Handle probe while awaiting monitor herald (since probes come from monitors).
%% TODO: filter to make sure the probe comes from the right monitor only?
handle_event(cast, ?PROBE(Probe, L), ?wait_mon(?RESP_INFO(_ReqId)), Data) ->
    ?DDT_DBG_PROBE("~p: Received probe ~p with path ~p while awaiting monitor", [Data#data.worker, Probe, L]),
    call_mon_state(?PROBE(Probe, L), Data),
    keep_state_and_data;

handle_event(cast, ?PROBE(Probe, L), ?wait_mon_proc(?RESP_INFO(_ReqId), _FromProc, _MsgInfoProc), Data) ->
    ?DDT_DBG_PROBE("~p: Received probe ~p with path ~p while awaiting monitor proc", [Data#data.worker, Probe, L]),
    call_mon_state(?PROBE(Probe, L), Data),
    keep_state_and_data;

%% Unwanted probe: postpone
handle_event(cast, ?PROBE(_Probe, _L), _State, Data) ->
    ?DDT_DBG_PROBE("~p: Postponing probe ~p with path ~p in state ~p", [Data#data.worker, _Probe, _L, _State]),
    Data1 = postpone_event(cast, ?PROBE(_Probe, _L), Data),
    {keep_state, Data1};

%%%======================
%% Edge cases

%% We are somehow non-exhaustive or someone's pranked us
handle_event(_Kind, _Msg, _State, _Data) ->
    error({unexpected_event, _Kind, _Msg, _State}).

%%%======================
%%% Monitor user API
%%%======================

%% @doc Stops tracing for the monitored process. This does not terminate the
%% tracing process itself, just stops listening to subsequent events.
stop_tracer(Mon) ->
    gen_statem:call(Mon, stop_tracer).

%% @doc Sends a `gen_statem` request which will be replied when a deadlock is
%% detected. Useful for simultaneous waiting for either a response from the
%% gen_server or a deadlock.
subscribe_deadlocks(Mon) ->
    gen_statem:send_request(Mon, subscribe).

%% @doc Sends a gen_statem request to abandon a deadlock subscription. Once
%% processed, the previous subscription will not be replied to.
unsubscribe_deadlocks(Mon) ->
    gen_statem:send_request(Mon, unsubscribe).

%%%======================
%%% Internal Helper Functions
%%%======================

%% @doc Handle receive trace.
handle_recv(From, ?QUERY_INFO([alias|ReqId]), Data) ->
    NormalizedFrom = resolve_to_pid(From),
    state_wait(NormalizedFrom, ReqId, Data);
handle_recv(From, ?QUERY_INFO(ReqId), Data) ->
    NormalizedFrom = resolve_to_pid(From),
    state_wait(NormalizedFrom, ReqId, Data);
handle_recv(_From, ?RESP_INFO(_ReqId), Data) ->
    state_unlock(Data).

%% @doc Handle send trace.
handle_send(_To, ?QUERY_INFO(ReqId), Data) ->
    state_lock(ReqId, Data);
handle_send(To, ?RESP_INFO(_ReqId), Data) ->
    NormalizedTo = resolve_to_pid(To),
    state_unwait(NormalizedTo, Data).

%% @doc Register a client
state_wait(Who, ReqId, Data) ->
    call_mon_state({wait, Who, ReqId}, Data).

%% @doc Unregister a client
state_unwait(Who, Data) ->
    call_mon_state({unwait, Who}, Data).

%% @doc Unregister a client safely (don't crash if the client is not actually waiting)
state_unwait_if_waiting(Who, Data) ->
    call_mon_state({unwait_if_waiting, Who}, Data).

%% @doc Register unlocking
state_unlock(Data) ->
    call_mon_state(unlock, Data).
    
%% @doc Register locking
state_lock(ReqId, Data) ->
    call_mon_state({lock, ReqId}, Data).

%% @doc Register a deadlock
state_deadlock(DL, Data) ->
    call_mon_state(?DEADLOCK_PROP(DL), Data).


%% @doc Send monitor herald to another monitor. The [To] should refer to the
%% worker process, not the monitor directly. If [To] is not monitored, the
%% function does nothing.
send_herald(To, MsgInfo, Data) ->
    NormalizedTo = resolve_to_pid(To),
    Mon = mon_of(Data, NormalizedTo),
    case Mon of
        undefined -> ok;
        _ ->
            ?DDT_DBG_HERALD("~p: Sending herald to ~p for message ~p", [Data#data.worker, To, MsgInfo]),
            Worker = Data#data.worker,
            Msg = ?HERALD(Worker, MsgInfo),
            gen_statem:cast(Mon, Msg),
            ok
    end.


%% @doc Send a call message to the monitor state process and handle the
%% response.
call_mon_state(Msg, Data = #data{mon_state = Pid}) ->
    Resp = gen_server:call(Pid, Msg),
    handle_mon_state_response(Resp, Data),
    Data.


%% Send a cast message to the monitor state process.
cast_mon_state(Msg, #data{mon_state = Pid}) ->
    gen_server:cast(Pid, Msg).


%% @doc Handle reponse of the monitoring algorithm. Execute all scheduled sends.
handle_mon_state_response(ok, _Data) ->
    ok;
handle_mon_state_response({send, Sends}, _Data) ->
    [ gen_statem:cast(ToPid, Msg) || {ToPid, Msg} <- Sends ],
    ok.


%% @doc Inspect the monitor of a process.
mon_of(_Data, Pid) ->
    mon_reg:mon_of(Pid).

%% @doc Unset the monitor from registry.
unset_mon(Data) ->
    Worker = Data#data.worker,
    WorkerPid = Data#data.worker_pid,
    mon_reg:unset_mon(Worker),
    case Worker of
        WorkerPid -> ok;
        _ -> mon_reg:unset_mon(WorkerPid)
    end.


%% @doc Check if shutdown reason was caused by a (possibly remote) deadlock
%% caused by a call to self.
is_self_loop({calling_self, _}) ->
    true;
is_self_loop({E, _}) ->
    is_self_loop(E);
is_self_loop(_) ->
    false.

 
%% @doc Resolve a process name to a PID for Erlang monitoring
resolve_to_pid(Pid) when is_pid(Pid) -> Pid;
resolve_to_pid({global, Name}) ->
    case global:whereis_name(Name) of
        undefined -> exit({noproc, {global, Name}});
        Pid -> Pid
    end;
resolve_to_pid({via, Mod, Name}) ->
    case Mod:whereis_name(Name) of
        undefined -> exit({noproc, {via, Mod, Name}});
        Pid -> Pid
    end;
resolve_to_pid(Name) when is_atom(Name) ->
    case whereis(Name) of
        undefined -> exit({noproc, Name});
        Pid -> Pid
    end.

%%%======================
%%% Internal Queue Helper Functions
%%%======================

postpone_event(EventType, Msg, Data = #data{message_q = MQ, message_map = MMap}) ->
    case resolve_sync_reqid(Msg) of
        undefined -> % Non-blocking event, simply add to the queue.
            MQ1 = queue:in({other, EventType, Msg}, MQ),
            MMap1 = MMap;
        ReqId -> % Blocking event, add to the queue and also to the map for easy lookup.
            case maps:get(ReqId, MMap, undefined) of
                undefined -> % First message for this request -> add to queue and map.
                    MQ1 = queue:in({sync, ReqId}, MQ),
                    MMap1 = maps:put(ReqId, Msg, MMap);
                ReqMessage -> % Already have a message for this request -> update the record.
                    MQ1 = MQ,
                    MMap1 = maps:put(ReqId, {ReqMessage, Msg}, MMap)
            end
    end,
    Data#data{message_q = MQ1, message_map = MMap1}.

resolve_sync_reqid(Msg) ->
    MsgInfo = 
        case Msg of
            ?RECV_INFO(Info) -> Info;
            ?HERALD(_From, Info) -> Info;
            _ -> undefined
        end,

    case MsgInfo of
        ?QUERY_INFO(ReqId) -> ReqId;
        ?RESP_INFO(ReqId) -> ReqId;
        _ -> undefined
    end.