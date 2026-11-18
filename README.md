# COP5615 Project 4.1 - Reddit Engine

Team: Qing Li (16912349), Yingzhu Chen (83945095)

This project implements a distributed Erlang/OTP Reddit engine and simulator.
It includes registration, subreddits, posts, reposts, comments, voting with
karma, feeds, direct messages, live notifications, and a configurable
Zipf-distributed workload.

## Features

| Area | Operations |
|---|---|
| Accounts | `{register, User}`, `{get_karma, User}` |
| Subreddits | `{create_sub, U, Sub}`, `{join_sub, U, Sub}`, `{leave_sub, U, Sub}` |
| Content | `{post, U, Sub, Title, Body}`, `{repost, U, Sub, PostId}` |
| Comments | `{comment, U, ParentId, Body}`, `{get_post, PostId}` |
| Votes | `{vote, U, ItemId, up|down|none}` |
| Feeds | `{get_feed, U, Limit, hot|new|top}` |
| Direct messages | `{send_dm, F, T, Body}`, `{reply_dm, U, DmId, Body}`, `{get_dms, U, Limit}` |
| Connections | `{connect, U, Pid}`, `{disconnect, U}` |

New posts can be pulled through feeds or pushed to online subreddit members.
DM and reply notifications are pushed to connected users. Offline users catch
up through feed and inbox requests after reconnecting.

## Current implementation guarantees

- Engine state is stored in public ETS tables.
- The pool uses 2 × schedulers workers by default. Requests for the same user
  are routed to the same worker and therefore remain in order.
- Individual voting and membership transitions are serialized by short-lived
  per-key ETS locks.
- A lock records its owner PID. If that PID is no longer alive, another
  process removes the stale lock and retries.
- Normal lock cleanup uses `after` and only removes the lock owned by the
  current process.
- Top feeds scan all posts in the user's subscribed subreddits before sorting,
  rather than limiting candidate posts by recency first.
- The simulator tracks finished, crashed, and unfinished users and treats
  unfinished users as a failed run.
- The DM simulator separates pending and already-replied message IDs. It only
  replies to a bounded pending sample, as documented in the simulator.

Per-key locks are a defect-recovery improvement, not a distributed consensus
mechanism. They protect operations in this single Erlang engine node.

## Repository layout

```text
src/reddit_store.erl    ETS tables and shared state
src/reddit_ops.erl      engine operations
src/reddit_engine.erl   worker pool and live pushes
src/reddit_client.erl   Erlang client API
src/reddit_user.erl     simulated user state and actions
src/reddit_sim.erl      client-node driver and result collection
src/reddit_main.erl     engine coordinator
src/reddit_report.erl   text report builder
src/reddit_stats.erl    histogram-based latency statistics
test/reddit_tests.erl   EUnit tests
bench.sh                benchmark sweep
REPORT.md               benchmark and functional test report
```

## Build and test

Requirements: Erlang/OTP 25 or newer.

Linux, macOS, Git Bash:

```bash
./run.sh test
./run.sh sim
./run.sh sim users 10000 clients 4 duration 30
./bench.sh
```

Windows PowerShell:

```powershell
.\run.ps1 test
.\run.ps1 sim
.\run.ps1 sim users 10000 clients 4 duration 30
```

The test command compiles the source and runs `eunit:test(reddit_tests)`.
GitHub Actions runs the same test command on Ubuntu for pushes and pull requests.
The workflow is in `.github/workflows/test.yml`.

## Run across machines

```bash
# Engine
./run.sh engine clients 2 users 10000

# On two client machines or terminals
./run.sh client engine@HOST
./run.sh client engine@HOST
```

All nodes must use the same Erlang cookie. The default cookie is `reddit`;
set `COOKIE` to a custom value on every node.

## Configuration

| Option | Default | Meaning |
|---|---:|---|
| `users` | 5000 | total simulated users |
| `clients` | 4 | client OS processes |
| `subs` | 100 | subreddit count |
| `zipf_s` | 1.0 | Zipf exponent |
| `subs_per_user` | 3 | average subscriptions per user |
| `duration` | 30 | measured run duration in seconds |
| `think_ms` | 1000 | mean time between online actions |
| `online_ms` / `offline_ms` | 20000 / 10000 | online/offline period means |
| `repost` | 0.1 | fraction of repost actions |
| `push_posts` | false | push every new post to subscribed members |
| `workers` | 2 × schedulers | engine worker processes |
| `feed_limit` | 25 | maximum posts selected per feed |
| `seed` | 42 | simulator random seed |
| `mode` | local | `local` or external `engine` mode |

Reports are printed to stdout and saved under `results/` by default.

## Latency and report caveats

Client latency is the Erlang distributed round trip. Engine service time is
measured separately inside the engine. Percentiles are approximated from
power-of-two histogram buckets in `reddit_stats.erl`, not by sorting exact
samples.

Performance numbers depend heavily on CPU count, VM count, Erlang scheduler
count, and network layout. Existing Windows 11/OTP 29 results and Linux/OTP 25
reruns are labeled separately in [REPORT.md](REPORT.md).
