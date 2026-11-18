%% Driver for one client node (a separate OS process). It contacts the
%% coordinator on the engine node, receives its slice of the user id range,
%% spawns one reddit_user process per simulated user, steps them through the
%% register / join / run phases on the coordinator's signal, and sends the
%% merged measurements back.
%%
%% Start manually on any machine that can reach the engine node:
%%   erl -sname c1 -setcookie reddit -pa ebin -noshell -run reddit_sim main engine@HOST
-module(reddit_sim).
-export([main/1, start/1]).

main([EngineNode]) ->
    start(list_to_atom(EngineNode)).

start(EngineNode) ->
    spawn(fun() -> run(EngineNode) end).

run(EngineNode) ->
    true = net_kernel:connect_node(EngineNode),
    Relay = spawn(fun relay/0),
    register(reddit_relay, Relay),
    Coord = {reddit_coord, EngineNode},
    Coord ! {hello, self(), node()},
    {Idx, Cfg} = receive {welcome, I, C} -> {I, C} end,
    #{users := N, clients := K, subs := Subs, zipf_s := Zs, workers := W} = Cfg,
    persistent_term:put(reddit_zipf, reddit_zipf:new(Subs, Zs)),
    Conn = reddit_client:conn(EngineNode, W),
    {First, Last} = slice(Idx, N, K),
    Pids = [reddit_user:start(self(), Conn, Id, Cfg) || Id <- lists:seq(First, Last)],
    Count = length(Pids),
    Crash0 = barrier(registered, Count, 0),
    Coord ! {registered, Idx},
    receive {phase, join} -> ok end,
    [P ! {phase, join} || P <- Pids],
    Crash1 = barrier(joined, Count - Crash0, Crash0),
    Coord ! {joined, Idx},
    DurationMs = receive {go, Ms} -> Ms end,
    [P ! {go, DurationMs} || P <- Pids],
    {Stats, Cnt, Done, Crash2, Unfinished} =
        collect(Count - Crash1, DurationMs + 60000, #{}, #{}, 0, Crash1),
    Coord ! {done, Idx, #{node => node(), users => Count, finished => Done,
                          crashed => Crash2, unfinished => Unfinished,
                          stats => Stats, cnt => Cnt,
                          memory => erlang:memory(total)}},
    receive halt -> ok after 300000 -> ok end,
    erlang:halt(case Unfinished of 0 -> 0; _ -> 1 end).

%% Users First..Last for client Idx (1-based) of K.
slice(Idx, N, K) ->
    Base = N div K,
    Extra = N rem K,
    First = (Idx - 1) * Base + min(Idx - 1, Extra) + 1,
    Size = Base + case Idx =< Extra of true -> 1; false -> 0 end,
    {First, First + Size - 1}.

%% Wait until N users have reported Tag; crashed users count as reported.
barrier(_Tag, N, Crashed) when N =< 0 ->
    Crashed;
barrier(Tag, N, Crashed) ->
    receive
        {Tag, _Pid} -> barrier(Tag, N - 1, Crashed);
        {user_crashed, _Pid, Info} ->
            report_crash(Info),
            barrier(Tag, N - 1, Crashed + 1)
    after 300000 ->
            error({barrier_timeout, Tag, N})
    end.

collect(0, _T, Stats, Cnt, Done, Crashed) ->
    {Stats, Cnt, Done, Crashed, 0};
collect(N, T, Stats, Cnt, Done, Crashed) ->
    receive
        {user_done, _Pid, S, C} ->
            collect(N - 1, T, reddit_stats:merge(Stats, S),
                    reddit_stats:merge_counts(Cnt, C), Done + 1, Crashed);
        {user_crashed, _Pid, Info} ->
            report_crash(Info),
            collect(N - 1, T, Stats, Cnt, Done, Crashed + 1)
    after T ->
            {Stats, Cnt, Done, Crashed, N}
    end.

report_crash(Info) ->
    io:format("~p: simulated user crashed: ~P~n", [node(), Info, 30]).

%% Forwards a batched push from the engine to the local user processes.
relay() ->
    receive
        {relay, Pids, Msg} -> [P ! Msg || P <- Pids]
    end,
    relay().
