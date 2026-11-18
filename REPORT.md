# Performance report

All numbers come from `./bench.sh`. The full report of every run is in
[results/](results/).

**Machine:** one Windows 11 PC with 8 cores, Erlang/OTP 29. The engine VM and
all client VMs ran on this one machine and shared its 8 cores, so the
capacity figures below are a lower bound for the engine.

**Default workload:** 100 subreddits, Zipf s = 1.0, 3 subs per user on
average, 30 s runs. An online user acts about once per second
(`think_ms 1000`). Users are online for 20 s and offline for 10 s on average
(about 65% of the time online). 10% of posts are reposts. The engine runs 16
worker processes.

## 1. Scaling the number of users (4 client processes)

| Users | Requests/s | p50 | p95 | p99 | Engine memory (ETS) | Setup: register + join |
|---:|---:|---:|---:|---:|---:|---:|
| 1,000 | 857 | 0.58 ms | 1.3 ms | 1.9 ms | 42 MB (5 MB) | 28 + 51 ms |
| 5,000 | 4,274 | 0.74 ms | 1.9 ms | 2.0 ms | 65 MB (22 MB) | 90 + 265 ms |
| 10,000 | 8,497 | 0.41 ms | 1.7 ms | 3.2 ms | 93 MB (43 MB) | 213 + 617 ms |
| 25,000 | 20,939 | 1.3 ms | 30 ms | 110 ms | 175 MB (106 MB) | 590 + 1432 ms |
| 50,000 | 25,306 | 615 ms | 1040 ms | 1320 ms | 212 MB (137 MB) | 1127 + 3274 ms |

Latency is the client round trip over Erlang distribution, across all
operations. Latency percentiles are approximated using power-of-two histogram
buckets.

- **Up to 10,000 users:** throughput grows linearly with users (about 0.85
  requests/s per user), and round trips stay under 3.5 ms at p99.
- **25,000 users:** the 99th percentile starts to rise (110 ms). The machine
  is close to its limit.
- **50,000 users:** the offered load would be about 43k requests/s. The
  system tops out at about 25k requests/s, so requests queue and latency
  grows to about 0.6 s. In the measured run, no request errors or crashed
  users were reported.

## 2. Maximum throughput (saturation run)

10,000 users acting every 10 ms on average:

- **30,176 requests/s** sustained for 30 s, with p50 191 ms and p99 262 ms
  (all queueing).
- The engine's own **service time stays small**: vote 13 µs, post 141 µs,
  comment 86 µs, get_feed 654 µs. The feed grows with the amount of content.
- The measured ceiling of about 25–30k requests/s comes from everything sharing
  one 8-core box: 5 Erlang VMs, message encoding and decoding, and the
  distribution connections. The next step to scale would be to put the client
  processes on other machines (`./run.sh engine` / `./run.sh client`). The
  engine-only capacity was not measured independently.

## 3. Number of client processes (10,000 users)

| Client processes | Requests/s | p50 | p95 | p99 | Setup: register + join |
|---:|---:|---:|---:|---:|---:|
| 1 | 8,390 | 0.78 ms | 14 ms | 102 ms | 530 + 1693 ms |
| 2 | 8,460 | 0.74 ms | 2.0 ms | 7.6 ms | 379 + 1454 ms |
| 4 | 8,497 | 0.41 ms | 1.7 ms | 3.2 ms | 213 + 617 ms |
| 8 | 8,496 | 0.54 ms | 1.6 ms | 2.1 ms | 216 + 622 ms |

All four configurations carry the same load, but tail latency is much better
with more client processes. With a single client VM, all 10,000 users share
one VM and one TCP connection to the engine, and p99 reaches 102 ms. Splitting
them over 4–8 processes brings p99 down to 2–3 ms.

## 4. Per-operation latency (10,000 users, 4 clients)

