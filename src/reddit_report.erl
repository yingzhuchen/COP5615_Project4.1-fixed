%% Builds the text performance report from client measurements, engine
%% counters and the final engine state.
-module(reddit_report).
-include("reddit.hrl").
-export([build/2]).

-define(OPS, [connect, disconnect, post, repost, comment, vote, get_feed, get_post,
              send_dm, reply_dm, get_dms, get_karma, join_sub, leave_sub]).

build(Opts, Run) ->
    #{dones := Dones, engine_stats := ES, run_ms := RunMs} = Run,
    Stats = lists:foldl(fun(#{stats := S}, A) -> reddit_stats:merge(A, S) end, #{}, Dones),
    Cnt = lists:foldl(fun(#{cnt := C}, A) -> reddit_stats:merge_counts(A, C) end, #{}, Dones),
    Secs = RunMs / 1000,
    TotalReq = lists:sum([C || {C, _, _, _} <- maps:values(Stats)]),
    EngineReq = lists:sum([C || {C, _} <- maps:values(ES)]),
    iolist_to_binary(
      [header("Reddit engine simulation report"),
       config(Opts, Dones),
       section("Setup"),
       fmt("clients say hello ~w ms, register users+subs ~w ms, join subs ~w ms~n",
           [maps:get(connect_ms, Run), maps:get(register_ms, Run), maps:get(join_ms, Run)]),
       section("Throughput (run phase)"),
       fmt("wall time                ~.1f s~n", [Secs]),
       fmt("client requests          ~w  (~w req/s)~n", [TotalReq, round(TotalReq / Secs)]),
       fmt("engine requests handled  ~w  (~w req/s)~n", [EngineReq, round(EngineReq / Secs)]),
       fmt("user actions             ~w~n", [maps:get(actions, Cnt, 0)]),
       latency_table(Stats, ES),
       errors(Cnt),
       live(Cnt, Opts, Secs),
       content(),
       zipf(Opts),
       resources(Dones)]).

config(Opts, Dones) ->
    Keys = [users, clients, subs, zipf_s, subs_per_user, duration, think_ms,
            online_ms, offline_ms, stagger_ms, repost, push_posts, workers, feed_limit, seed],
    [section("Configuration"),
     [fmt("~-14s ~p~n", [K, maps:get(K, Opts)]) || K <- Keys],
     fmt("~-14s ~s~n", [client_nodes, lists:join(", ", [atom_to_list(N) || #{node := N} <- Dones])]),
     fmt("~-14s ~p (OTP ~s, ~w schedulers)~n",
         [engine_node, node(), erlang:system_info(otp_release),
          erlang:system_info(schedulers_online)])].

latency_table(Stats, ES) ->
    [section("Latency per operation (client round trip; engine = service time)"),
     fmt("~-11s ~9s ~9s ~8s ~8s ~8s ~9s ~10s~n",
         ["op", "count", "avg us", "p50", "p95", "p99", "max", "engine us"]),
     [begin
          V = maps:get(Op, Stats),
          {EC, ET} = maps:get(Op, ES, {0, 0}),
          EAvg = case EC of 0 -> 0.0; _ -> ET / EC end,
          fmt("~-11s ~9w ~9w ~8w ~8w ~8w ~9w ~10.1f~n",
              [Op, element(1, V), round(reddit_stats:avg(V)),
               reddit_stats:percentile(V, 0.50), reddit_stats:percentile(V, 0.95),
               reddit_stats:percentile(V, 0.99), element(3, V), EAvg])
      end || Op <- ?OPS, maps:is_key(Op, Stats)],
     all_row(Stats)].

all_row(Stats) ->
    case maps:values(Stats) of
        [] -> [];
        Vs ->
            M = reddit_stats:combine(Vs),
            fmt("~-11s ~9w ~9w ~8w ~8w ~8w ~9w~n",
                ["ALL", element(1, M), round(reddit_stats:avg(M)),
                 reddit_stats:percentile(M, 0.50), reddit_stats:percentile(M, 0.95),
                 reddit_stats:percentile(M, 0.99), element(3, M)])
    end.

errors(Cnt) ->
    Errs = lists:sort([{Op, E, N} || {{error, Op, E}, N} <- maps:to_list(Cnt)]),
    [section("Errors returned to clients"),
     case Errs of
         [] -> "none\n";
         _ -> [fmt("~-11s ~-16s ~w~n", [Op, E, N]) || {Op, E, N} <- Errs]
     end].

live(Cnt, Opts, Secs) ->
    Users = maps:get(users, Opts),
    OnlineMs = maps:get(online_ms, Cnt, 0),
    Frac = OnlineMs / (Users * Secs * 1000),
    [section("Live connections"),
     fmt("connects ~w, disconnects ~w, avg time online ~.1f%~n",
         [maps:get(connects, Cnt, 0), maps:get(disconnects, Cnt, 0), 100 * Frac]),
     fmt("pushes received: dm ~w, reply ~w, new_post ~w~n",
         [maps:get(push_dm, Cnt, 0), maps:get(push_reply, Cnt, 0), maps:get(push_post, Cnt, 0)]),
     fmt("pushes sent by engine: dm ~w, reply ~w, new_post ~w~n",
         [reddit_ops:counter(push_dm), reddit_ops:counter(push_reply),
          reddit_ops:counter(push_post)])].

content() ->
    {Posts, Reposts} = ets:foldl(fun({_, #post{repost_of = undefined}}, {P, R}) -> {P + 1, R};
                                    ({_, _}, {P, R}) -> {P + 1, R + 1} end,
                                 {0, 0}, reddit_posts),
    MaxDepth = ets:foldl(fun({_, #comment{depth = D}}, M) -> max(D, M) end, 0, reddit_comments),
    [section("Engine content at end of run"),
     fmt("users ~w, subreddits ~w, memberships ~w~n",
         [tsize(reddit_users), tsize(reddit_subs), tsize(reddit_user_subs)]),
     fmt("posts ~w (reposts ~w = ~.1f%), comments ~w (max depth ~w), votes ~w, dms ~w~n",
         [Posts, Reposts, pct(Reposts, Posts), tsize(reddit_comments), MaxDepth,
          tsize(reddit_votes), tsize(reddit_dms)]),
     fmt("users still marked online ~w~n", [tsize(reddit_online)])].

zipf(#{subs := N, zipf_s := S}) ->
    PerSub = ets:foldl(fun({_, #post{sub = Sb, repost_of = R}}, A) ->
                               {P, Rp} = maps:get(Sb, A, {0, 0}),
                               A#{Sb => {P + 1, Rp + case R of undefined -> 0; _ -> 1 end}}
                       end, #{}, reddit_posts),
    Rows = [{K, reddit_ops:sub_member_count(Sub), maps:get(Sub, PerSub, {0, 0})}
            || K <- lists:seq(1, N), Sub <- [reddit_user:sub_name(K)]],
    {_, M1, _} = hd(Rows),
    Show = [R || {K, _, _} = R <- Rows,
                 K =< 10 orelse lists:member(K, [20, 30, 50, 75, 100, 200, 500, 1000])],
    [section("Zipf check: subreddit members and posts by rank"),
     fmt("fitted exponent: members ~.2f, posts ~.2f (configured s = ~.2f)~n",
         [fit([{K, M} || {K, M, _} <- Rows]), fit([{K, P} || {K, _, {P, _}} <- Rows]), S]),
     fmt("~-6s ~-8s ~9s ~11s ~9s ~9s~n",
         ["rank", "sub", "members", "ideal M1/k^s", "posts", "reposts"]),
     [fmt("~-6w ~-8s ~9w ~11w ~9w ~9w~n",
          [K, reddit_user:sub_name(K), M, round(M1 / math:pow(K, S)), P, Rp])
      || {K, M, {P, Rp}} <- Show]].

%% Least-squares slope of log(value) against log(rank), negated.
fit(Pairs) ->
    Pts = [{math:log(K), math:log(V)} || {K, V} <- Pairs, V > 0],
    case length(Pts) of
        N when N < 2 -> 0.0;
        N ->
            Mx = lists:sum([X || {X, _} <- Pts]) / N,
            My = lists:sum([Y || {_, Y} <- Pts]) / N,
            Sxy = lists:sum([(X - Mx) * (Y - My) || {X, Y} <- Pts]),
            Sxx = lists:sum([(X - Mx) * (X - Mx) || {X, _} <- Pts]),
            -Sxy / Sxx
    end.

resources(Dones) ->
    [section("Resources"),
     fmt("engine node memory ~.1f MB (ETS tables ~.1f MB), processes ~w~n",
         [mb(erlang:memory(total)), mb(reddit_store:memory_bytes()),
          erlang:system_info(process_count)]),
     fmt("client nodes memory ~.1f MB total~n",
         [mb(lists:sum([M || #{memory := M} <- Dones]))]),
     fmt("simulated users finished ~w, crashed ~w~n",
         [lists:sum([F || #{finished := F} <- Dones]),
          lists:sum([C || #{crashed := C} <- Dones])]),
     fmt("simulated users unfinished ~w~n",
         [lists:sum([U || #{unfinished := U} <- Dones])])].

tsize(T) -> ets:info(T, size).
pct(_, 0) -> 0.0;
pct(A, B) -> 100 * A / B.
mb(B) -> B / 1048576.

header(T) -> [T, "\n", lists:duplicate(length(T), $=), "\n"].
section(T) -> ["\n", T, "\n", lists:duplicate(length(T), $-), "\n"].
fmt(F, A) -> io_lib:format(F, A).
