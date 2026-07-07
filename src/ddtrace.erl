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
    , tracer               :: process_name() % the srpc_tracer process
    , idle_timer           :: non_neg_integer() % timeout after which the monitor hibernates in synced state
    %% Queue and map data structures for efficient herald-trace matching.
    , trace_q              :: queue:queue()  % queue of trace messages
    , mon_msg_q            :: queue:queue()  % queue of monitor messages
    , mon_msg_m            :: map()  % map of monitor messages for out-of-band O(1) processing
    , sync_timeout         :: non_neg_integer() % timeout for waiting for synchronisation (matching RECV with herald)
    , sync_timeout_panic   :: non_neg_integer() % additive timeout for triggering panic and stopping the tracer
    , late_map             :: map()          % map of late replies after unlocking from a handled timeout
    , late_ttl             :: non_neg_integer() % time-to-live for a late reply trace, awaiting a herald that may not arrive (when not from a monitored worker)
    %% Internal "detector" and "tracer" states
    , detector_state       :: ddt_detector:state()
    , tracer_state         :: ddt_tracer:state()
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
    process_flag(priority, ?PROCESS_PRIORITY),
    process_flag(trap_exit, true),

    mon_reg:ensure_started(),
    
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
    DetectorState = ddt_detector:init(Worker),
    TracerState = ddt_tracer:init(WorkerPid),

    %% First timeout that logs a warning that we're waiting unusually long for synchronisation (matching RECV with herald).
    SyncTimeout = proplists:get_value(sync_timeout, Opts, ?SYNC_TIMEOUT),
    %% Second timeout that triggers panic and stops the tracer to avoid potential performance issues if we're waiting for synchronisation for way too long.
    %% The total time until panic will be sync_timeout + sync_timeout_panic, so it should be set accordingly (e.g. panic timeout could be the same as the initial warning timeout).
    SyncTimeoutPanic = proplists:get_value(sync_timeout_panic, Opts, ?SYNC_TIMEOUT_PANIC),
    LateTTL = proplists:get_value(late_ttl, Opts, 60000),

    Data = #data{ worker = Worker
                , worker_pid = WorkerPid
                , erl_monitor = ErlMon
                , idle_timer = proplists:get_value(idle_timer, Opts, 5000)
                , trace_q = queue:new()
                , mon_msg_q = queue:new()
                , mon_msg_m = #{}
                , sync_timeout = SyncTimeout
                , sync_timeout_panic = SyncTimeoutPanic
                , late_map = #{}
                , late_ttl = LateTTL
                , detector_state = DetectorState
                , tracer_state = TracerState
                },

    {ok, ?synced, Data, []}.

callback_mode() ->
    %% We use `state_enter` to debug major state transitions via tracing. Leave
    %% it unless it causes performance issues.
    [handle_event_function, state_enter].

terminate(State, Data) ->
    terminate(shutdown, State, Data).
