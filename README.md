# COP5615_Project4.1
Team members: Qing Li (16912349) Yingzhu Chen(83945095)

A Reddit clone engine and a client tester/simulator, written in Erlang/OTP
(part I: engine + simulator, no REST/WebSocket layer yet). Performance
results are in [REPORT.md](REPORT.md).

## What is implemented

**Engine** (one Erlang VM / OS process):

| Feature | Request |
|---|---|
| Register account | `{register, User}` |
| Create, join, leave subreddit | `{create_sub, U, Sub}`, `{join_sub, U, Sub}`, `{leave_sub, U, Sub}` |
| Text posts and reposts | `{post, U, Sub, Title, Body}`, `{repost, U, Sub, PostId}` |
| Hierarchical comments (comment on a post or on a comment, any depth) | `{comment, U, ParentId, Body}` |
| Upvote / downvote / withdraw, karma | `{vote, U, ItemId, up \| down \| none}`, `{get_karma, U}` |
| Feed of posts from joined subreddits (`hot`, `new`, `top`) | `{get_feed, U, Limit, Sort}` |
| A post with its full comment tree | `{get_post, U, PostId}` |
| Direct messages: list, send, reply | `{get_dms, U, Limit}`, `{send_dm, U, To, Body}`, `{reply_dm, U, DmId, Body}` |
| Live connection | `{connect, U, Pid}`, `{disconnect, U}` |

Connected users get live pushes: a new direct message, a reply to one of their
posts or comments, and (with `push_posts true`) every new post in their
subreddits. Offline users catch up through their feed and inbox when they
reconnect.

**Simulator**: several independent client OS processes (Erlang nodes). Each
one runs thousands of simulated users, one Erlang process per user.

- Users alternate between online and offline periods of exponentially
  distributed length. While online they act about once per `think_ms`. The
  mix of actions is feed, vote, comment, post, view post, DM, inbox, karma,
  and join/leave.
- Subreddit membership follows a Zipf distribution. Each user joins 1–5 subs
  drawn with P(rank k) ∝ 1/k^s.
- Popular subreddits get more posts. A user posts to one of their subs
  chosen with weight 1/k^s, so post counts grow faster than member counts
  (see the Zipf table in the report).
- A share of posts (`repost`, default 10%) are reposts of posts the user has
  seen. Reposts keep a link to the original.
- Every request is timed on the client. The engine also records its own
  service time. One report combines both.

## Layout

```
src/reddit_store.erl    ETS tables holding all engine state
src/reddit_ops.erl      engine logic (pure request -> reply over ETS)
src/reddit_engine.erl   engine worker pool, routing, live pushes
src/reddit_client.erl   client-side API to a remote engine
src/reddit_user.erl     one simulated user
src/reddit_sim.erl      client process driver (one per client OS process)
src/reddit_main.erl     entry point: starts engine, spawns/coordinates clients
src/reddit_report.erl   performance report
src/reddit_zipf.erl     Zipf sampler
src/reddit_stats.erl    mergeable latency histograms
test/reddit_tests.erl   engine unit tests
```

### Design

- **Engine state** lives in public ETS tables. Simple updates use atomic ETS
  operations (`insert_new`, `take`, `update_counter`), while multi-step vote
  and membership updates use short-lived per-key locks. The engine has no
  global lock and no single mailbox bottleneck.
- **Engine workers**: a pool of gen_servers (2 × schedulers). A client sends
  each request to the worker chosen by `phash2(UserName)`. One user's
  requests stay in order, and different users run in parallel.
- **Separate processes**: the engine and each client are separate Erlang VMs
  talking over Erlang distribution. `sim` mode starts the client VMs with
  OTP's `peer` module. `engine` + `client` mode lets you start them by hand,
  on other machines too.
- **Push fan-out** for new posts is batched: one message per client node,
  forwarded locally by that node's `reddit_relay` process.
- `reddit_ops` knows nothing about processes or transport. Part II can put
  a REST/WebSocket layer in front of it without changes.

## How to run

Requires Erlang/OTP 25 or newer (developed on OTP 29). No other dependencies.

Windows (PowerShell):

```powershell
.\run.ps1 test                                   # engine unit tests
.\run.ps1 sim                                    # default: 5000 users, 4 clients, 30 s
.\run.ps1 sim users 20000 clients 4 duration 60  # any options, key value pairs
```

Linux / macOS / Git Bash:

```bash
./run.sh test
./run.sh sim users 20000 clients 4 duration 60
./bench.sh            # the full experiment sweep used in REPORT.md
```

The report is printed and also saved to `results/run_<users>u_<clients>c_<secs>s_<time>.txt`.

### Clients started by hand (or on other machines)

```bash
./run.sh engine clients 2 users 10000     # terminal 1: prints engine@HOST, waits
./run.sh client engine@HOST               # terminal 2
./run.sh client engine@HOST               # terminal 3
```

Every node must use the same cookie (`COOKIE` environment variable, default
`reddit`). The scripts use short names (`-sname`). Across machines with
different domains, change them to `-name` with full host names.

### Options

| Option | Default | Meaning |
|---|---|---|
| `users` | 5000 | simulated users in total |
| `clients` | 4 | client OS processes |
| `subs` | 100 | number of subreddits (Zipf ranks) |
| `zipf_s` | 1.0 | Zipf exponent |
| `subs_per_user` | 3 | average subs joined per user (1 .. 2n-1) |
| `duration` | 30 | seconds of simulated activity |
| `think_ms` | 1000 | mean time between actions of an online user |
| `online_ms` / `offline_ms` | 20000 / 10000 | mean length of online / offline periods |
| `stagger_ms` | 3000 | users that start online log in within this window |
| `repost` | 0.1 | share of posts that are reposts |
| `push_posts` | false | push each new post to all online members of the sub |
| `workers` | 2 × schedulers | engine worker processes |
| `feed_limit` | 25 | posts per feed request |
| `seed` | 42 | random seed |
| `mode` | local | `local` spawns clients itself; `engine` waits for external clients |
| `out` | results | report directory |
