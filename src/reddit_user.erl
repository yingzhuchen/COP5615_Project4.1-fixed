%% One simulated Reddit user (one Erlang process on a client node).
%%
%% Lifecycle:
%%   1. register (users 1..Subs also create subreddit r_<id>), tell the sim;
%%   2. on {phase, join}: join 1..(2*subs_per_user - 1) subreddits sampled
%%      from a Zipf distribution, so subreddit member counts follow Zipf;
%%   3. on {go, Ms}: alternate online / offline periods (exponentially
%%      distributed lengths) for Ms milliseconds. While online the user acts
%%      every ~think_ms and receives live pushes; on reconnect it catches up
%%      with its feed and inbox;
%%   4. report its latency stats and counters to the sim.
%%
%% Posting is biased toward popular subreddits: the target sub is chosen
%% among the user's subs with weight 1/rank^s, so the big subs get far more
%% posts. A share of posts (repost option) are reposts of posts seen earlier.
-module(reddit_user).
-export([start/4, name/1, sub_name/1]).

-record(u, {id, name, conn, sim, cfg, zipf,
            subs = [],          % ranks of joined subs
            online = false,
            online_since = 0,
            gen = 0,            % invalidates timers from an earlier period
            posts = [],         % recently seen post ids
            comments = [],      % recently seen comment ids
            pending_dms = [],   % dm ids waiting for a reply
            replied_dms = [],   % dm ids already answered
            last_dm = 0,
            nposts = 0,
            stats = #{},
            cnt = #{}}).

-define(KEEP, 30).
-define(WORDS, {<<"erlang">>, <<"actor">>, <<"reddit">>, <<"karma">>, <<"post">>,
                <<"thread">>, <<"node">>, <<"message">>, <<"vote">>, <<"feed">>,
                <<"comment">>, <<"distributed">>, <<"system">>, <<"process">>,
                <<"beam">>, <<"otp">>, <<"latency">>, <<"zipf">>, <<"today">>,
                <<"great">>, <<"why">>, <<"how">>, <<"anyone">>, <<"else">>}).

name(Id) -> <<"u", (integer_to_binary(Id))/binary>>.
sub_name(K) -> <<"r_", (integer_to_binary(K))/binary>>.

start(Sim, Conn, Id, Cfg) ->
    spawn(fun() ->
                  try init(Sim, Conn, Id, Cfg)
                  catch C:E:St -> Sim ! {user_crashed, self(), {C, E, St}}
                  end
          end).

init(Sim, Conn, Id, Cfg) ->
    rand:seed(exsss, {Id, maps:get(seed, Cfg), 1}),
    S0 = #u{id = Id, name = name(Id), conn = Conn, sim = Sim, cfg = Cfg,
            zipf = persistent_term:get(reddit_zipf)},
    {_, S1} = req(register, {register, S0#u.name}, S0),
    S2 = case Id =< maps:get(subs, Cfg) of
             true ->
                 {_, X} = req(create_sub, {create_sub, S1#u.name, sub_name(Id)}, S1),
                 X#u{subs = [Id]};
             false ->
                 S1
         end,
    Sim ! {registered, self()},
    receive {phase, join} -> ok end,
    S3 = join_initial(S2),
    Sim ! {joined, self()},
    receive {go, DurationMs} -> ok end,
    erlang:send_after(DurationMs, self(), stop),
    S4 = S3#u{stats = #{}, cnt = #{}},           % measure the run phase only
    On = cfg(online_ms, S4),
    Off = cfg(offline_ms, S4),
    G = S4#u.gen + 1,
    case rand:uniform() < On / (On + Off) of
        true ->   % log in at a random moment of the first few seconds
            erlang:send_after(rand:uniform(cfg(stagger_ms, S4)), self(), {toggle, G});
        false ->
            erlang:send_after(exp_ms(Off), self(), {toggle, G})
    end,
    loop(S4#u{gen = G}).

join_initial(S) ->
    Avg = cfg(subs_per_user, S),
    J = rand:uniform(max(1, 2 * Avg - 1)),
    Ranks = reddit_zipf:sample_distinct(J, S#u.zipf),
    lists:foldl(fun(K, Acc) -> join(K, Acc) end, S, Ranks).

join(K, S) ->
    case req(join_sub, {join_sub, S#u.name, sub_name(K)}, S) of
        {ok_like, S1} -> S1#u{subs = [K | lists:delete(K, S1#u.subs)]};
        {_, S1} -> S1
    end.

%% ---------------------------------------------------------------- run loop

loop(S) ->
    receive
        {reddit_push, Msg} ->
            loop(on_push(Msg, S));
        {tick, G} when G =:= S#u.gen ->
            S1 = act(S),
            erlang:send_after(exp_ms(cfg(think_ms, S)), self(), {tick, G}),
            loop(S1);
        {tick, _Stale} ->
            loop(S);
        {toggle, G} when G =:= S#u.gen ->
            loop(case S#u.online of
                     true -> go_offline(S);
                     false -> go_online(S)
                 end);
        {toggle, _Stale} ->
            loop(S);
        stop ->
            finish(S)
    end.

go_online(S0) ->
    G = S0#u.gen + 1,
    S = S0#u{gen = G, online = true, online_since = now_ms(),
             cnt = reddit_stats:bump(connects, S0#u.cnt)},
    {_, S1} = req(connect, {connect, S#u.name, self()}, S),
    S2 = do_inbox(do_feed(S1)),                 % catch up on what was missed
    erlang:send_after(exp_ms(cfg(think_ms, S)), self(), {tick, G}),
    erlang:send_after(exp_ms(cfg(online_ms, S)), self(), {toggle, G}),
    S2.

go_offline(S0) ->
    G = S0#u.gen + 1,
    S = case S0#u.online of
            true ->
                {_, X} = req(disconnect, {disconnect, S0#u.name}, S0),
                add_online_time(X#u{cnt = reddit_stats:bump(disconnects, X#u.cnt)});
            false ->
                S0
        end,
    erlang:send_after(exp_ms(cfg(offline_ms, S)), self(), {toggle, G}),
    S#u{gen = G, online = false}.

%% The final logout is teardown (every user does it at the same instant), so
%% it is not part of the latency measurements.
finish(S) ->
    S1 = case S#u.online of
             true ->
                 _ = reddit_client:call(S#u.conn, S#u.name, {disconnect, S#u.name}),
                 add_online_time(S#u{cnt = reddit_stats:bump(disconnects, S#u.cnt)});
             false -> S
         end,
    S1#u.sim ! {user_done, self(), S1#u.stats, S1#u.cnt}.

add_online_time(S) ->
    S#u{cnt = reddit_stats:bump(online_ms, now_ms() - S#u.online_since, S#u.cnt)}.

on_push({dm, #{id := Id}}, S) ->
    Pending = case lists:member(Id, S#u.replied_dms) of
                  true -> S#u.pending_dms;
                  false -> lists:sublist([Id | S#u.pending_dms], 10)
              end,
    S#u{pending_dms = Pending, cnt = reddit_stats:bump(push_dm, S#u.cnt)};
on_push({reply, #{comment_id := C}}, S) ->
    S#u{comments = keep(C, S#u.comments), cnt = reddit_stats:bump(push_reply, S#u.cnt)};
on_push({new_post, #{id := P}}, S) ->
    S#u{posts = keep(P, S#u.posts), cnt = reddit_stats:bump(push_post, S#u.cnt)};
on_push(_, S) ->
    S.

%% ----------------------------------------------------------------- actions

act(S0) ->
    S = S0#u{cnt = reddit_stats:bump(actions, S0#u.cnt)},
    case pick_weighted(cfg(mix, S)) of
        post -> do_post(S);
        comment -> do_comment(S);
        vote -> do_vote(S);
        feed -> do_feed(S);
        view_post -> do_view_post(S);
        dm -> do_dm(S);
        inbox -> do_inbox(S);
        karma -> element(2, req(get_karma, {get_karma, S#u.name}, S));
        churn -> do_churn(S)
    end.

do_post(#u{subs = []} = S) ->
    do_churn(S);
do_post(S) ->
    Z = S#u.zipf,
    Sub = pick_weighted([{K, reddit_zipf:weight(Z, K)} || K <- S#u.subs]),
    case S#u.posts =/= [] andalso rand:uniform() < cfg(repost, S) of
        true ->
            Orig = pick(S#u.posts),
            {_, S1} = req(repost, {repost, S#u.name, sub_name(Sub), Orig}, S),
            S1;
        false ->
            N = S#u.nposts + 1,
            Title = <<"Post ", (integer_to_binary(N))/binary, " by ", (S#u.name)/binary>>,
            case req(post, {post, S#u.name, sub_name(Sub), Title, text(10, 40)}, S) of
                {{ok, Id}, S1} -> S1#u{nposts = N, posts = keep(Id, S1#u.posts)};
                {_, S1} -> S1
            end
    end.

do_comment(S) ->
    Target = case S#u.comments =/= [] andalso rand:uniform() < 0.5 of
                 true -> pick(S#u.comments);
                 false -> pick(S#u.posts)
             end,
    case Target of
        undefined -> do_feed(S);
        _ ->
            case req(comment, {comment, S#u.name, Target, text(3, 15)}, S) of
                {{ok, Id}, S1} -> S1#u{comments = keep(Id, S1#u.comments)};
                {_, S1} -> S1
            end
    end.

do_vote(S) ->
    case pick(S#u.posts ++ S#u.comments) of
        undefined -> do_feed(S);
        Item ->
            Dir = pick_weighted([{up, 70}, {down, 25}, {none, 5}]),
            element(2, req(vote, {vote, S#u.name, Item, Dir}, S))
    end.

do_feed(S) ->
    Sort = pick_weighted([{hot, 6}, {new, 3}, {top, 1}]),
    case req(get_feed, {get_feed, S#u.name, cfg(feed_limit, S), Sort}, S) of
        {{ok, Posts}, S1} ->
            Ids = [Id || #{id := Id} <- Posts],
            S1#u{posts = lists:sublist(Ids ++ (S1#u.posts -- Ids), ?KEEP)};
        {_, S1} -> S1
    end.

do_view_post(S) ->
    case pick(S#u.posts) of
        undefined -> do_feed(S);
        P ->
            case req(get_post, {get_post, S#u.name, P}, S) of
                {{ok, #{comments := Tree}}, S1} ->
                    Ids = lists:sublist(tree_ids(Tree), 15),
                    S1#u{comments = lists:sublist(Ids ++ (S1#u.comments -- Ids), ?KEEP)};
                {_, S1} -> S1
            end
    end.

do_dm(S) ->
    N = cfg(users, S),
    To = case rand:uniform(N) of
             Id when Id =:= S#u.id -> (Id rem N) + 1;
             Id -> Id
         end,
    element(2, req(send_dm, {send_dm, S#u.name, name(To), text(3, 12)}, S)).

%% Read the inbox; reply to one waiting message.
do_inbox(S) ->
    S2 = case req(get_dms, {get_dms, S#u.name, 20}, S) of
             {{ok, Dms}, S1} ->
                 New = [Id || #{id := Id} <- Dms,
                              Id > S1#u.last_dm,
                              not lists:member(Id, S1#u.replied_dms)],
                 S1#u{last_dm = lists:max([S1#u.last_dm | New]),
                      pending_dms = lists:sublist(lists:usort(New ++ S1#u.pending_dms), 10)};
             {_, S1} -> S1
         end,
    case S2#u.pending_dms of
        [Dm | Rest] when Dm > 0 ->
            case req(reply_dm, {reply_dm, S2#u.name, Dm, text(2, 10)},
                     S2#u{pending_dms = Rest}) of
                {ok, S3} -> S3#u{replied_dms = keep(Dm, S3#u.replied_dms)};
                {_, S3} -> S3
            end;
        _ -> S2
    end.

%% Occasionally leave a sub or join a new one.
do_churn(S) ->
    case S#u.subs =/= [] andalso rand:uniform() < 0.4 of
        true ->
            K = pick(S#u.subs),
            {_, S1} = req(leave_sub, {leave_sub, S#u.name, sub_name(K)}, S),
            S1#u{subs = lists:delete(K, S1#u.subs)};
        false ->
            join(reddit_zipf:sample(S#u.zipf), S)
    end.

%% ----------------------------------------------------------------- helpers

%% Timed request; returns {Reply, State}. Replies are normalised so callers
%% can match {ok, V}; join returns ok_like on success or "already member".
req(Op, Req, S) ->
    T0 = erlang:monotonic_time(microsecond),
    R = try reddit_client:call(S#u.conn, S#u.name, Req)
        catch exit:{timeout, _} -> {error, timeout};
              exit:_ -> {error, call_failed}
        end,
    Dt = erlang:monotonic_time(microsecond) - T0,
    Stats = reddit_stats:record(Op, Dt, S#u.stats),
    {Reply, Cnt} =
        case R of
            ok when Op =:= join_sub -> {ok_like, S#u.cnt};
            {error, already_member} when Op =:= join_sub -> {ok_like, S#u.cnt};
            {error, E} when is_atom(E) -> {R, reddit_stats:bump({error, Op, E}, S#u.cnt)};
            {error, _} -> {R, reddit_stats:bump({error, Op, other}, S#u.cnt)};
            _ -> {R, S#u.cnt}
        end,
    {Reply, S#u{stats = Stats, cnt = Cnt}}.

cfg(Key, #u{cfg = Cfg}) -> maps:get(Key, Cfg).

keep(X, L) -> lists:sublist([X | lists:delete(X, L)], ?KEEP).

pick([]) -> undefined;
pick(L) -> lists:nth(rand:uniform(length(L)), L).

pick_weighted(L) ->
    Total = lists:sum([W || {_, W} <- L]),
    pw(L, rand:uniform() * Total).

pw([{X, _}], _) -> X;
pw([{X, W} | _], R) when R < W -> X;
pw([{_, W} | Rest], R) -> pw(Rest, R - W).

exp_ms(Mean) -> max(1, round(-Mean * math:log(1.0 - rand:uniform()))).

now_ms() -> erlang:monotonic_time(millisecond).

tree_ids(Tree) ->
    lists:flatmap(fun(#{id := Id, replies := R}) -> [Id | tree_ids(R)] end, Tree).

text(Min, Max) ->
    N = Min + rand:uniform(Max - Min + 1) - 1,
    Words = [element(rand:uniform(tuple_size(?WORDS)), ?WORDS) || _ <- lists:seq(1, N)],
    iolist_to_binary(lists:join(<<" ">>, Words)).
