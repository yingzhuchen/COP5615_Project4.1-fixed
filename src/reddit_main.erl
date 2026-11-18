%% Entry point for the engine node. Starts the engine, then coordinates the
%% client nodes through three phases (register, join, run) and writes the
%% performance report.
%%
%%   mode local  (default): spawns `clients` client nodes itself, each a
%%                          separate OS process started with the peer module.
%%   mode engine          : only starts the engine and waits for `clients`
%%                          externally started reddit_sim nodes.
%%
%% Usage (all options are optional, key value pairs):
%%   erl -sname engine -setcookie reddit -pa ebin -noshell \
%%       -run reddit_main main users 10000 clients 4 duration 60
-module(reddit_main).
-export([main/1, run/1, defaults/0]).

defaults() ->
    #{users => 5000,          % simulated users in total
      clients => 4,           % client OS processes
      subs => 100,            % subreddits (Zipf ranks)
      zipf_s => 1.0,          % Zipf exponent
      subs_per_user => 3,     % average subs a user joins
      duration => 30,         % seconds of simulated activity
      think_ms => 1000,       % mean time between actions of an online user
      online_ms => 20000,     % mean length of an online period
      offline_ms => 10000,    % mean length of an offline period
      stagger_ms => 3000,     % users that start online log in within this window
      repost => 0.1,          % share of posts that are reposts
      feed_limit => 25,
      push_posts => false,    % push every new post to online sub members
      workers => erlang:system_info(schedulers_online) * 2,
      seed => 42,
      mode => local,
      out => "results",
      mix => [{feed, 20}, {vote, 30}, {comment, 18}, {post, 10}, {view_post, 8},
              {dm, 4}, {inbox, 6}, {karma, 2}, {churn, 2}]}.

main(Args) ->
    Opts = parse(Args, defaults()),
    spawn(fun() ->
                  try run(Opts)
                  catch C:E:St ->
                          io:format("fatal: ~p:~p~n~p~n", [C, E, St]),
                          erlang:halt(1)
                  end
          end).

run(Opts) ->
    node() =/= nonode@nohost orelse error(start_erl_with_sname),
    #{clients := K, workers := W, mode := Mode} = Opts,
    ok = reddit_engine:start(W, Opts),
    register(reddit_coord, self()),
    io:format("engine ~p up with ~p workers; ~p users on ~p client nodes~n",
              [node(), W, maps:get(users, Opts), K]),
    case Mode of
        local -> [spawn_client(I) || I <- lists:seq(1, K)];
        engine -> io:format("waiting for ~p reddit_sim client nodes...~n", [K])
    end,
    {Report, Dones} = coordinate(Opts),
    io:put_chars(Report),
    File = filename:join(maps:get(out, Opts),
                         io_lib:format("run_~wu_~wc_~ws_~w.txt",
                                       [maps:get(users, Opts), K,
                                        maps:get(duration, Opts),
                                        os:system_time(second)])),
    ok = filelib:ensure_dir(File),
    ok = file:write_file(File, Report),
    io:format("~nreport written to ~s~n", [File]),
    timer:sleep(500),
    Unfinished = lists:sum([maps:get(unfinished, D, 0) || D <- Dones]),
    erlang:halt(case Unfinished of 0 -> 0; _ -> 1 end).

spawn_client(I) ->
    Ebin = filename:dirname(code:which(?MODULE)),
    Name = list_to_atom("client" ++ integer_to_list(I) ++ "_" ++
                            integer_to_list(erlang:unique_integer([positive]))),
    {ok, _Peer, Node} =
        peer:start(#{name => Name,
                     args => ["-setcookie", atom_to_list(erlang:get_cookie()),
                              "-pa", Ebin, "+zdbbl", "32768"]}),
    _ = reddit_sim_starter(Node),
    Node.

reddit_sim_starter(Node) ->
    erpc:call(Node, reddit_sim, start, [node()]).

coordinate(Opts) ->
    #{clients := K, duration := Dur} = Opts,
    T0 = now_ms(),
    Sims = [receive {hello, Pid, _Node} ->
                    Pid ! {welcome, I, Opts},
                    Pid
            end || I <- lists:seq(1, K)],
    T1 = now_ms(),
    wait_all(registered, K),
    T2 = now_ms(),
    [S ! {phase, join} || S <- Sims],
    wait_all(joined, K),
    T3 = now_ms(),
    reddit_engine:reset_stats(),
    io:format("setup done (register ~w ms, join ~w ms); running for ~w s...~n",
              [T2 - T1, T3 - T2, Dur]),
    [S ! {go, Dur * 1000} || S <- Sims],
    Dones = [receive {done, _I, D} -> D end || _ <- Sims],
    T4 = now_ms(),
    EngineStats = reddit_engine:collect_stats(),
    Report = reddit_report:build(Opts, #{dones => Dones,
                                         connect_ms => T1 - T0,
                                         register_ms => T2 - T1,
                                         join_ms => T3 - T2,
                                         run_ms => T4 - T3,
                                         engine_stats => EngineStats}),
    [S ! halt || S <- Sims],
    {Report, Dones}.

wait_all(Tag, K) ->
    [receive {Tag, _} -> ok end || _ <- lists:seq(1, K)],
    ok.

now_ms() -> erlang:monotonic_time(millisecond).

%% "key value" pairs; values take the type of the default.
parse([K, V | Rest], Acc) ->
    Key = list_to_atom(K),
    maps:is_key(Key, Acc) orelse error({unknown_option, K}),
    parse(Rest, Acc#{Key => convert(maps:get(Key, Acc), V)});
parse([], Acc) ->
    Acc;
parse([K], _) ->
    error({missing_value, K}).

convert(D, V) when is_integer(D) -> list_to_integer(V);
convert(D, V) when is_float(D) ->
    try list_to_float(V) catch error:badarg -> float(list_to_integer(V)) end;
convert(D, V) when is_boolean(D) -> list_to_atom(V) =:= true;
convert(D, V) when is_atom(D) -> list_to_atom(V);
convert(_, V) -> V.