| Op | Count | avg | p50 | p95 | p99 | Engine service time |
|---|---:|---:|---:|---:|---:|---:|
| connect | 16,328 | 472 µs | 378 µs | 1.5 ms | 2.7 ms | 3 µs |
| post | 17,242 | 535 µs | 379 µs | 1.7 ms | 3.4 ms | 17 µs |
| repost | 1,824 | 484 µs | 375 µs | 1.7 ms | 3.3 ms | 18 µs |
| comment | 34,295 | 510 µs | 386 µs | 1.7 ms | 3.4 ms | 17 µs |
| vote | 57,002 | 496 µs | 358 µs | 1.7 ms | 3.2 ms | 7 µs |
| get_feed | 55,719 | 671 µs | 625 µs | 1.8 ms | 3.3 ms | 156 µs |
| get_post (with comment tree) | 15,402 | 505 µs | 391 µs | 1.7 ms | 3.4 ms | 25 µs |
| send_dm | 7,664 | 484 µs | 379 µs | 1.7 ms | 3.2 ms | 14 µs |
| reply_dm | 6,241 | 350 µs | 295 µs | 0.9 ms | 1.8 ms | 16 µs |
| get_dms | 27,838 | 389 µs | 307 µs | 1.0 ms | 2.2 ms | 6 µs |
| get_karma | 3,744 | 498 µs | 351 µs | 1.7 ms | 3.3 ms | 2 µs |
| join_sub / leave_sub | 3,951 | 470 µs | 372 µs | 1.7 ms | 3.2 ms | 12–14 µs |

**Where the time goes:** the engine's service time is a small fraction of
the round trip. Most of the time is network hop and scheduling.

**Content produced in this run:**
- 19,066 posts, of which 9.6% are reposts
- 34,295 comments, nested up to 6 levels deep
- 51,070 votes and 13,905 DMs

**Live connections:**
- 16,328 connects and 16,328 disconnects; users were online 64% of the time
  on average.
- The engine pushed 10,152 DM notifications and 22,216 reply notifications.
  Clients received all but one of each; those two were still in flight when
  the run ended.

## 5. Zipf distribution of subreddit membership and posts

10,000 users, s = 1.0. "Ideal" is members(rank 1) / k^s.

| Rank | Members | Ideal | Posts | Reposts |
|---:|---:|---:|---:|---:|
| 1 | 4,559 | 4,559 | 6,684 | 639 |
| 2 | 2,777 | 2,280 | 2,800 | 267 |
| 3 | 2,023 | 1,520 | 1,628 | 161 |
| 5 | 1,175 | 912 | 704 | 63 |
| 10 | 591 | 456 | 306 | 24 |
| 20 | 318 | 228 | 102 | 11 |
| 50 | 131 | 91 | 20 | 5 |
| 100 | 72 | 46 | 12 | 0 |

**Members:** the least-squares fit of log(members) against log(rank) gives
an exponent of **0.97** (configured 1.0). With s = 1.5 it gives **1.44**.
The curve is slightly flatter at the top than the ideal, because a user joins
distinct subreddits and rank 1 cannot be picked twice.

**Posts:** the fitted exponent is **1.46** (1.88 with s = 1.5). Post counts
fall off faster than member counts, so the large subreddits get
disproportionately more posts, as the assignment asks. Rank 1 holds 15% of
all memberships (46% of users joined it) but gets 35% of all posts: 6,684 in
30 s.

## 6. Pushing every post to online members (`push_posts true`)

With fan-out on, the engine delivered **24 million post notifications in
30 s** (about 800k messages/s), batched per client node. That load dominates
the machine:
- Request throughput falls from 8.5k to 6.9k requests/s.
- p99 latency rises to about 1 s.
- The average service time of get_feed rises from 156 µs to 6.7 ms.

This is why the default delivers posts through the feed (pull) and pushes
only DMs and replies, the way Reddit's own inbox works.

## 7. Functional testing

The functional suite is run with:

```bash
./run.sh test
```

It currently contains 10 EUnit tests covering accounts, subreddit membership
and counts, posts and new/top/hot feeds, nested comments, votes and karma
(including concurrent votes), reposts, direct messages, concurrent
join/leave consistency, and live notifications. The suite passed all 10 tests
on Erlang/OTP 25 in the Linux validation environment. On Windows, the same
command is run through Git Bash or WSL; PowerShell users can use
`.\run.ps1 test`.

## Summary

- On one 8-core machine, the engine and 4 client processes simulate
  **10,000 concurrent users at about 8.5k requests/s with p99 under 3.5 ms**.
- **25,000 users** run with p99 around 110 ms.
- The system sustains about **25–30k requests/s** before requests start to
  queue.
- The measured runs reported no request errors or crashed users; each report
  also records unfinished users separately, and the simulator exits
  unsuccessfully if any remain.
