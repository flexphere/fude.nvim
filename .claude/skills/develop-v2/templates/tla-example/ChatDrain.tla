------------------------------ MODULE ChatDrain ------------------------------
(***************************************************************************)
(* Model of lua/fude/chat.lua: send / cancel / drain / waiting / retry.    *)
(* One review target (one claude session). Each Neovim callback is one     *)
(* atomic step (the main loop runs them one at a time).                    *)
(*                                                                         *)
(* Example model for /develop-v2 (from the prototype in issue #340).       *)
(* GuardDraining = TRUE models the code (send waits while a cancelled      *)
(* process drains); ChatDrain_unguarded.cfg sets it FALSE to check that    *)
(* OneWriterUnlessKilled then fails (the model is not too weak).           *)
(*   python3 -I run-tlc.py ChatDrain.tla --allow-deadlock                  *)
(* (--allow-deadlock: Jobs/MaxProcs are bounded, so the last state stops.) *)
(***************************************************************************)
EXTENDS Naturals, FiniteSets

CONSTANTS Jobs,        \* questions the user may send, e.g. {1,2,3}
          MaxProcs,    \* bound on processes started (state space)
          None,
          GuardDraining \* TRUE: Send waits while draining (the guard);
                        \* FALSE: the guard is removed (ChatDrain_unguarded.cfg)

Pids == 1..MaxProcs

VARIABLES
    running,    \* job being answered, or None              (chat.lua: running)
    draining,   \* pid sent SIGTERM and not exited, or None (chat.lua: draining)
    waiting,    \* job whose start waits for the drain      (chat.lua: waiting)
    jobState,   \* [Jobs -> {"new","pending","started","finished"}]
    jobToken,   \* [Jobs -> Pids \cup {None}]                (job.token / job.handle)
    retried,    \* [Jobs -> BOOLEAN]
    proc,       \* [Pids -> {"none","alive","term","killed","exited","gone"}]
    owner,      \* [Pids -> Jobs \cup {None}]
    nextPid,
    timers      \* set of [pid, stage \in {"drain","kill"}]  (vim.defer_fn)

vars == <<running, draining, waiting, jobState, jobToken, retried,
          proc, owner, nextPid, timers>>

Init ==
    /\ running = None /\ draining = None /\ waiting = None
    /\ jobState = [j \in Jobs |-> "new"]
    /\ jobToken = [j \in Jobs |-> None]
    /\ retried  = [j \in Jobs |-> FALSE]
    /\ proc  = [p \in Pids |-> "none"]
    /\ owner = [p \in Pids |-> None]
    /\ nextPid = 1
    /\ timers = {}

(* start_process(job): a new process with its own token. *)
CanStart == nextPid <= MaxProcs
StartProcFrom(j, js, pr) ==
    /\ proc'     = [pr EXCEPT ![nextPid] = "alive"]
    /\ owner'    = [owner EXCEPT ![nextPid] = j]
    /\ jobToken' = [jobToken EXCEPT ![j] = nextPid]
    /\ jobState' = [js EXCEPT ![j] = "started"]
    /\ nextPid'  = nextPid + 1
StartProc(j, js) == StartProcFrom(j, js, proc)

(* M.send *)
Send(j) ==
    /\ running = None
    /\ jobState[j] = "new"
    /\ CanStart
    /\ running' = j
    /\ IF GuardDraining /\ draining # None
       THEN /\ waiting' = j
            /\ jobState' = [jobState EXCEPT ![j] = "pending"]
            /\ UNCHANGED <<proc, owner, jobToken, nextPid>>
       ELSE /\ StartProc(j, jobState)
            /\ UNCHANGED waiting
    /\ UNCHANGED <<draining, retried, timers>>

(* M.cancel: SIGTERM, draining = token, arm the drain timer, finish. *)
Cancel ==
    /\ running # None
    /\ LET j == running IN
       /\ IF jobToken[j] # None
          THEN LET p == jobToken[j] IN
               /\ proc' = [proc EXCEPT ![p] = IF @ = "alive" THEN "term" ELSE @]
               /\ draining' = p
               /\ timers' = timers \cup {[pid |-> p, stage |-> "drain"]}
          ELSE UNCHANGED <<proc, draining, timers>>
       /\ jobState' = [jobState EXCEPT ![j] = "finished"]
       /\ running' = None
    /\ UNCHANGED <<waiting, jobToken, retried, owner, nextPid>>

(* The OS: a process ends. An alive one finishes its answer; one sent       *)
(* SIGTERM or SIGKILL exits. A killed one MAY never exit (no fairness):     *)
(* that is the case KILL_TIMEOUT_MS gives up on.                            *)
OsExit(p) ==
    /\ proc[p] \in {"alive", "term", "killed"}
    /\ proc' = [proc EXCEPT ![p] = "exited"]
    /\ UNCHANGED <<running, draining, waiting, jobState, jobToken, retried,
                   owner, nextPid, timers>>

(* end_drain(token), as a state transformer over the values given. *)
EndDrain(p, js, pr) ==
    IF draining = p
    THEN /\ draining' = None
         /\ waiting' = None
         /\ IF waiting # None /\ js[waiting] # "finished" /\ CanStart
            THEN StartProcFrom(waiting, js, pr)
            ELSE /\ jobState' = js /\ proc' = pr
                 /\ UNCHANGED <<owner, jobToken, nextPid>>
    ELSE /\ UNCHANGED <<draining, waiting, owner, jobToken, nextPid>>
         /\ jobState' = js /\ proc' = pr

(* The exit callback (vim.schedule after the process ended). *)
ExitCallback(p) ==
    /\ proc[p] = "exited"
    /\ LET j == owner[p] IN
       IF jobState[j] = "finished" \/ jobToken[j] # p
       THEN /\ EndDrain(p, jobState, [proc EXCEPT ![p] = "gone"])
            /\ UNCHANGED <<running, retried, timers>>
       ELSE \* handle_exit: done/error, or one retry with a new process
            \/ /\ ~retried[j] /\ CanStart /\ draining # p
               /\ retried' = [retried EXCEPT ![j] = TRUE]
               /\ proc'     = [proc EXCEPT ![p] = "gone", ![nextPid] = "alive"]
               /\ owner'    = [owner EXCEPT ![nextPid] = j]
               /\ jobToken' = [jobToken EXCEPT ![j] = nextPid]
               /\ nextPid'  = nextPid + 1
               /\ UNCHANGED <<running, draining, waiting, jobState, timers>>
            \/ /\ running' = None
               /\ proc' = [proc EXCEPT ![p] = "gone"]
               /\ jobState' = [jobState EXCEPT ![j] = "finished"]
               /\ UNCHANGED <<draining, waiting, jobToken, retried, owner,
                              nextPid, timers>>

(* DRAIN_TIMEOUT_MS: still draining -> SIGKILL, arm the kill timer. *)
DrainTimer(t) ==
    /\ t \in timers /\ t.stage = "drain"
    /\ timers' = (timers \ {t}) \cup
                 (IF draining = t.pid THEN {[pid |-> t.pid, stage |-> "kill"]} ELSE {})
    /\ proc' = IF draining = t.pid /\ proc[t.pid] \in {"alive","term"}
               THEN [proc EXCEPT ![t.pid] = "killed"] ELSE proc
    /\ UNCHANGED <<running, draining, waiting, jobState, jobToken, retried,
                   owner, nextPid>>

(* KILL_TIMEOUT_MS: give up waiting for the exit; end_drain(token). *)
KillTimer(t) ==
    /\ t \in timers /\ t.stage = "kill"
    /\ timers' = timers \ {t}
    /\ EndDrain(t.pid, jobState, proc)
    /\ UNCHANGED <<running, retried>>

Next ==
    \/ \E j \in Jobs : Send(j)
    \/ Cancel
    \/ \E p \in Pids : OsExit(p) \/ ExitCallback(p)
    \/ \E t \in timers : DrainTimer(t) \/ KillTimer(t)

\* Weak fairness on everything the system does by itself, except the exit of
\* a SIGKILLed process (it may hang in the kernel).
Fairness ==
    /\ \A p \in Pids : WF_vars(ExitCallback(p))
    /\ \A p \in Pids : WF_vars(proc[p] = "term" /\ OsExit(p))
    /\ WF_vars(\E t \in timers : DrainTimer(t) \/ KillTimer(t))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ running \in Jobs \cup {None}
    /\ draining \in Pids \cup {None}
    /\ waiting \in Jobs \cup {None}

\* Processes that may still write the claude session.
Live == {p \in Pids : proc[p] \in {"alive", "term", "killed"}}

\* Strict: never two such processes at once.
OneWriter == Cardinality(Live) <= 1

\* Relaxed: two only when one of them got SIGKILL and has not exited (the
\* case KILL_TIMEOUT_MS deliberately gives up on).
OneWriterUnlessKilled ==
    Cardinality({p \in Live : proc[p] # "killed"}) <= 1

\* A waiting question always has a drain that will release it.
WaitingHasDrain == waiting # None => draining # None

\* A waiting question eventually starts or is cancelled.
WaitingEventuallyLeaves == \A j \in Jobs :
    (jobState[j] = "pending") ~> (jobState[j] # "pending")
=============================================================================
