-module(ddt_detector).

-include("ddtrace.hrl").
-export([ init/1
        , add_waitee/3
        , remove_waitee/2
        , remove_waitee_if_waiting/2
        , is_active/1
        , lock/2
        , unlock/1
        , check_probe/2
        , propagate_deadlock/2
        , subscribe/2
        , unsubscribe/2
        ]).

-type process_name() ::
        pid()
      | atom()
      | {global, term()}
      | {via, module(), term()}.

-record(state,
    { worker             :: process_name()
    , probe              :: gen_statem:request_id() | undefined
    , waitees            :: [process_name()] % callers waiting on us
    , reqid_map = #{}
    , subscribers = []   :: [gen_statem:from()]
    , deadlocked = false :: {true, [process_name()]} | false
    }).

%% Exported opaque type so ddtrace can hold it
-opaque state() :: #state{}.
-export_type([state/0]).

%%%======================
%% Public API
%%%======================

%% @doc Initialize the detector state
-spec init(process_name()) -> state().
init(Worker) ->
    #state{
        worker = Worker,
        probe = undefined,
        waitees = []
    }.

%% Add waitee (deadlocked)
add_waitee(Who, ReqId, State = #state{deadlocked = {true, DL}}) ->
    State1 = register_waitee(Who, ReqId, State),
    Resp = case mon_reg:mon_of(Who) of
               undefined -> ok;
               MonPid when is_pid(MonPid) ->
                   {send, [{MonPid, ?DEADLOCK_PROP(DL)}]}
           end,
    {Resp, State1};

%% Add waitee (self)
add_waitee(Who, _ReqId, State = #state{worker = Who}) ->
    {Sends, State1} = report_deadlock([Who, Who], State),
    {{send, Sends}, State1};

%% Add waitee (unlocked)
add_waitee(Who, ReqId, State = #state{probe = undefined}) ->
    State1 = register_waitee(Who, ReqId, State),
    {ok, State1};

%% Add waitee (locked)
add_waitee(Who, ReqId, State = #state{probe = Probe}) ->
    State1 = register_waitee(Who, ReqId, State),
    Resp = case mon_reg:mon_of(Who) of
               undefined -> ok;
               MonPid when is_pid(MonPid) ->
                   Worker = State#state.worker,
                   ?DDT_DBG_PROBE("~p: Sending probe ~p to ~p with path [~p]", [Worker, Probe, MonPid, Worker]),
                   {send, [{MonPid, ?PROBE(Probe, [Worker])}]}
           end,
    {Resp, State1}.

%% Remove waitee while deadlocked --- error
remove_waitee(_, #state{deadlocked = {true, DL}}) ->
    error({unwait_deadlocked, DL});

%% Remove waitee
remove_waitee(WhoId, State) ->
    State1 = unregister_waitee(WhoId, true, State),
    {ok, State1}.

%% Remove waitee if waiting (don't error if not waiting)
remove_waitee_if_waiting(WhoId, State) ->
    State1 = unregister_waitee(WhoId, false, State),
    {ok, State1}.

%% Checks whether the state of the detector contains a probe or any waitee
is_active(#state{probe = Probe, waitees = Waitees}) ->
    case {Probe, Waitees} of
        {undefined, []} -> false;
        _ -> true
    end.

%% Lock while already locked --- error
lock(_, #state{probe = Probe}) when Probe =/= undefined ->
    error(already_locked);

%% Set lock
lock(Probe, State) ->
    State1 = State#state{probe = Probe},
    ?DDT_DBG_LOCK("~p: Locked!", [State#state.worker]),
    {ok, State1}.

%% Unlock while not locked --- error
unlock(#state{probe = undefined}) ->
    error(unlock_not_locked);

%% Unlock while deadlocked --- error
unlock(#state{deadlocked = {true, DL}}) ->
    error({unlock_deadlocked, DL});

%% Unlock
unlock(State) ->
    State1 = State#state{probe = undefined},
    ?DDT_DBG_LOCK("~p: Unlocked!", [State#state.worker]),
    {ok, State1}.

%% Probe while not locked --- ignore
check_probe(?PROBE(_Probe, _L), State = #state{probe = undefined}) ->
    {ok, State};

%% Own probe returned --- deadlock
check_probe(?PROBE(Probe, DL), State = #state{probe = Probe}) ->
    Worker = State#state.worker,
    ?DDT_WARN_DEADLOCK("~p: Own probe ~p returned! Deadlock detected with path: ~p", [Worker, Probe, [Worker|DL]]),
    {DlProp, State1} = report_deadlock([Worker|DL], State),
    {{send, DlProp}, State1};

%% Foreign probe --- propagate
check_probe(?PROBE(Probe, L), State) ->
    Worker = State#state.worker,
    Waits = State#state.waitees,
    Mons = [ mon_reg:mon_of(Who) || Who <- Waits ],
    Sends = [ {Mon, ?PROBE(Probe, [Worker|L])} || Mon <- Mons ],
    ?DDT_DBG_PROBE("~p: Propagating foreign probe ~p (path: ~p) to ~p monitors", [Worker, Probe, [Worker|L], length(Sends)]),
    Resp = case Sends of [] -> ok; _ -> {send, Sends} end,
    {Resp, State}.

%% Deadlock propagation --- not even locked 
propagate_deadlock(?DEADLOCK_PROP(DL), #state{probe = undefined}) ->
    error({deadlock_not_locked, DL});

%% Deadlock propagation --- propagate and become deadlocked
propagate_deadlock(?DEADLOCK_PROP(DL), State = #state{deadlocked = false}) ->
    {DlProp, State1} = report_deadlock(DL, State),
    {{send, DlProp}, State1};

%% Deadlock propagation while deadlocked --- ignore
propagate_deadlock(?DEADLOCK_PROP(_DL), State) ->
    {ok, State}.


%% Deadlock subscription while deadlocked --- reply immediately
subscribe(From, State = #state{deadlocked = {true, DL}}) ->
    gen_statem:reply(From, {deadlock, DL}),
    State;

%% Deadlock subscription --- add subscriber
subscribe(From, State = #state{deadlocked = false}) ->
    State#state{subscribers = [From | State#state.subscribers]}.

%% Deadlock unsubscription --- remove subscriber
unsubscribe(From, State = #state{subscribers = Subs}) ->
    NewSubs = lists:delete(From, Subs),
    State#state{subscribers = NewSubs}.

%%%======================
%% Private functions
%%%======================

get_waitee(Who, State = #state{reqid_map = WaitsRev}) when is_reference(Who) ->
    case maps:find(Who, WaitsRev) of
        {ok, WhoName} -> get_waitee(WhoName, State);
        _ -> undefined
    end;
get_waitee(Who, #state{waitees = Waits}) ->
    case lists:member(Who, Waits) of
        true -> {ok, Who};
        _ -> undefined
    end.

register_waitee(Who, ReqId, State) ->
    case mon_reg:mon_of(Who) of
        undefined -> State;
        _ -> register_monitored_waitee(Who, ReqId, State)
    end.
register_monitored_waitee(Who, ReqId, State = #state{waitees = Waits, reqid_map = ReqMap}) ->
    case get_waitee(Who, State) of
        {ok, _} -> error({already_waiting, Who});
        _ -> ok
    end,
    State#state{
      waitees = [Who|Waits],
      reqid_map = ReqMap#{ReqId=>Who}
     }.

unregister_waitee(Who, MustWait, State) ->
    case mon_reg:mon_of(Who) of
        undefined -> State;
        _ -> unregister_monitored_waitee(Who, MustWait, State)
    end.
unregister_monitored_waitee(Who, MustWait,  State = #state{waitees = Waits, reqid_map = ReqMap}) ->
    case get_waitee(Who, State) of
        undefined -> 
            case MustWait of
                true -> error({not_waiting, Who});
                false -> State
            end;
        {ok, WhoName} ->
            NewWaits = lists:delete(WhoName, Waits),
            NewReqMap = maps:filter(fun(_K, V) -> V =/= WhoName end, ReqMap),
            State#state{waitees = NewWaits, reqid_map = NewReqMap}
    end.
                                              
foreign_deadlock({foreign, DL}) ->
    {foreign, DL};
foreign_deadlock(DL) ->
    {foreign, DL}.
    
report_deadlock(DL, State) ->
    %% Notify waitees
    Sends = [ begin
                  Mon = mon_reg:mon_of(Pid),
                  {Mon, ?DEADLOCK_PROP(foreign_deadlock(DL))}
              end
              || Pid <- State#state.waitees
            ],

    %% Notify subscribers
    [ begin
          gen_statem:reply(From, {deadlock, DL})
      end
     || From <- State#state.subscribers
    ],
    
    %% Set deadlocked flag. Clear subscribers, so they are notified only once.
    %% We do it directly from the state, because we don't care about message
    %% ordering anymore (we are deadlocked, and will remain so).
    State1 = State#state{
               deadlocked = {true, DL},          
               subscribers = []
              },
    
    {Sends, State1}.

