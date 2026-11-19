# Reddit Engine Performance and Verification Report

**Team members:** Qing Li (16912349), Yingzhu Chen (83945095)

## Implementation and Architecture

The Reddit engine supports user registration, subreddit creation and membership management, posts and reposts, nested comments, upvotes and downvotes with karma tracking, personalized feeds, direct messages, and message replies.

The system consists of an Erlang/OTP engine and independent client nodes:

- **ETS state storage:** the engine stores users, subreddits, memberships,
  posts, comments, scores, votes, karma, direct messages, connections, and
  counters in public ETS tables. Simple operations use atomic ETS operations,
  while vote and Join/Leave state transitions use per-key locking.
- **Engine Worker Pool:** the engine runs a configurable gen_server worker
  pool. Requests are routed by user so that one user's requests stay on the
  same worker and are processed in order, while different users can run in
  parallel.
- **Independent Client Nodes:** each simulated client is an Erlang VM and
  runs one Erlang process per simulated user. Client nodes communicate with
  the engine through Erlang distribution and send the merged performance
  measurements back to the coordinator.
- **Zipf distribution:** subreddit ranks and membership selections follow a
  Zipf distribution, and posting activity is also biased toward popular
  subreddits.
- **Online/offline simulation:** each user alternates between exponential
  online and offline periods. While online, users perform the configured mix
  of actions. On reconnect, they catch up with their feed and inbox.

The engine also pushes DMs and comment replies to connected users. Optional
post fan-out pushes every new post to online subscribers of that subreddit.

## 1. Test environment and scope

The benchmark data below was collected on one test PC with 8 cores and
Erlang/OTP 29. The engine and all client VMs shared that machine.

## 2. Benchmark baseline

The following values are the benchmark baseline for the implementation.

**Default workload:** 100 subreddits, Zipf `s = 1.0`, 3 subscriptions per
user on average, 30-second runs, one action about every second per online
user, 20-second mean online periods, 10-second mean offline periods, 10%
reposts, and 16 engine workers.

### 2.1 User scaling

| Users | Requests/s | p50 | p95 | p99 | Engine memory (ETS) | Register + join |
|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 857 | 0.58 ms | 1.3 ms | 1.9 ms | 42 MB (5 MB) | 28 + 51 ms |
| 5,000 | 4,274 | 0.74 ms | 1.9 ms | 2.0 ms | 65 MB (22 MB) | 90 + 265 ms |
| 10,000 | 8,497 | 0.41 ms | 1.7 ms | 3.2 ms | 93 MB (43 MB) | 213 + 617 ms |
| 25,000 | 20,939 | 1.3 ms | 30 ms | 110 ms | 175 MB (106 MB) | 590 + 1432 ms |
| 50,000 | 25,306 | 615 ms | 1040 ms | 1320 ms | 212 MB (137 MB) | 1127 + 3274 ms |

- Throughput grew approximately linearly through 10,000 users.
- The 25,000-user run showed a much larger p99 tail.
- The 50,000-user run offered more work than the engine could sustain.

### 2.2 Saturation

A saturation run with 10,000 users acting every 10 ms on average sustained
30,176 requests/s for 30 seconds, with p50 191 ms and p99 262 ms.

### 2.3 Client process count

| Client processes | Requests/s | p50 | p95 | p99 | Register + join |
|---:|---:|---:|---:|---:|---:|
| 1 | 8,390 | 0.78 ms | 14 ms | 102 ms | 530 + 1693 ms |
| 2 | 8,460 | 0.74 ms | 2.0 ms | 7.6 ms | 379 + 1454 ms |
| 4 | 8,497 | 0.41 ms | 1.7 ms | 3.2 ms | 213 + 617 ms |
| 8 | 8,496 | 0.54 ms | 1.6 ms | 2.1 ms | 216 + 622 ms |

Distributing 10,000 users across 4-8 client processes greatly improved p99
tail latency compared with one process.

### 2.4 Zipf workload

The original 10,000-user run fit member exponent 0.97 (configured 1.0) and
post exponent 1.46 (configured 1.0). This measured the expected concentration
of posts in popular subreddits.

With fan-out enabled, the original run delivered approximately 24 million
post notifications in 30 seconds and throughput fell from about 8.5k to
6.9k requests/s.

## 3. Functional testing

Run locally:

```bash
./run.sh test
```

The suite is EUnit-based and currently contains 11 test groups:

- account registration and karma
- subreddit creation and membership
- post, feed, and top-feed behavior
- nested comments
- normal and concurrent votes
- concurrent Join/Leave consistency
- stale-lock recovery
- repost behavior
- direct messages
- live engine notifications

Test verification:

- 11 test groups passed
- the benchmark completed all users
- no crashed or unfinished users

## 4. Correctness changes

The implementation now serializes each `(ItemId, User)` vote and each
`(User, Sub)` membership transition. Stale owner PIDs are detected with
`is_process_alive/1` and reclaimed. Deadlock recovery is limited to stale
locks on the engine node; it is not a cross-node distributed lock protocol.

Top feed candidates now include all posts in subscribed subreddits. This
improves historical ranking correctness but can be more expensive as content
grows.

## 5. Report reproducibility

Reproduce the 10,000-user benchmark:

```powershell
.\run.ps1 sim users 10000 clients 4 duration 30
```

Run the full sweep:

```bash
./bench.sh
```

Client and engine latency percentiles are approximate because
`reddit_stats.erl` uses power-of-two histogram buckets rather than exact
sorted latency samples.