terminate(Reason, _State, Data) ->
    ddt_tracer:stop(Data#data.tracer_state),
    if Reason =:= normal; Reason =:= shutdown; element(1, Reason) =:= shutdown ->
            ok;
         true ->
            Worker = Data#data.worker,
            logger:error("~p: Monitor for worker ~p died abnormally: ~w", [self(), Worker, Reason], #{module => ?MODULE, subsystem => ddtrace})
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

%%%======================
%%% Timeouts

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

%% The TTL expired and no herald ever arrived for this late reply. Time to forget about it.
handle_event({timeout, ReqId}, cleanup_timed_out_reply, _State, Data = #data{late_map = LMap}) ->
    {keep_state, Data#data{late_map = maps:remove(ReqId, LMap)}};

handle_event(timeout, idle_hibernate, _State, _Data) ->
    ?DDT_DBG('HIBERNATING', "~p: No traffic in the last ~p ms... time for a nap.", [_Data#data.worker, _Data#data.idle_timer]),
    {keep_state_and_data, [hibernate]};

%%%======================
%%% Calls

handle_event({call, From}, subscribe, _State, Data) ->
    DetectorState1 = ddt_detector:subscribe(From, Data#data.detector_state),
    {keep_state, Data#data{detector_state = DetectorState1}};

handle_event({call, From}, unsubscribe, _State, Data) ->
    DetectorState1 = ddt_detector:unsubscribe(From, Data#data.detector_state),
    {keep_state, Data#data{detector_state = DetectorState1}, [{reply, From, ok}]};

handle_event({call, From}, stop_tracer, _State, Data) ->
    %% Unregister from mon_reg before stopping
    unset_mon(Data),
    %% We reply first, then trigger a normal stop.
    {stop_and_reply, normal, [{reply, From, ok}]};

%%%======================
%%% Raw Trace Routing

handle_event(info, Trace, _State, Data) when element(1, Trace) =:= trace ->
    {EventsToQueue, TracerState1} = ddt_tracer:handle_trace(Trace, Data#data.tracer_state),
    
    %% Map the returned events into actions
    Actions = [{next_event, internal, Ev} || Ev <- EventsToQueue],
    
    {keep_state, Data#data{tracer_state = TracerState1}, Actions};

%%%======================
%%% Info

%% The worker has attempted a call to itself. When this happens, no actual
%% message is sent. We fake the call message to "detect" the deadlock.
handle_event(info, {'DOWN', _ErlMon, process, Pid, {calling_self, _Reason}}, _State, Data = #data{worker_pid = Pid}) ->
    Data1 = handle_recv(Data#data.worker, ?QUERY_INFO(make_ref()), Data),
    {keep_state, Data1};
%% The worker process has died.
handle_event(info, {'DOWN', ErlMon, process, Pid, Reason}, _State, Data = #data{worker_pid = Pid}) ->
    case is_self_loop(Reason) of
        true ->
            Data1 = handle_recv(Data#data.worker, ?QUERY_INFO(make_ref()), Data),
            {keep_state, Data1};
        false ->
            erlang:demonitor(ErlMon, [flush]),
            %% Use shutdown to kill linked processes (ddtrace_detector and srpc_tracer)
            {stop, shutdown, Data}
    end;

%%%======================
%%% handle_event: Internal Queue Processing
%%%======================

%% Check the queue for the next trace right after we matched a herald.
handle_event(internal, check_trace, State, Data = #data{trace_q = TQ}) ->
    case queue:out(TQ) of
        {empty, _} ->
            case State of
                ?wait_proc(_, _) ->
                    keep_state_and_data;
                ?synced ->
                    {keep_state_and_data, [{next_event, internal, check_mon}]}
            end;
        {{value, Ev}, TQ1} ->
            {keep_state, Data#data{trace_q = TQ1}, [{next_event, internal, Ev}]}
    end;

%% This should never fire! We do not check mon queue in the wait_proc state!
handle_event(internal, check_mon, State = ?wait_proc(_, _), _Data) ->
    error({unexpected_check_mon, State});

%% Check the monitor event queue for the next event.
handle_event(internal, check_mon, State, Data = #data{mon_msg_q = MQ, mon_msg_m = MM}) ->
    case queue:out(MQ) of
        {empty, _} ->
            if State == ?synced ->
                %% If the detector is not active (), start a hibernation timer
                case ddt_detector:is_active(Data#data.detector_state) of
                    true -> keep_state_and_data;
                    false -> {keep_state_and_data, [{timeout, Data#data.idle_timer, idle_hibernate}]}
                end
            end;
        {{value, ReqId}, MQ1} ->
            case maps:take(ReqId, MM) of
                error ->
                    %% Tombstone: this event was resolved out-of-band while in a wait state.
                    %% Ignore it and process the next item in the queue.
                    {keep_state, Data#data{mon_msg_q = MQ1}, [{next_event, internal, check_mon}]};
                {MonEvents, MM1} ->
                    %% Standard path: event(s) found, process them. 
                    Actions = [{next_event, cast, Ev} || Ev <- lists:reverse(MonEvents)] ++ [{next_event, internal, check_trace}],
                    {keep_state, Data#data{mon_msg_q = MQ1, mon_msg_m = MM1}, Actions}
            end
    end;

handle_event(internal, {lookup_herald, MsgInfo}, _State, Data = #data{mon_msg_m = MM}) ->
    ReqId = resolve_herald_reqid(MsgInfo),
    case maps:take(ReqId, MM) of
        error ->
            %% No entry (yet), corresponding herald has not arrived yet
            keep_state_and_data;
        {MonEvents, MM1} ->
            %% Standard path: event(s) found, process them. 
            Actions = [{next_event, cast, Ev} || Ev <- lists:reverse(MonEvents)],
            {keep_state, Data#data{mon_msg_m = MM1}, Actions}
    end;

%%%======================
%% Send trace

%% Handle send trace in synced state
handle_event(internal, ?SEND_INFO(To, MsgInfo), ?synced, Data) ->
    Data1 = handle_send(To, MsgInfo, Data),
    send_herald(To, MsgInfo, Data),
    {keep_state, Data1, [{next_event, internal, check_trace}]};

%% Handle send trace while awaiting process trace
handle_event(internal, ?SEND_INFO(To, MsgInfo), ?wait_proc(_From, _ProcMsgInfo), Data) ->
    Data1 = handle_send(To, MsgInfo, Data),
    send_herald(To, MsgInfo, Data),
    {keep_state, Data1, [{next_event, internal, check_trace}]};

%% Awaiting herald: postpone
handle_event(internal, Ev = ?SEND_INFO(_To, _MsgInfo), _State, Data = #data{trace_q = TQ}) ->
    {keep_state, Data#data{trace_q = queue:in(Ev, TQ)}};

%%%======================
%% Receive trace

%% We were synced, so now we wait for monitor herald
handle_event(internal, ?RECV_INFO(MsgInfo), ?synced, Data) ->
    {next_state, ?wait_mon(MsgInfo), Data, [{next_event, internal, {lookup_herald, MsgInfo}}]};

%% Awaited process receive-trace
handle_event(internal, ?RECV_INFO(MsgInfo), ?wait_proc(From, MsgInfo), Data0) ->
    Data1 = handle_recv(From, MsgInfo, Data0),
    {next_state, ?synced, Data1, [{next_event, internal, check_trace}]};

%% Unwanted process receive-trace. We wait for herald first, and then
%% resume waiting for the process trace.
handle_event(internal, ?RECV_INFO(MsgInfoNotif), ?wait_proc(From, MsgInfo), Data) when MsgInfoNotif =/= MsgInfo ->
    {next_state, ?wait_mon_proc(MsgInfoNotif, From, MsgInfo), Data, [{next_event, internal, {lookup_herald, MsgInfoNotif}}]};

%% Awaiting herald: postpone
handle_event(internal, Ev = ?RECV_INFO(_MsgInfo), _State, Data = #data{trace_q = TQ}) ->
    {keep_state, Data#data{trace_q = queue:in(Ev, TQ)}};

%%%======================
%%% Timeout trace

%% Our worker just timed out waiting for a response.
%% This is effectively an unlock (if handled) or a crash and we're about to die anyway.
handle_event(internal, ?TIMEOUT_SEND(To, ReqId), ?synced, Data = #data{late_map = LMap}) ->
    ?DDT_INFO_TIMEOUT("~p: Call to ~p timed out!", [Data#data.worker, To]),
    NormalizedTo = resolve_to_pid(To),
    case mon_of(Data, NormalizedTo) of
        undefined -> ok;
        MonPid ->
            % Inform the monitor about our timeout. The monitor may or may not know
            % about us after a timeout, but if it knows, we must tell it to stop waiting
            % for us, otherwise it will get confused with subsequent requests.
            Worker = Data#data.worker,
            Msg = ?TIMEOUT_WAITEE(Worker, ReqId),
            gen_statem:cast(MonPid, Msg),
            ok
    end,
    
    % logger:warning("Handling a timeout! Unlocking! State: ~p", [Data#data.detector_state]),
    Data1 = state_unlock(Data),
    % logger:warning("New state: ~p", [Data1#data.detector_state]),
    LMap1 = maps:put(ReqId, true, LMap),
    {keep_state, Data1#data{late_map = LMap1}, [{{timeout, ReqId}, Data1#data.late_ttl, cleanup_timed_out_reply}, {next_event, internal, check_trace}]};

%% The herald coming from a late reply somehow beat the tracer
handle_event(internal, ?TIMEOUT_SEND(_To, ReqId), ?wait_proc(_From, ?RESP_INFO(ReqId)), Data) ->
    ?DDT_INFO_TIMEOUT("~p: Call to ~p timed out! (target replied late)", [Data#data.worker, _To]),
    Data1 = state_unlock(Data),
    {next_state, ?synced, Data1, [{next_event, internal, check_trace}]};

handle_event(internal, Ev = ?TIMEOUT_SEND(_To, _ReqId), _State, Data = #data{trace_q = TQ}) ->
    {keep_state, Data#data{trace_q = queue:in(Ev, TQ)}};

handle_event(cast, ?TIMEOUT_WAITEE(Who, ReqId), _State, Data) ->
    ?DDT_INFO_TIMEOUT("~p: Waitee ~p timed out waiting for us!", [Data#data.worker, Who]),

    %% Unwait politely. We might have actually replied and already unwaited between the timeout and our late reply (if replied).
    Data1 = state_unwait_if_waiting(Who, ReqId, Data),
    {keep_state, Data1};

%%%======================
%% Monitor herald

%% We received a herald from another monitor
handle_event(cast, Ev = ?HERALD(_From, _MsgInfo), _State, _Data) ->
    {keep_state_and_data, [{next_event, internal, Ev}]};

%% We were synced, so now we should wait for process trace
handle_event(internal, _Ev = ?HERALD(From, MsgInfo), ?synced, Data = #data{late_map = LMap}) ->
    ReqId = resolve_herald_reqid(MsgInfo),
    %% Check if herald belongs to a late reply (edge case of reply coming after a handled timeout)
    case maps:take(ReqId, LMap) of
        error ->
            %% Normal flow: wait for the process trace
            {next_state, ?wait_proc(From, MsgInfo), Data, [{next_event, internal, check_trace}]};
        {_, LMap1} ->
            %% Cancel the TTL timer, drop the herald, and stay synced.
            {keep_state, Data#data{late_map = LMap1}, [{{timeout, ReqId}, cancel}]}
    end;

%% Awaited herald
handle_event(internal, ?HERALD(From, MsgInfo), ?wait_mon(MsgInfo), Data0) ->
    Data1 = handle_recv(From, MsgInfo, Data0),
    {next_state, ?synced, Data1, [{next_event, internal, check_trace}]};

handle_event(internal, ?HERALD(From, MsgInfo), ?wait_mon_proc(MsgInfo, FromProc, MsgInfoProc), Data0) ->
    Data1 = handle_recv(From, MsgInfo, Data0),
    {next_state, ?wait_proc(FromProc, MsgInfoProc), Data1, [{next_event, internal, check_trace}]};

%% Unwanted herald: postpone
handle_event(internal, Ev = ?HERALD(_From, MsgInfoOther), _State, Data) ->
    ReqId = resolve_herald_reqid(MsgInfoOther),
    {keep_state, postpone_mon_event(ReqId, Ev, Data)};

%%%======================
%% Probe

%% Handle probe in synced state
handle_event(cast, ?PROBE(Probe, L), ?synced, Data) ->
    ?DDT_DBG_PROBE("~p: Received probe ~p with path ~p in synced state", [Data#data.worker, Probe, L]),
    Data1 = state_check_probe(?PROBE(Probe, L), Data),
    {keep_state, Data1};

%% Handle probe while awaiting monitor herald (since probes come from monitors).
%% TODO: filter to make sure the probe comes from the right monitor only?
handle_event(cast, ?PROBE(Probe, L), ?wait_mon(?RESP_INFO(_ReqId)), Data) ->
    ?DDT_DBG_PROBE("~p: Received probe ~p with path ~p while awaiting monitor", [Data#data.worker, Probe, L]),
    Data1 = state_check_probe(?PROBE(Probe, L), Data),
    {keep_state, Data1};

handle_event(cast, ?PROBE(Probe, L), ?wait_mon_proc(?RESP_INFO(_ReqId), _FromProc, _MsgInfoProc), Data) ->
    ?DDT_DBG_PROBE("~p: Received probe ~p with path ~p while awaiting monitor proc", [Data#data.worker, Probe, L]),
    Data1 = state_check_probe(?PROBE(Probe, L), Data),
    {keep_state, Data1};

%% Unwanted probe: postpone
handle_event(cast, Ev = ?PROBE(Probe, _L), _State, Data) ->
    {keep_state, postpone_mon_event(Probe, Ev, Data)};

%%%======================
%%% Deadlock propagation

handle_event(cast, ?DEADLOCK_PROP(DL), _State, Data) ->
    Data1 = state_propagate_deadlock(?DEADLOCK_PROP(DL), Data),
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

%% @doc Handle receive trace.
handle_recv(From, ?QUERY_INFO(ReqId), Data) ->
    NormalizedFrom = resolve_to_pid(From),
    state_wait(NormalizedFrom, ReqId, Data);
handle_recv(_From, ?RESP_INFO(_ReqId), Data) ->
    state_unlock(Data).

%% @doc Handle send trace.
handle_send(_To, ?QUERY_INFO(ReqId), Data) ->
    state_lock(ReqId, Data);
handle_send(To, ?RESP_INFO(ReqId), Data) ->
    NormalizedTo = resolve_to_pid(To),
    % Unwait politely. The waitee may have already timed out and its monitor
    % could have informed us ahead of our worker sending a late reply.
    state_unwait_if_waiting(NormalizedTo, ReqId, Data).

%% @doc Register a client
state_wait(Who, ReqId, Data) ->
    state_handle_action(ddt_detector:add_waitee(Who, ReqId, Data#data.detector_state), Data).

%% @doc Unregister a client safely (don't crash if the client is not actually waiting)
state_unwait_if_waiting(Who, ReqId, Data) ->
    state_handle_action(ddt_detector:remove_waitee_if_waiting(Who, ReqId, Data#data.detector_state), Data).

%% @doc Register unlocking
state_unlock(Data) ->
    state_handle_action(ddt_detector:unlock(Data#data.detector_state), Data).
    
%% @doc Register locking
state_lock(ReqId, Data) ->
    state_handle_action(ddt_detector:lock(ReqId, Data#data.detector_state), Data).

%% @doc Check incoming probe
state_check_probe(Probe, Data) ->
    state_handle_action(ddt_detector:check_probe(Probe, Data#data.detector_state), Data).

%% @doc Propagate deadlocks
state_propagate_deadlock(DL, Data) ->
    state_handle_action(ddt_detector:propagate_deadlock(DL, Data#data.detector_state), Data).


%% @doc Handle a deadlock-state action and handle the response response.
%% Returns the updated state.
state_handle_action({Resp, NewDetectorState}, Data) ->
    handle_detector_response(Resp),
    Data#data{detector_state = NewDetectorState}.


%% @doc Handle reponse of the monitoring algorithm. Execute all scheduled sends.
handle_detector_response(ok) ->
    ok;
handle_detector_response({send, Sends}) ->
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
resolve_to_pid({Name, Node}) when is_atom(Name), is_atom(Node) ->
    case rpc:call(Node, erlang, whereis, [Name]) of
        Pid when is_pid(Pid) -> Pid;
        _ -> exit({noproc, {Name, Node}})
    end;
resolve_to_pid(Name) when is_atom(Name) ->
    case whereis(Name) of
        undefined -> exit({noproc, Name});
        Pid -> Pid
    end.

%%%======================
%%% Internal Queue Helper Functions
%%%======================

postpone_mon_event(ReqId, Ev, Data = #data{mon_msg_q = MQ, mon_msg_m = MM}) ->
    case maps:get(ReqId, MM, undefined) of
        undefined -> % First mon message for this request
            MQ1 = queue:in(ReqId, MQ),
            MM1 = maps:put(ReqId, [Ev], MM);
        Events ->
            MQ1 = MQ,
            MM1 = maps:put(ReqId, [Ev | Events], MM)
    end,
    Data#data{mon_msg_q = MQ1, mon_msg_m = MM1}.

resolve_herald_reqid(MsgInfo) ->
    case MsgInfo of
        ?QUERY_INFO(ReqId) -> ReqId;
        ?RESP_INFO(ReqId) -> ReqId;
        _ -> undefined
    end.