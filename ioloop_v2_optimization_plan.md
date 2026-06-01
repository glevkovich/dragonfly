# IoLoopV2 Optimization Plan — Consolidated & Prioritized (v9)

This document consolidates all research into a single actionable plan with priorities, risks,
and implementation order.

---

## Background: Why V2 Is Slower Than V1

**V1** uses two fibers per connection: `IoLoop` (reader/parser) and `AsyncFiber`
(executor/flusher). They run concurrently on the same thread, meaning parsing happens while
execution/flushing is in progress. V1 also has smart heuristics:

- **Conditional flush** in `SquashPipeline()`: flushes only when
  `parsed_cmd_q_len_ == pipeline_count` (no new commands arrived), otherwise skips it
  (`skip_pipeline_flushing++`).
- **Epoch yield**: when only 1 command is pending and the fiber hasn't been preempted since the
  last dispatch, it explicitly `Yield()`s to let `IoLoop` fill the queue.

**V2** has one fiber that does everything sequentially:

```
io_event_.await() → ReadPendingInput() → ParseLoop() → ExecuteBatch()
→ ReplyBatch() → loop top → Flush (if idle) → repeat
```

No one reads the socket while `ExecuteBatch()` runs. This sequential model has two fundamental
consequences:
1. **Pipeline flushing**: Without the merged PR, `ReplyBatch()` flushed unconditionally at every
   `ParseLoop` chunk, creating 6–12 `sendmsg` syscalls for a 100-command pipeline vs V1's 1–2.
2. **No concurrent parsing**: While V1's IoLoop fiber fills the queue during execution, V2's
   single fiber cannot parse while executing — the socket buffer accumulates unread data.

### Merged PR Results (commit 1603e65b)

The first optimization PR has been merged. It:
- Skipped `Flush()` in `ReplyBatch()` for V2 (delegated to IoLoopV2's idle-await flush).
- Added a fast-path in `SinkReplyBuilder::Flush()` that returns immediately when nothing is
  buffered.
- Removed the redundant flush after `dispatch_q_` draining.

**Benchmark results (5-run median, V2 throughput):**

| Pipeline | V2 syscalls (main) | V2 syscalls (PR) | Change  |
|----------|--------------------|------------------|---------|
| 100      | 92,440             | 27,725           | **−70%** |
| 500      | 92,772             | 5,731            | **−94%** |

V2 fragmentation at p=500: 1,802 → 426 (−76%).

**Pre-existing V2 pubsub regression (unaffected by the merged PR):**

| Pipeline | V1 syscalls | V2 syscalls (main) | V2 syscalls (PR) | V2 RPS (main) |
|----------|-------------|--------------------:|------------------:|--------------:|
| 1        | ~125K       | 256K                | 257K              | 84K           |
| 10       | ~25K        | 165K                | 165K              | 131K          |
| 100      | ~4K         | 157K                | 157K              | 137K          |

The V2 pubsub regression is a **wakeup granularity problem**, not a flush problem (see Task 5
below).

---

## Task List

| #  | Task | Phase | Priority | Risk | Effort | Dependencies | PR | Status |
|----|------|-------|----------|------|--------|--------------|-----|--------|
| ~~1~~ | ~~[Conditional Flushing in ReplyBatch()](#task-1-conditional-flushing-in-replybatch---merged)~~ | ~~1~~ | ~~P0~~ | ~~Low~~ | ~~Small~~ | ~~None~~ | ~~[#7213](https://github.com/dragonflydb/dragonfly/pull/7213)~~ | **MERGED** |
| ~~2~~ | ~~[Epoch-Based Yield Heuristic (standalone)](#task-2-epoch-based-yield-heuristic-standalone--na)~~ | ~~—~~ | ~~P0~~ | ~~Low~~ | ~~Small~~ | ~~None~~ | — | **N/A for V2 alone** |
| ~~3~~ | ~~[Bounded Control-Path Dispatch Quota](#task-3-bounded-control-path-dispatch-quota--merged)~~ | ~~1~~ | ~~P1 — Important~~ | ~~Low~~ | ~~Small~~ | ~~None~~ | ~~[#7234](https://github.com/dragonflydb/dragonfly/pull/7234)~~ | **MERGED** |
| ~~4~~ | ~~[Eager Parsing in NotifyOnRecv + Shared IoBuf](#task-4-eager-parsing-in-notifyonrecv--shared-iobuf--cancelled)~~ | ~~2~~ | ~~P1 — Major~~ | ~~High~~ | ~~Large~~ | ~~Design doc~~ | — | **CANCELLED** |
| ~~5~~ | ~~[V2 Pubsub Wakeup Batching](#task-5-v2-pubsub-wakeup-batching--merged)~~ | ~~1~~ | ~~P1 — Important~~ | ~~Medium~~ | ~~Medium~~ | ~~None~~ | ~~[#7437](https://github.com/dragonflydb/dragonfly/pull/7437)~~ | **MERGED** |
| ~~6~~ | ~~[Epoch-Based Yield (after Task 4)](#task-6-epoch-based-yield-after-task-4--cancelled)~~ | ~~2~~ | ~~P1 — Dependent~~ | ~~Low~~ | ~~Trivial~~ | ~~Task 4~~ | — | **CANCELLED** |
| 7  | [`io_event_.notify()` — Skip Redundant Wakeups (Deduplication)](#task-7-io_event_notify--skip-redundant-wakeups-deduplication--p2-investigate-first) | 2 | P2 — Investigate | Unknown | TBD | Helio audit | — | TODO |
| 8  | [Soft Backpressure / Smart Yielding](#task-8-soft-backpressure--smart-yielding--p2) | 3 | P2 — Moderate | Medium | Medium | None | — | TODO |
| 9  | [Full io_uring Buffer Ring Integration](#task-9-full-io_uring-buffer-ring-integration--p3-future--endgame) | 3 | P3 — Future | High | Large | Kernel 5.19+ | — | TODO |
| 10 | [Deferred Fan-Out Batching (Pubsub p=1)](#task-10-deferred-fan-out-batching-pubsub-p1--p2) | 2 | P2 — Important | Medium | Medium | Task 5 merged | — | TODO |
| ~~11~~ | ~~[V2 Subscriber-Side Reply Batching (SetBatchMode in ProcessControlMessages)](#task-11-v2-subscriber-side-reply-batching-setbatchmode-in-processcontrolmessages--merged)~~ | ~~1~~ | ~~P2 — Important~~ | ~~Low~~ | ~~Small~~ | ~~None~~ | ~~[#7479](https://github.com/dragonflydb/dragonfly/pull/7479)~~ | **MERGED** |
| 12 | [TLS Support for IoLoopV2 (MC + RESP)](#task-12-tls-support-for-ioloopv2--p1-required) | 4 | P1 — Required | High | Large | None | — | TODO |
| 13 | [Conditional SquashPipeline for V2](#task-13-conditional-squashpipeline-for-v2--p2-conditional) | 4 | P2 — Conditional | Medium | Medium | M2 benchmarks | — | TODO |
| **14** | **[Fiber-Level Time Profiling (Measure Before Optimize)](#task-14-fiber-level-time-profiling-measure-before-optimize--p0-next)** | **2** | **P0 — NEXT** | **Low** | **Small–Medium** | **None** | — | **TODO** |
| ~~15~~ | ~~[Idle-Flush Coalescing Delay (`pipeline_wait_batch_usec` for V2)](#task-15-idle-flush-coalescing-delay-pipeline_wait_batch_usec-for-v2--cancelled)~~ | ~~2~~ | ~~P2 — Experiment~~ | ~~Low~~ | ~~Trivial~~ | ~~Task 14 data~~ | — | **CANCELLED** |
| ~~16~~ | ~~[Transactional-Command Reply-Flush Coalescing (ZADD `batched_=false`)](#task-16-transactional-command-reply-flush-coalescing-zadd-batched_false--cancelled)~~ | ~~2~~ | ~~P3 — Low~~ | ~~Low~~ | ~~Small~~ | ~~Task 14 data~~ | — | **CANCELLED** |

---

## ~~Task 1: Conditional Flushing in ReplyBatch() — MERGED~~

~~The unconditional `Flush()` in `ReplyBatch()` created 6–12 syscalls per 100-command pipeline.~~

**Resolved:** `ReplyBatch()` no longer flushes in V2. Flushing is delegated to IoLoopV2's
idle-await block (before `io_event_.await()`) and the backpressure block. Additionally,
`SinkReplyBuilder::Flush()` has a fast-path that returns immediately when nothing is buffered.

Result: V2 throughput syscalls at p=500 dropped from **92K to 5.7K** (−94%).

---

## ~~Task 2: Epoch-Based Yield Heuristic (standalone) — N/A~~

~~Port V1's epoch yield to V2: if only 1 command is pending and the fiber hasn't been preempted,
yield to let more data arrive.~~

**Why this doesn't work in V2 alone:** V1's yield works because the IoLoop fiber continues
parsing concurrently during the yield — the queue fills while AsyncFiber sleeps. In V2,
everything is one fiber. When it yields, nobody reads or parses — the data just sits in the
kernel buffer. The yield accomplishes nothing and adds artificial latency to isolated commands.

~~**However, Task 2 becomes highly valuable once Task 4 (Eager Parsing in NotifyOnRecv) is
implemented.** See Task 6 below for the revised version.~~

**Update:** Task 4 (Eager Parsing) was cancelled after benchmarking proved it architecturally
useless in a single-fiber model. Task 6 (Epoch Yield) was cancelled along with it.

---

## ~~Task 3: Bounded Control-Path Dispatch Quota — MERGED~~

### The Problem

In IoLoopV2, the dispatch queue is drained completely:

```cpp
while (!dispatch_q_.empty()) {
    auto msg = std::move(dispatch_q_.front());
    dispatch_q_.pop_front();
    // ... process ...
}
```

If PubSub is delivering thousands of messages, this loop starves the data path entirely. No
Redis command can execute until every PubSub/admin message is processed.

V1 already solves this with `async_dispatch_quota`, which limits how many dispatch queue messages
are processed before yielding back to the pipeline.

### The Fix

Bound the loop and batch the flush:

```cpp
uint32_t dispatch_quota = GetFlag(FLAGS_async_dispatch_quota);
uint32_t processed = 0;
size_t sub_bytes_before = conn_stats.dispatch_queue_subscriber_bytes;

while (!dispatch_q_.empty() && processed < dispatch_quota) {
    auto msg = std::move(dispatch_q_.front());
    dispatch_q_.pop_front();
    processed++;
    UpdateDispatchStats(msg, false);
    if (std::holds_alternative<MigrationRequestMessage>(msg.handle)) {
        break;
    }
    std::visit(AsyncOperations{reply_builder_.get(), this}, msg.handle);
}

// Single flush for the entire control-path batch
reply_builder_->Flush();
if (auto ec = reply_builder_->GetError(); ec)
    return ec;

// Only notify backpressure if subscriber bytes actually decreased
if (conn_stats.dispatch_queue_subscriber_bytes < sub_bytes_before) {
    GetQueueBackpressure().pubsub_ec.notifyAll();
}
```

This also resolves two existing TODOs:
- Line ~2847: `"Possibly don't flush unconditionally"` → batch flush once after quota.
- Line ~2852: `"Properly handle backpressure"` → conditional notification.

### Expected Impact

Prevents PubSub floods from starving command execution. Ensures fairness between control and
data paths.

### Risk

Low. The existing `FLAGS_async_dispatch_quota` mechanism already exists and is tuned.

---

## ~~Task 4: Eager Parsing in NotifyOnRecv + Shared IoBuf — CANCELLED~~

> ~~**This is the single most impactful remaining optimization.** Tasks 4, 5 (old numbering), and
> 6 are architecturally inseparable and should be designed and implemented as one unit.~~
>
> **CANCELLED (2 Jun 2026).** See [Why Tasks 4 and 6 Were Cancelled](#why-tasks-4-and-6-were-cancelled) below.

### The Problem

`NotifyOnRecv` currently only copies raw bytes into `io_buf_` and sets `pending_input_ = true`.
Parsing happens later when the fiber wakes. This means:

- While `ExecuteBatch()` runs, no parsing happens.
- The fiber must wake up, read, parse, then execute — a sequential bottleneck.

### The Fix (Two-Stage)

**Stage 1: Eager parsing into existing per-connection `io_buf_` (safe, no lifetime risk)**

Parse eagerly in the `NotifyOnRecv` callback, but continue using the per-connection `io_buf_`:

```cpp
peer->RegisterOnRecv([this](const FiberSocketBase::RecvNotification& n) {
    NotifyOnRecv(n);
    // Eagerly parse up to N commands (quota prevents proactor starvation)
    constexpr uint32_t kEagerParseQuota = 100;
    if (io_buf_.InputLen() > 0 && !backpressure_active_) {
        ParseFromBuffer(io_buf_, kEagerParseQuota);
    }
    io_event_.notify();
});
```

Key design constraints for the callback:
- **Quota:** Parse at most N commands per callback invocation. If data remains, set
  `pending_input_ = true` and wake the fiber. The fiber handles the rest in its normal
  `ParseLoop()` path.
- **No fiber operations:** `NotifyOnRecv` runs on the proactor event loop, not a fiber. Cannot
  call `Yield()`, `Wait()`, or any fiber-blocking operation.
- **Parser errors:** Must be queued as deferred errors, not handled inline.
- **Backpressure:** Skip parsing if the parsed queue is over limit.

**Stage 2: Thread-local shared IoBuf (memory optimization, higher risk)**

Once eager parsing is stable, replace per-connection `io_buf_` with a thread-local shared
buffer:

```cpp
static thread_local IoBuf tl_recv_buf(kDefaultRecvBufSize);
```

Since `ParseXX` functions deplete the input buffer to completion, the shared buffer is empty
after parsing and ready for the next connection.

### The Shared Buffer Lifetime Problem

**This is the critical design challenge.** Currently, `ParsedCommand` stores `MutableSlice`
views that point directly into `io_buf_`:

```
io_buf_:  [*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n]
                      ^^^               ^^^               ^^^
ParsedCommand args:   [0]               [1]               [2]  ← zero-copy pointers
```

With a shared buffer, if another connection's `NotifyOnRecv` fires and overwrites the buffer
before the first connection executes, the result is **use-after-free**.

This isn't just about yielding. **Blocking commands** are the fatal case:

```
Client sends: SET key val\r\nBLPOP mylist 0\r\n
```

1. Both commands parsed with zero-copy pointers into the shared buffer.
2. `SET` executes fine.
3. `BLPOP` suspends the fiber (list is empty, blocks indefinitely).
4. Another connection's `NotifyOnRecv` overwrites the shared buffer.
5. Someone pushes to `mylist`, fiber resumes, follows dangling pointers → **crash**.

Commands that suspend fibers: `BLPOP`, `BRPOP`, `XREAD BLOCK`, `WAIT`, `SUBSCRIBE`, etc.

### Possible Solutions to the Lifetime Problem

| Approach | Correctness | Performance | Complexity |
|----------|------------|-------------|------------|
| **(a) Copy all arguments** into per-command storage | Safe | Loses zero-copy | Low |
| **(b) Copy-On-Yield** — copy only when fiber must suspend | Safe if complete | Fast path stays zero-copy | High — must intercept every suspension point |
| **(c) Refcounted ring buffer** — pin segments until commands release them | Safe | Zero-copy preserved | Very High |
| **(d) io_uring buffer rings** — kernel guarantees buffer lifetime | Safe | Zero-copy, kernel-managed | High — helio-level change (see Task 9) |

**Copy-On-Yield** sounds elegant but is fragile: you don't know at parse time whether `BLPOP`
will block. By the time you discover it blocks, you're deep inside `DispatchCommand`. Every
`Yield()`, `Wait()`, `Await()` in command execution would need to check and materialize
arguments.

**io_uring buffer rings** (Task 9) are the cleanest endgame — the kernel hands each recv its
own buffer chunk that you explicitly return after execution. No sharing, no lifetime tracking.

### Recommendation

**Implement Stage 1 first** (eager parsing into per-connection `io_buf_`). This gives the full
batching benefit without any lifetime risk. Defer Stage 2 (shared buffer) until Task 9
(io_uring buffer rings) provides a safe foundation.

### Expected Impact

Eliminates the sequential bottleneck. The fiber wakes to a full queue of parsed commands,
executes them all, and flushes once.

### Risk

**Stage 1:** Medium. Thread safety is the main concern — `NotifyOnRecv` runs in proactor
context. Safe only if the fiber is guaranteed to be suspended when the callback fires. The
parser state (`redis_parser_`) and `io_buf_` must not be accessed concurrently.

**Stage 2:** HIGH. Lifetime management is fundamentally hard with zero-copy pointers.

---

## ~~Task 5: V2 Pubsub Wakeup Batching — MERGED~~

**Resolved:** PR #7437 merged. V2 pubsub wakeup coalescing via do-while + Yield in
`ProcessControlMessages`. Fixes the 2× syscall regression at p≥10.

### The Problem (historical)

V2 pubsub does **2× more syscalls** and **50–73% lower RPS** than V1. This regression exists
on main and is unrelated to the merged flush PR.

**Root cause:** Each `PubMessage` arriving via `SendAsync()` calls `io_event_.notify()`, waking
the fiber once per message. The fiber wakes, drains one (or a few) messages from `dispatch_q_`,
`continue`s back to the top of the loop, hits `io_buf_.InputLen() == 0`, flushes, sleeps. Next
message arrives — repeat. **One syscall per message delivery.**

V1's AsyncFiber naturally batches because the `cnd_.wait()` predicate coalesces wakeups — by
the time the fiber actually runs, multiple messages have accumulated in `dispatch_q_`.

### The Fix

The fix is **not** adding a flush back into `dispatch_q_` draining (that would undo the merged
PR's pipeline improvement). Instead, batch wakeups so the fiber processes groups of pubsub
messages before flushing.

Potential approaches:
1. **Debounced wakeup:** After processing `dispatch_q_`, don't immediately loop back to the
   await block. Instead, do a brief non-blocking check for more messages (e.g., `Yield()` to
   let the proactor deliver pending notifications, then re-check `dispatch_q_`).
2. **Batch-aware dispatch_q_ draining:** Instead of `continue` after processing dispatch_q_,
   fall through to the idle-await block only if no more messages arrived during processing.
3. **Deferred flush after dispatch_q_:** Flush only after the dispatch quota is exhausted (ties
   into Task 3's bounded quota), not on every loop iteration.

### Expected Impact

**p≥10 (addressed by the PR):** Reduces V2 pubsub syscalls from ~170K → ~29K at p=10 (−83%)
and ~157K → ~6.4K at p=100 (−96%), matching V1's order of magnitude.

**p=1 (still unaddressed):** At p=1 each message wakes the subscriber fiber when the queue is
empty, so the do-while batching loop has nothing to coalesce. V2 delivers exactly 1 message
per wakeup (~550K syscalls, the theoretical minimum: 50K publishes × 10 subscribers + 50K
publisher replies) vs V1's ~2.2 messages per wakeup (~247K syscalls). The root cause is a
scheduling timing difference: V1's `cnd_.notify_one()` places AsyncFiber in the **ready
queue** but does not immediately yield to it. Subsequent PUBLISH calls continue to fan out,
queueing messages to other subscriber connections. By the time the scheduler actually runs
AsyncFiber, 2–3 messages have accumulated — an accidental coalescing benefit. V2's
`io_event_.notify()` causes the subscriber fiber to wake sooner, before subsequent fan-out
messages land. See Task 10 for the targeted fix.

### Risk

Medium. Must not regress latency for single pubsub messages (subscriber should still get
messages promptly).

---

## ~~Task 6: Epoch-Based Yield (after Task 4) — CANCELLED~~

> **CANCELLED (2 Jun 2026).** Task 6 depended entirely on Task 4. With Task 4 cancelled, a
> voluntary yield has nothing to accomplish — no callback will parse data during the yield.
> See [Why Tasks 4 and 6 Were Cancelled](#why-tasks-4-and-6-were-cancelled) below.

### Summary

After Task 4 exists, when the fiber has only 1 command left, it takes a brief voluntary pause
(yield). During that pause, the proactor can receive and pre-parse the next TCP burst. When
the fiber wakes up, it has a full batch ready instead of just 1 command. Like waiting an extra
second at the elevator for more people to board before going up.

### Why This Works Once Task 4 Exists

With Task 4 (Eager Parsing in `NotifyOnRecv`), the proactor callback reads and parses while the
fiber is suspended. This changes the yield equation completely:

```
V2 fiber: queue has 1 cmd left → Yield()
  → fiber suspends
  → proactor runs event loop
  → TCP completion fires NotifyOnRecv
  → callback reads + parses → pushes commands into parsed_cmd queue
  → io_event_.notify()
  → fiber resumes
V2 fiber: queue now has 30 commands → skip Flush + await → keep executing
```

This perfectly recreates V1's dual-fiber batching behavior with a single fiber and an event
callback.

### The Fix

~20 lines, trivial once Task 4 is working:

```cpp
uint64_t cur_epoch = fb2::FiberSwitchEpoch();
if (parsed_cmd_q_len_ <= 1 && cur_epoch == prev_epoch
    && io_buf_.InputLen() == 0 && pending_input_) {
    ThisFiber::Yield();  // Proactor fires NotifyOnRecv, which eagerly parses
}
prev_epoch = cur_epoch;
```

The `pending_input_` guard ensures we only yield when the kernel has signaled new TCP data,
avoiding artificial latency on isolated single commands.

### Expected Impact

Allows pipeline fragments to coalesce before execution. The fiber skips both the `await` block
and its associated flush.

### Risk

Low. Trivial once Task 4 is stable.

---

## Task 7: `io_event_.notify()` — Skip Redundant Wakeups (Deduplication) — P2 (Investigate First)

### Summary

When 100 commands arrive across 10 TCP packets, `notify()` fires 10 times. But if Helio
already ignores duplicate wakeups internally, adding extra code to skip them would actually
slow things down (cache pressure). So: measure first, only fix if it's actually a problem.

### The Problem (Theoretical)

`io_event_.notify()` is called from multiple paths: `NotifyOnRecv`, `ExecuteBatch()`,
`ReplyBatch()`, backpressure relief. For a 100-command pipeline arriving in 10 TCP segments,
the callback fires 10 times.

### Status: INVESTIGATE BEFORE IMPLEMENTING

Helio's `EventCount` (which powers `io_event_`) likely already handles redundant `notify()`
calls internally (skipping duplicates). Adding an `std::atomic<bool>` on the hottest path
introduces cache-line bouncing overhead.

**Required investigation:**
1. Read helio's `EventCount::notify()` implementation — check if it short-circuits when already
   signaled.
2. Profile `io_event_.notify()` overhead with `perf` under a saturated pipeline benchmark. If
   it's <1% of CPU time, this task is not worth the complexity.
3. Only implement the atomic flag approach if both checks show real overhead.

### Clarification: Task 7 Does Not Fix the p=1 Pubsub Regression

Task 7 targets **redundant wakeups while the fiber is already awake** — for example, 10 TCP
segments arriving for a pipeline where `notify()` fires 10 times during a single scheduling
slot. This is unrelated to the p=1 pubsub regression.

At p=1, the subscriber fiber is **asleep** when each message arrives. Every `notify()` is
legitimate — `dispatch_q_` was empty when the message was enqueued. Adding a
`!had_pending_messages` guard (mirroring V1's logic in `SendAsync`) would be correct but
saves nothing at p=1, because `had_pending_messages` is always false when the first message
of each burst arrives.

**The p=1 regression is a scheduling timing problem, not a redundant-wakeup problem.** See
Task 10.

### Risk

Unknown until investigated. Could be premature optimization with negative ROI.

---

## Task 8: Soft Backpressure / Smart Yielding — P2

### Summary

Current backpressure is binary — either fine or the fiber parks completely (expensive). The
fix adds a "soft limit" in the middle: at 75% full, do a quick yield instead of a full sleep.
Like coasting before braking hard.

### The Problem

V2's backpressure is binary: either under limit (proceed) or over limit (park the fiber via
`io_event_.await()`). Parking is expensive — the fiber goes to sleep and must wait for another
connection to free memory.

### The Fix

Add a soft limit (e.g., 75% of the hard limit). Between soft and hard:

```cpp
if (hard_over) {
    // Current behavior: park the fiber
} else if (soft_over) {
    ThisFiber::Yield();  // Let other connections drain, then re-check
}
```

### Expected Impact

Smoother throughput under memory pressure. Fewer full-park/wake cycles.

### Risk

Medium. Must tune the soft limit. Needs benchmarking.

---

## Task 9: Full io_uring Buffer Ring Integration — P3 (Future / Endgame)

### Summary

Today, we already use iouring, but io_uring just replaces the syscall mechanism, not the memory management.
 each connection allocates its own io_buf_, does recv() into it, parses from it.
Right now each connection owns its own 4KB receive buffer = 40MB for 10K connections. With
io_uring buffer rings, the kernel manages a shared pool: when data arrives, it deposits it
into a pool buffer and hands you the pointer — and you own that buffer until you're done.
This eliminates per-connection buffers AND solves the use-after-free problem from Task 4
Stage 2, because each connection's data lives in its own kernel-provided slot.

### The Problem

Each connection allocates its own `io_buf_` (default 4KB, can grow). With 10K connections per
thread, that's 40MB+ of mostly-cold buffers.

### Why io_uring Buffer Rings Are the Endgame

With io_uring buffer rings (`IORING_OP_PROVIDE_BUFFERS`, kernel 5.19+):

- The kernel manages a pool of memory buffers.
- When a TCP packet arrives, the kernel writes it into a pool buffer and hands Dragonfly the
  pointer.
- You own that specific buffer until you explicitly return it to the kernel.
- The kernel **guarantees** it won't reuse that buffer until you give it back.

This eliminates the shared-buffer use-after-free problem completely:
- No per-connection `io_buf_` needed.
- Zero-copy pointers into kernel-provided buffers are safe even if the fiber yields or blocks.
- Buffer is returned after all commands referencing it are executed.

The codebase already has partial support: `MaybeEnableRecvMultishot()` and the
`io::MutableBytes` path in `NotifyOnRecv` exist. The remaining work is:
1. Making multishot recv the default for non-TLS connections on io_uring.
2. Integrating buffer ring lifecycle with command execution (pin buffer until release).
3. Removing the fallback `ReadPendingInput()` / `TryRecv()` path.

**This is a helio-level change**, requiring modifications to `UringSocket` and buffer ring
management in helio.

### Expected Impact

- **Memory:** From N × 4KB per thread to kernel-managed pool. Massive reduction.
- **Syscalls:** Eliminates one `recv()` syscall per read event.
- **Safety:** Kernel-guaranteed buffer lifetime enables zero-copy shared buffers without the
  use-after-free risks described in Task 4.

### Risk

High. Requires kernel 5.19+, complex buffer ring management, and TLS cannot use this path.

---

## Task 10: Deferred Fan-Out Batching (Pubsub p=1) — P2

### Summary

Split PUBLISH's subscriber fan-out into two phases: first enqueue to all subscribers, then
notify all at once. By the time the first subscriber fiber wakes, the rest of the fan-out has
already landed in their queues. The existing `ProcessControlMessages` do-while batching loop
then drains them all before flushing — one `sendmsg` syscall for the whole burst.

### The Problem

PUBLISH currently fans out to N subscribers by calling `SendAsync` on each in sequence.
`SendAsync` calls `io_event_.notify()` unconditionally for V2, waking the subscriber fiber
immediately:

```
for each subscriber:
    dispatch_q_.push_back(msg)   // enqueue
    io_event_.notify()           // wake immediately  <— too early
```

The subscriber fiber wakes between enqueue steps, finds 1 message, processes it, flushes
(1 `sendmsg`), and sleeps. At p=1 with 10 subscribers and 50K publishes, this produces
~550K syscalls — 1 per message delivery — regardless of V2's do-while batching in
`ProcessControlMessages`, because the queue is always empty when each notification fires.

V1 avoids this because `cnd_.notify_one()` puts AsyncFiber in the **ready queue** but does
not immediately yield to it. The publishing thread continues fan-out, queuing messages to
other subscriber connections. By the time the scheduler runs AsyncFiber, 2–3 messages have
typically accumulated. This is an accidental coalescing benefit from the fiber scheduler,
not an explicit design.

### The Fix

Decouple enqueue from notify in the fan-out loop:

```cpp
// Phase 1: enqueue to all subscribers (no wakeups yet)
for (auto& sub : subscribers) {
    sub->EnqueueAsync(msg);   // push to dispatch_q_ + update stats, no notify
}

// Phase 2: wake all subscribers in one pass
for (auto& sub : subscribers) {
    sub->WakeAsync();         // io_event_.notify() only
}
```

This requires splitting the internal `SendAsync` path into:
1. `EnqueueAsync(MessageHandle)` — pushes to `dispatch_q_` and updates stats, no notification.
2. `WakeAsync()` — calls `io_event_.notify()` only.

The fan-out site in `channel_store.cc` / the PUBLISH command handler calls `EnqueueAsync`
for all N subscribers, then calls `WakeAsync` for all N. By the time subscriber #1's fiber
runs, subscribers #2…N have their messages already queued. `ProcessControlMessages`'s
`Yield()` at the bottom of the do-while loop picks up the coalesced messages in one
scheduling slot — single flush for the whole burst.

### Expected Impact

At p=1 with 10 subscribers, reduce V2 syscalls from ~550K toward V1 levels (~125–250K).
Does not affect p≥10 (already addressed by Task 5's PR).

### Dependencies

Task 5 (wakeup batching PR) must be merged first — without the `ProcessControlMessages`
do-while loop, the deferred fan-out has nothing to coalesce into.

### Risk

Medium. The fan-out path is correctness-critical: ordering guarantees, backpressure handling,
monitor and checkpoint message interleaving. Needs thorough testing.

---

## ~~Task 11: V2 Subscriber-Side Reply Batching (SetBatchMode in ProcessControlMessages) — MERGED~~

### Summary

When `ProcessControlMessages` drains multiple queued PubSub messages in one pass, each reply
is flushed immediately via `FinishScope()` (because `batched_==false`). V1's `AsyncFiber`
explicitly set `SetBatchMode(GetPendingMessageCount() > 1)` before dispatching, coalescing N
subscriber replies into a single `sendmsg`. V2 should do the same.

Note: Task 5's do-while + Yield coalesces **wakeups** (accumulates messages in `dispatch_q_`),
but without batch mode each `SendBulkStrArr` still flushes individually. Task 11 is the
complementary piece that coalesces the **replies** those accumulated messages produce.

### The Problem

Each PubSub message dispatched through `AsyncOperations::operator()(const PubMessage&)` calls
`SendBulkStrArr` → `ReplyScope` → `FinishScope()`. Since `batched_==false` during
`ProcessControlMessages`, `FinishScope()` calls `Flush()` immediately — one `sendmsg` syscall
per message even when 50 messages were batched in `dispatch_q_`.

The do-while loop's comment says "combining many PubSub replies into a single sendmsg syscall"
but that's aspirational, not actual behavior without batch mode.

### The Fix

Set batch mode at the top of `ProcessControlMessages`, flush explicitly at every exit:

```cpp
bool Connection::ProcessControlMessages(uint32_t quota) {
  DCHECK(!reply_builder_->IsBatchMode());
  // Batch subscriber replies — a single sendmsg for the entire drain pass.
  reply_builder_->SetBatchMode(true);
  absl::Cleanup batch_guard = [this] {
    reply_builder_->SetBatchMode(false);
    reply_builder_->Flush();
  };

  // ... existing do-while drain loop unchanged ...
}
```

The `absl::Cleanup` guarantees batch mode is reset and flushed on every exit path (quota
reached, migration break, error, normal completion).

### Expected Impact

Reduces subscriber-side `sendmsg` syscalls proportional to queue depth. If 30 PubSub messages
accumulated during the Yield(), that's 30 → 1 syscalls. Complements Task 5 (wakeup
coalescing) and Task 10 (fan-out timing).

### Dependencies

None. Independent of all other tasks. Can be implemented immediately.

### Risk

Low. The `absl::Cleanup` pattern already guards batch mode in `ReplyBatch()` and
`ExecuteBatch()`. The only subtlety: must ensure `Flush()` is safe to call unconditionally
(it is — `Flush()` already has a fast-path that returns immediately when nothing is buffered).

---

## Recommended Implementation Order

### Phase 1: Quick fixes

| Task | Description | Effort | Status |
|------|-------------|--------|--------|
| **Task 3** | Bounded dispatch quota — port V1's `async_dispatch_quota` | Small | **MERGED** |
| **Task 5** | V2 pubsub wakeup coalescing — fix the 2× syscall regression | Medium | **MERGED** |
| **Task 11** | Subscriber-side reply batching — SetBatchMode in ProcessControlMessages | Small | **MERGED** |

### Phase 2: Measure, then optimize

| Task | Description | Effort | Status |
|------|-------------|--------|--------|
| **Task 14** | Fiber-level time profiling — measure where V2 actually spends time before picking the next optimization | Small–Medium | **TODO — DO THIS FIRST** |
| ~~**Task 15**~~ | ~~Idle-flush coalescing delay — port `pipeline_wait_batch_usec` to V2's idle-await path~~ | ~~Trivial~~ | **CANCELLED** |
| ~~**Task 16**~~ | ~~Transactional-command reply-flush coalescing — fix ZADD `batched_=false` auto-flush~~ | ~~Small~~ | **CANCELLED** |
| ~~**Task 4 Stage 1**~~ | ~~Eager parsing in NotifyOnRecv~~ | ~~Large~~ | **CANCELLED** |
| ~~**Task 6**~~ | ~~Epoch yield~~ | ~~Trivial~~ | **CANCELLED** |
| **Task 7** | notify() skip redundant wakeups — investigate helio first, implement only if needed | TBD | TODO (after Task 14 data) |
| **Task 10** | Deferred fan-out batching — fix pubsub p=1 regression | Medium | TODO (after Task 14 data) |

### Phase 3: Memory and backpressure

| Task | Description | Effort |
|------|-------------|--------|
| **Task 8** | Soft backpressure (independent, benefits from Task 4's larger batches) | Medium |
| **Task 9** | io_uring buffer rings — the shared-buffer endgame | Large |
| **Task 4 Stage 2** | Shared IoBuf (only after Task 9 provides safe lifetime management) | Large |

### Phase 4: TLS + remaining gaps (after benchmarks)

| Task | Description | Effort |
|------|-------------|--------|
| **Task 12** | TLS support for IoLoopV2 — required for both MC and RESP | Large |
| **Task 13** | Conditional SquashPipeline for V2 — only if M2 ZADD benchmarks show significant regression | Medium |

### Measurement

After each phase, re-run `bench_v2.sh` with all modes. Targets:
- **Phase 1:** V2 pubsub syscalls at p≥10 match V1's order of magnitude (Task 5 PR: ~6.4K at
  p=100, ~29K at p=10). Task 10 targets the remaining p=1 regression (~550K → ~125–250K).
- **Phase 2:** V2 throughput RPS matches V1 at p=1 (currently ~30% lower, 44K vs 64K RPS).
- **Phase 3:** Memory per connection drops significantly; V2 matches or exceeds V1 across all
  benchmarks.
- **Phase 4:** TLS connections can use IoLoopV2; sync-heavy pipelines (ZADD) within acceptable
  regression threshold vs V1 (or SquashPipeline ported if not).

---

## Addendum: Existing Codebase TODO Audit

| Line  | Existing TODO Text | Resolution |
|-------|--------------------|------------|
| ~2847 | "Possibly don't flush unconditionally" | **Resolved** by merged PR (flush removed from ReplyBatch for V2) |
| ~2852 | "Properly handle backpressure" | Resolved via Task 3 (bounded quota + conditional notification) |
| ~2101 | "Poissbily optimize wakeups" | Handled by Task 7 (skip redundant wakeups while fiber is awake — investigate first). Does **not** fix the p=1 pubsub regression; see Task 10 (deferred fan-out batching). |
| ~2811 | "optimize CanReply with looking up waiter key" | Micro-optimization: replace `parsed_head_->CanReply()` in the await predicate with a direct waiter key check |

---

## Task 12: TLS Support for IoLoopV2 — P1 (Required)

### Summary

IoLoopV2 is currently non-TLS only (both Memcache and RESP). TLS connections fall back to V1.
This blocks V2 adoption for any production deployment requiring encryption.

### The Problem

The V2 event loop relies on `io_uring` multishot recv and `NotifyOnRecv` callbacks, which
operate on raw socket FDs. TLS adds an intermediate layer (`TlsSocket`) that performs
encryption/decryption between the kernel buffer and the application buffer. The current V2
path bypasses this layer.

### Risk

High. TLS introduces buffering semantics (partial reads, renegotiation) that conflict with
the assumptions made by `NotifyOnRecv` and `io_event_.await()`. Requires careful integration
with helio's `TlsSocket` abstraction.

---

## Task 13: Conditional SquashPipeline for V2 — P2 (Conditional)

### Summary

V1's `SquashPipeline()` aggressively batches execution of pipelined commands that don't
support async dispatch (e.g., ZADD, SADD, sorted set operations). V2 currently processes
these one-at-a-time via `ExecuteBatch()`. If M2 cloud benchmarks show significant regression
for these workloads, we need a V2 equivalent.

### Status: CONDITIONAL ON M2 BENCHMARK RESULTS

Do not implement until the M2 ZADD cloud benchmark (Epic #6006, Milestone 2 sub-issue 3)
quantifies the actual regression. If V2 is within acceptable bounds (e.g., <10% slower),
the complexity may not be justified — V2's deferred flushing already provides some natural
batching.

### The Problem

V1's `SquashPipeline` uses `DispatchManyCommands()` to feed N commands to the execution
engine in one call, avoiding per-command dispatch overhead. V2's `ExecuteBatch()` dispatches
one command per iteration. For commands that cannot be async-dispatched, this means V2 pays
N function calls + N stat updates vs V1's 1 batched call.

### Risk

Medium. Porting `SquashPipeline` to V2's single-fiber model requires rethinking the
`async_dispatch` guard and the flush-skip heuristic (`parsed_cmd_q_len_ == pipeline_count`).

---

## Task 14: Fiber-Level Time Profiling (Measure Before Optimize) — P0 (NEXT)

### Summary

We don't know where V2's fiber actually spends its time. Every prediction so far has been
wrong (Task 4: "dramatic improvement" → net negative). Before picking the next optimization,
instrument the IoLoopV2 loop to answer: **what percentage of wall-clock time does the fiber
spend in each phase, and why does V2 flush 60% more often than V1?**

### Why This Must Come First

The batch density gap (V2: 5.9 vs V1: 9.4 at p=10) tells us V2 reaches the idle-await and
flushes more often. But we don't know WHY:

- **Hypothesis A:** V2 executes commands faster (no fiber-switch overhead between IoLoop and
  AsyncFiber), so it drains the queue before the next TCP segment arrives. If true, the
  "problem" is actually V2 being too efficient — the fix would be coalescing at the flush
  level, not at execution.
- **Hypothesis B:** V2 receives data in smaller chunks than V1's IoLoop fiber (multishot CQE
  delivers partial segments). If true, we're parsing fewer commands per wake cycle.
- **Hypothesis C:** Some unexpected yield point (backpressure, control messages, ParseRedis
  max_busy_cycles) causes premature returns to loop-top, triggering extra flushes.
- **Hypothesis D:** The proactor event loop overhead between wake and fiber-resume adds latency
  that V1 doesn't have (V1's IoLoop never sleeps on the await — it busy-loops on recv).

We can't distinguish these without measurements.

### What to Measure

**Phase 1: Per-loop-iteration counters (cheap, always-on)**

Add counters to IoLoopV2 that track per-connection stats exposed via `CLIENT INFO` or
`DEBUG CONNECTION <id>`:

```cpp
struct V2LoopStats {
  uint64_t loop_iterations;        // Total loop-top entries
  uint64_t idle_awaits;            // Times we actually parked at io_event_.await()
  uint64_t flushes;                // Times reply_builder_->Flush() actually sent data
  uint64_t cmds_executed;          // Total commands executed
  uint64_t cmds_per_wake;          // Histogram or running average: cmds between idle awaits
  uint64_t parse_calls;            // Times ParseRedis was called
  uint64_t cmds_per_parse;         // Commands produced per ParseRedis call
  uint64_t control_msg_processed;  // dispatch_q_ messages processed
  uint64_t backpressure_parks;     // Times we hit the backpressure await
  uint64_t read_pending_calls;     // Times ReadPendingInput was called
  uint64_t bytes_per_read;         // Average bytes per ReadPendingInput call
};
```

**Key derived metric:** `batch_density = cmds_executed / flushes`. This is what we already
know is low. But the counters above tell us WHY — is it because `idle_awaits` is too high
(we sleep too often)? Or because `cmds_per_parse` is too low (we parse too few per wake)?

**Phase 2: TSC-based time breakdown (conditional, flag-gated)**

Behind a `--v2_profile` flag, add `__rdtsc()` measurements:

```cpp
uint64_t t0 = __rdtsc();
ReadPendingInput();
uint64_t t_read = __rdtsc();
ParseRedis(...);
uint64_t t_parse = __rdtsc();
ExecuteBatch();
uint64_t t_exec = __rdtsc();
// ... accumulate deltas into per-phase counters
```

Report as percentages: "idle: 40%, read: 5%, parse: 15%, execute: 30%, flush: 10%".

Compare V1 vs V2 under identical workload to see WHERE the time distribution differs.

**Phase 3: Queue depth at flush points**

Every time `Flush()` actually sends data, log `parsed_cmd_q_len_` at that moment. If V2
flushes when the queue is empty (0 pending) vs V1 flushing when it has 5+ pending, that
immediately explains the density gap and points to the fix.

### Expected Outcome

A data-driven answer to "what should Task N+1 be?" rather than another guess. Possible
outcomes:

- "Fiber spends 60% idle → data arrives too slowly → need to investigate multishot delivery
  timing vs V1's busy-loop recv"
- "Fiber spends 80% in execute → V2 is already optimal, the gap is just the missing concurrent
  parse (fundamentally unsolvable without a 2nd fiber or thread)"
- "Fiber parks 3× more often than expected due to backpressure → Task 8 is the real fix"
- "Queue depth at flush is always 0-1 → V2 processes too fast, need explicit coalescing delay"

### Implementation

**Effort: Small–Medium.** Phase 1 counters are ~40 lines in IoLoopV2 + ~20 lines to expose
via `DEBUG CONNECTION`. Phase 2 (rdtsc) is another ~30 lines behind a flag. No architectural
risk — pure read-only instrumentation.

### Risk

Low. Counters are plain integer increments on the per-connection `V2LoopStats` struct
(single-thread access only — no atomics needed). TSC reads are ~20ns each. Flag-gated
profiling adds zero overhead when disabled.

### Refined Implementation (Synthesis of Multi-Bot Code Review)

> **Note:** Tasks 15 and 16 grew directly out of the Task 14 instrumentation work. Task 14 benchmarks should be run first to establish baseline batch-density numbers; Tasks 15 and 16 are the two concrete optimizations those numbers motivate.

Three independent reviews (Perplexity, Gemini, and the original plan) agreed: proceed with
profiling before any further optimization. The following refinements are required before
writing code:

#### 🔴 Critical: The TSC Fiber-Suspension Trap (Gemini)

The original plan wraps `ExecuteBatch()` and `Flush()` with raw `__rdtsc()`:

```cpp
uint64_t t0 = __rdtsc();
ExecuteBatch();
uint64_t t_exec = __rdtsc(); // WRONG — may include time other fibers ran
```

This is incorrect. Both functions can suspend the fiber (async transaction barriers in
`ExecuteBatch`, `fc.Get()` in io_uring Flush). The delta will include wall-clock time from
**other fibers executing on the same thread**. Execution will appear to take 100× longer than
it actually does.

**Fix:** Only measure CPU-bound phases that never yield (`ParseLoop`, serialization).
For phases that may suspend, either:
- Measure sub-segments around the known suspension points only, OR
- Use event counts alone (Phase 1) without TSC for those phases.

#### Proactor Wake Latency — Directly Tests Hypothesis D (Gemini)

Add a `last_notify_tsc` field to `Connection`. In the `RegisterOnRecv` callback, set it
before calling `io_event_.notify()`. At loop-top in IoLoopV2, read `__rdtsc() - last_notify_tsc`.
This gives the exact fiber scheduling delay: time from "kernel delivered data" to "fiber
started processing it". V1 has no such delay (IoLoop fiber busy-loops on recv). If this delta
is large (thousands of cycles), it directly explains the batch density gap.

#### Flush Calls vs Flush Syscalls (Perplexity)

Split the single `flushes` counter into two:
- `flush_calls` — every call to `reply_builder_->Flush()`
- `flush_syscalls` — only when `Write()` actually queues a send (non-empty buffer)

The density problem is about real `sendmsg` calls, not no-op flushes on empty buffers.
If `flush_calls` >> `flush_syscalls`, the flush path is fine and the overhead is elsewhere.

#### Tag Flushes by Cause (Perplexity)

```cpp
enum FlushReason { kIdleAwait, kBackpressure, kManual };
```

Track `flush_reason_idle_await`, `flush_reason_backpressure` separately. This directly
identifies which code path is driving extra flushes.

#### Two-Dimensional Queue Depth at Flush (Gemini)

At each real flush, record both:
- `flush_queue_depth_accum += parsed_cmd_q_len_` — commands still parsed but not yet executed
- `flush_io_buf_input_accum += io_buf_.InputLen()` — raw bytes not yet parsed

If `queue_depth` is consistently 0 but `io_buf_input` is consistently high → Hypothesis B
(data arrives in small parse-starved chunks). If both are 0 → Hypothesis A (V2 drains
everything perfectly, just flushes too eagerly).

#### Histogram, Not Averages (Perplexity)

For `cmds_per_wake` and `cmds_per_parse`, use a small fixed histogram
(buckets: 0, 1, 2–4, 5–8, 9–16, >16) rather than a running average. A bimodal distribution
(mostly 0–1 with rare spikes) tells a different story than a flat average of 3.

#### Callback vs Fiber Parse Calls (Perplexity)

Track `parse_calls_callback` and `parse_calls_fiber` separately. Directly measures whether
the multishot recv path does meaningful parsing work or is just a stub.

#### `CycleClock::Now()` over raw `__rdtsc()` (Perplexity)

Use `CycleClock::Now()` (already used in this codebase) rather than bare `__rdtsc()`. It
handles frequency scaling and keeps the code portable.

#### Stats Location: Per-Connection (Gemini)

Keep `V2LoopStats` as a field on the `Connection` object, not in `tl_facade_stats`. IoLoopV2
runs entirely within one connection's context, so per-connection isolation is correct. Expose
via `DEBUG CONNECTION <id>` and optionally dump to VLOG on connection close.

#### Updated `V2LoopStats` struct

```cpp
struct V2LoopStats {
  // Phase 1: always-on event counters
  uint64_t loop_iterations;           // Loop-top entries
  uint64_t loop_no_work;              // Iterations that did no read/parse/execute/flush
  uint64_t idle_awaits;               // Times fiber parked at io_event_.await()
  uint64_t flush_calls;               // Total Flush() invocations
  uint64_t flush_syscalls;            // Flush() calls that actually sent bytes
  uint64_t flush_reason_idle;         // Flushes triggered by idle-await path
  uint64_t flush_reason_backpressure; // Flushes triggered by backpressure path
  uint64_t cmds_executed;             // Total commands executed
  uint64_t parse_calls_fiber;         // ParseRedis calls from main loop
  uint64_t parse_calls_callback;      // ParseRedis calls from NotifyOnRecv callback (expect 0 — EagerParse reverted; sanity check)
  uint64_t control_msgs_processed;    // dispatch_q_ messages drained
  uint64_t backpressure_parks;        // Times fiber parked on backpressure
  uint64_t backpressure_reliefs;      // Times backpressure woke and notified others
  uint64_t read_pending_calls;        // ReadPendingInput() calls
  uint64_t bytes_read_total;          // Total bytes from ReadPendingInput
  uint64_t bytes_sent_total;          // Total bytes in real flushes
  // Histograms (buckets: 0,1,2-4,5-8,9-16,>16)
  uint32_t cmds_per_wake_hist[6];     // cmds executed between idle awaits
  uint32_t cmds_per_parse_hist[6];    // cmds produced per ParseRedis call
  // Flush queue depth accumulator (divide by flush_syscalls for average)
  uint64_t flush_queue_depth_accum;   // parsed_cmd_q_len_ at each real flush
  uint64_t flush_io_buf_input_accum;  // io_buf_.InputLen() at each real flush
  uint64_t flush_inflight_count;      // flush_syscalls where HasInFlightCommands() was true
  // Phase 2: TSC timing (flag-gated, non-suspending phases only)
  uint64_t cycles_parse_total;        // CycleClock cycles in ParseLoop (never suspends)
  uint64_t cycles_read_total;         // CycleClock cycles in ReadPendingInput (sync path)
  uint64_t wakeup_latency_cycles;     // Sum of (loop-top TSC - last notify TSC)
  uint64_t wakeup_latency_count;      // Samples for above (for average)
};
```

### Risk

Low. Counters are plain integer increments on the per-connection `V2LoopStats` struct
(single-thread access only — no atomics needed). TSC reads are ~20ns each. Flag-gated
profiling adds zero overhead when disabled.

### Reporting Format

When dumping stats (on connection close via `VLOG(1)` or via `DEBUG CONNECTION <id>`), print
derived metrics in a single line for easy comparison between V1 and V2 runs:

```
[conn %d] iters=%lu no_work=%lu idle_awaits=%lu
  flush: calls=%lu syscalls=%lu idle=%lu bp=%lu inflight=%lu
  density=%.1f (cmds/flush_syscall)
  wake: avg_cmds=%.1f avg_bytes_read=%lu avg_bytes_sent=%lu
  wake_latency_avg=%.0f cycles  parse_cycles=%lu read_cycles=%lu
```

The three numbers that immediately diagnose the batch density gap:
1. `batch_density = cmds_executed / flush_syscalls` — is it close to V1's 9.4, or stuck at 5.9?
2. `flush_queue_depth_accum / flush_syscalls` — are we flushing with 0 commands pending or 5+?
3. `wake_latency_avg` — how much scheduling delay does the proactor add between `notify()` and fiber resume?

---

## Changelog

### v8 (current)
- **Tasks 4 and 6 CANCELLED:** 5-run A/B benchmark (commit 715ebbfc) proved Eager Parsing
  architecturally useless in V2's single-fiber cooperative model. Parsing in the `NotifyOnRecv`
  callback cannot overlap with execution because both share the same OS thread — it only
  rearranges work, adding context-switch overhead. Results: -8% at p=1 throughput, neutral
  elsewhere, and a catastrophic -92% ZADD regression due to queue bloat when async commands
  park the fiber. Task 6 (Epoch Yield) depended on Task 4 and is cancelled with it.
- **Phase 2 reorganized:** Removed dead tasks; remaining work is Task 7 (investigate) and
  Task 10 (deferred fan-out batching).
- **Key insight:** The real remaining bottleneck is batch density — at p=10, V2 achieves
  density 5.9 vs V1's 9.4, meaning V2 flushes replies ~60% more often than necessary.

### v7
- **Task 5 marked MERGED:** PR #7437 landed. V2 pubsub wakeup coalescing now active.
- **Yield experiment results:** Disabling V1's epoch yield block (commit 2d763977) showed mixed
  results — improved throughput at p=100/500 (+22%/+41%) but hurt p=1 (−19%), fragmentation
  (−53% at p=1), ZADD p=500 (−70%), and pubsub (−27% to −32% at low pipelines). Conclusion:
  the yield helps V1 at low pipelines by giving IoLoop time to fill the queue, but hurts when
  there's already enough data. Task 6 remains valid for V2 (with `pending_input_` guard) once
  Task 4 exists.
- **Phase 1 status column added.** Tasks 3 and 5 both merged; only Task 11 remains.
- **Task 11 merged.** PR [#7479](https://github.com/dragonflydb/dragonfly/pull/7479) (issue [#232](https://github.com/dragonflydb/dataplane-private/issues/232)). All Phase 1 tasks complete.

### v6
- **New Task 12: TLS Support for IoLoopV2.** Required for both MC and RESP production
  deployments. Currently all TLS connections fall back to V1.
- **New Task 13: Conditional SquashPipeline for V2.** Only if M2 ZADD benchmarks show
  significant regression. Tracks the missing sync-command batching logic.
- **Phase 4 added** to Recommended Implementation Order.

---

## Why Tasks 4 and 6 Were Cancelled

### Task 4: Eager Parsing in NotifyOnRecv — Architecturally Unsound

**Benchmark:** 5-run A/B test (commit 715ebbfc), 2 proactor threads, cross-machine, all 4
modes (throughput, fragmentation, zadd, pubsub).

**Results (V2 median RPS, with vs without Eager Parsing):**

| Mode | p=1 | p=10 | p=100 | p=500 |
|------|-----|------|-------|-------|
| throughput | -8% | +2% (noise) | -2% (noise) | -2% (noise) |
| fragmentation | -3% | -2% | +2% | **-10%** |
| zadd | +5% | **-43%** | -4% | **-92%** |
| pubsub | +1% | **-19%** | -4% | -5% |

**Why it failed — the fundamental flaw:**

Dragonfly uses cooperative fibers on a single OS thread per proactor. The `NotifyOnRecv`
callback and the IoLoopV2 fiber share the **exact same CPU core**. They can never execute
concurrently. The theory was "parse in the callback while the fiber executes commands" — but
this is physically impossible. The callback only fires when the fiber has yielded control to
the proactor event loop. By that point, execution is already finished and the fiber was about
to parse anyway.

Moving parsing from the fiber context to the callback context doesn't save wall-clock time —
it just rearranges the same work on the same thread with worse cache locality and an extra
context switch.

**Why p=1 regressed (-8%):** For single commands, the naturally tight
`recv → parse → execute → reply` path was split across two contexts (callback parses, then
fiber executes), adding overhead for zero gain.

**Why ZADD collapsed (-92% at p=500):** ZADD is a multi-key transactional command. When
pipelined, the fiber dispatches via `SingleHopAsync()` and parks at idle-await waiting for
shard completion. The park sets `phase_ == READ_SOCKET`, which the EagerParse guard interprets
as "safe to parse." The callback aggressively stuffs hundreds of commands into the queue while
the fiber is trickling through them one async-command-at-a-time. The queue hits the
backpressure limit → thrashing → 13x regression.

**Could we fix the bug?** Yes — adding `if (parsed_head_ && !parsed_head_->CanReply()) return;`
would prevent queue bloat. But even with the fix, the throughput data shows zero benefit for
the primary workload (SET/GET). The optimization is architecturally useless, not just buggy.

### Task 6: Epoch-Based Yield — No Purpose Without Task 4

Task 6's sole purpose was to create proactor time-slices for the EagerParse callback to fire
during execution. Without EagerParse, a voluntary yield just adds latency — no callback will
parse data during the pause, so the fiber wakes to the exact same state it left.

The fiber already yields naturally at:
1. Socket writes (`fc.Get()` in io_uring SENDMSG)
2. Async transaction barriers (`run_barrier_.Wait()`)
3. The idle await when no data is available

These provide sufficient scheduling opportunities for the proactor to process io_uring
completions without artificial yields.

### v5
- **Task 3 marked MERGED:** PR #7234 landed.
- **Task 5 updated:** PR #7437 submitted (wakeup batching via do-while + Yield in
  `ProcessControlMessages`).
- **New Task 11: V2 Subscriber-Side Reply Batching.** `SetBatchMode(true)` in
  `ProcessControlMessages` so accumulated PubSub replies coalesce into a single `sendmsg`.
  Complements Task 5 (wakeup coalescing) — Task 5 batches the wakeups, Task 11 batches the
  replies those wakeups produce.
- **Phase column added** to the task list table for quick at-a-glance scheduling.

### v4
- **Task 5 Expected Impact updated:** Clarified that the PR fixes p≥10 (−83% to −96% syscalls)
  but p=1 remains at the theoretical minimum (~550K). Added root cause: V1's
  `cnd_.notify_one()` allows scheduling latency to accumulate messages before AsyncFiber runs;
  V2's `io_event_.notify()` wakes the subscriber sooner, eliminating accidental coalescing.
- **Task 7 clarification added:** Explicit note distinguishing "redundant wakeups while awake"
  (what Task 7 addresses) from the p=1 scheduling timing regression (what Task 7 does *not*
  fix). Cross-reference to Task 10.
- **New Task 10: Deferred Fan-Out Batching.** Splits `SendAsync`'s fan-out into
  `EnqueueAsync` + `WakeAsync` phases so all subscriber messages land before any fiber wakes.
  Targets p=1 pubsub regression. Depends on Task 5 PR.
- **Addendum TODO audit updated:** Task 7 entry now cross-references Task 10 for p=1.
- **Measurement targets updated** to reflect Task 5 PR results and Task 10's p=1 goal.

### v3
- **Tasks 1 & 2 struck through:** Task 1 merged. Task 2 reclassified as N/A for V2 standalone
  (revived as Task 6, dependent on Task 4).
- **Tasks 4 & 5 merged:** Old Task 5 (Shared IoBuf) folded into Task 4 as Stage 2. They are
  architecturally inseparable — parsing consumes the buffer, so shared buffers only make sense
  with eager parsing.
- **New Task 5: Pubsub wakeup coalescing.** The V2 pubsub regression (2× syscalls, 50–73%
  lower RPS vs V1) is a wakeup granularity problem, not a flush problem. Adding a flush back
  would undo the merged PR's pipeline improvement.
- **New Task 6:** Epoch yield revived as a dependent task on Task 4. With eager parsing in
  NotifyOnRecv, yielding allows the proactor to parse more data, recreating V1's dual-fiber
  batching in a single fiber.
- **Shared buffer lifetime analysis added** to Task 4: detailed explanation of the
  use-after-free problem (BLPOP example), evaluation of four mitigation approaches, and
  recommendation to defer shared buffers until io_uring buffer rings (Task 9).
- **Old Task 8 (io_uring multishot) expanded** to Task 9 with buffer ring focus — positioned as
  the endgame that safely enables shared buffers.
- **Implementation phases restructured** based on dependency analysis and benchmark data.
- **Benchmark results added** from the merged PR (92K → 5.7K syscalls at p=500).

### v2
- Task 2: Added mandatory `pending_input_` guard. Risk upgraded to Low-Medium.
- Task 6: Downgraded to "Investigate." Added helio audit steps.

### v1
- Initial document.

---

## ~~Task 15: Idle-Flush Coalescing Delay (`pipeline_wait_batch_usec` for V2) — CANCELLED~~

> **CANCELLED (4 Jun 2026).** Cross-machine benchmarks showed significant regressions with a
> 50 µs coalescing delay: −28% p100 latency on multi-connection SET, −33% on pubsub, and
> −60% on synchronous commands (ZADD). The improvement was limited to a single-connection
> scenario (+15% p100). The root cause: with multiple concurrent connections the server is
> continuously busy, so the idle wait adds pure latency rather than amortizing flushes.
> Unlike V1, V2 has no concurrent parser fiber — nothing reads the socket during the sleep,
> making the mechanism far less effective than originally expected.
> The branch was tagged as `task-15-idle-flush-coalescing-delay-cancelled-4-6-26` and pushed
> to the fork for reference.

### ~~Summary~~

~~V1's `AsyncFiber` sleeps up to `pipeline_wait_batch_usec` microseconds before dispatching
the last command in the queue, giving the `IoLoop` fiber time to parse more commands from the
next TCP segment. V2 has no equivalent — it falls straight through to `profiled_flush` and
`io_event_.await()`. This task ports the mechanism to V2's idle-await path.~~

### The Problem

In V2, `pipeline_wait_batch_usec` is read from flags and cached thread-locally (line 234)
but is only used in V1's `AsyncFiber` (lines 2020–2021 of `dragonfly_connection.cc`):

```cpp
if (pipeline_wait_batch_usec > 0) {
  ThisFiber::SleepFor(chrono::microseconds(pipeline_wait_batch_usec));
}
```

V2's idle block does nothing before flushing:

```cpp
if (!should_wake()) {
  profiled_flush(stats_v2_.flush_reason_idle);   // flush immediately
  io_event_.await(should_wake);                   // then sleep
}
```

When V2 finishes all queued commands, the TCP buffer may contain a new burst that hasn't
been read yet (it's sitting in the kernel buffer waiting for the next `ReadPendingInput()`
call). Flushing immediately and then sleeping means those bytes arrive only after a round-trip
through `io_event_.notify()`.

### The Fix

Sleep briefly before flushing, just enough for the kernel to deliver the next TCP segment:

```cpp
if (!should_wake()) {
  if (pipeline_wait_batch_usec > 0 && parsed_cmd_q_len_ == 0) {
    ThisFiber::SleepFor(chrono::microseconds(pipeline_wait_batch_usec));
    // After sleeping, re-check — new commands may have arrived
    if (should_wake()) {
      phase_ = PROCESS;
      continue;
    }
  }
  profiled_flush(stats_v2_.flush_reason_idle);
  io_event_.await(should_wake);
}
```

The `parsed_cmd_q_len_ == 0` guard avoids sleeping when there are still commands to process.
The `should_wake()` re-check after the sleep avoids flushing if new data arrived during the
sleep (skipping the flush means those replies are batched with the new pipeline).

### Tradeoffs

| Scenario | Effect |
|----------|--------|
| p=1, single isolated command | Adds up to N μs latency to every response |
| p=10, next segment arrives within N μs | Avoids one flush + await cycle; density improves |
| p=100, all data already buffered | No effect — `should_wake()` returns true immediately |
| p=1 pubsub (message-per-wakeup) | Adds N μs latency per message — may hurt |

**Recommended starting value:** 50–100 μs. Cross-machine TCP RTT is typically 200–500 μs, so
100 μs buys the next segment ≈20–50% of the time without adding perceptible latency to most
deployments. Measure impact at p=1 vs p=10 vs p=100 before exposing to users.

### Relationship to V1

V1's mechanism works because `IoLoop` parses data during the sleep. V2 has no concurrent
parser — during the sleep, nothing reads the socket. This is less effective than V1's version.
However, the kernel may complete the recv and call `NotifyOnRecv` during the sleep, which
sets `pending_input_ = true` and calls `io_event_.notify()`, which causes `should_wake()` to
return true. The re-check after the sleep catches this case.

If Task 4 Stage 1 (Eager Parsing in NotifyOnRecv) is ever resurrected, this task becomes
much more effective — the sleep gives the proactor time to parse the next segment into the
queue, making it equivalent to V1's behavior.

### Expected Impact

Moderate. Likely to improve batch density from ~6 → ~8 commands per flush at p=10 (cross-
machine). No impact at p=100+ (data already in kernel buffer when fiber drains). Measurable
latency increase at p=1.

### Implementation

**Effort: Trivial.** ~15 lines in the idle-await block of `IoLoopV2`. The flag already
exists and is thread-locally cached.

### Risk

Low. Sleep is voluntary and bounded. The `should_wake()` re-check prevents any regression for
already-full pipelines. Easy to disable by setting `pipeline_wait_batch_usec=0`.

### Dependencies

Run Task 14 benchmarks first to establish baseline batch-density numbers. The sleep delta
is only useful if `batch_density` is currently below the theoretical maximum (it is — ~6 at
p=10 vs theoretical 10).

---

## ~~Task 16: Transactional-Command Reply-Flush Coalescing (ZADD `batched_=false`) — CANCELLED~~

> **CANCELLED (3 Jun 2026).** Task 14's `OnSendCallback` instrumentation disproves the
> hypothesis. ZADD replies **are** coalescing correctly: density=10.0 at p=10,
> density=49.7 at p=100. No fix needed. See [Why Task 16 Was Cancelled](#why-task-16-was-cancelled) below.

### Summary

Multi-shard transactional commands (ZADD, SADD, SMEMBERS, sorted-set operations, etc.) emit
their replies after the connection fiber resumes from a cross-shard transaction await. At that
resume point, `batched_` is `false`. `FinishScope()` therefore auto-flushes each reply
immediately via `SinkReplyBuilder::Flush()` — bypassing V2's idle-await `profiled_flush`.
The result: one `sendmsg` syscall per ZADD reply, regardless of pipeline depth.

This was first observed as an instrumentation blindspot (Task 14) — `profiled_flush` saw
`PendingBytes()==0` for every ZADD pipeline run and reported 0 flush syscalls. The root cause
is a real performance regression, not just a measurement artifact.

### Root Cause — Detailed

`ExecuteBatch()` sets batch mode for commands with a successor in the queue:

```cpp
// dragonfly_connection.cc ~line 2641
reply_builder_->SetBatchMode(ioloop_v2_ && is_head && (cmd->next != nullptr));
```

For ZADD at pipeline depth p:
- p=1: `cmd->next == nullptr` → `batched_=false` → `FinishScope()` auto-flushes → 1 syscall
- p>1: `is_head=true && cmd->next != nullptr` → `batched_=true` during `ExecuteBatch()`'s
  dispatch phase.

But ZADD is transactional: `service_->DispatchCommand()` schedules the transaction and
**suspends the fiber**. By the time the fiber resumes and `SendLong()` is called to emit the
integer reply, `ExecuteBatch()` has already exited (the RAII `absl::Cleanup` that called
`SetBatchMode(false)` ran when the fiber suspended). So even at p>1:

```
ExecuteBatch():
  SetBatchMode(true)    // queued next cmd exists
  DispatchCommand()     // suspends fiber → ExecuteBatch frame exits, Cleanup fires
                         // → SetBatchMode(false) ← HERE
  [fiber suspended]
  ...
  [fiber resumes inside transaction callback]
  SendLong(result)     // batched_=false → FinishScope() → Flush() → sendmsg
```

The `absl::Cleanup` unwinds when the fiber suspends across an `await` boundary inside
`ExecuteBatch`, resetting `batched_` before the reply is emitted.

### The Fix

There are two clean approaches:

**Option A: SetBatchMode around the reply, not the dispatch**

In `ReplyBatch()`, where replies are actually emitted (`cmd->SendReply()`), hold `batched_=true`
for the full batch. `ReplyBatch()` already does this:

```cpp
bool Connection::ReplyBatch() {
  reply_builder_->SetBatchMode(true);
  absl::Cleanup batch_guard = [this] { reply_builder_->SetBatchMode(false); };
  while (HasInFlightCommands() && parsed_head_->CanReply()) {
    cmd->SendReply();
    ...
  }
  if (!ioloop_v2_) { reply_builder_->Flush(); }
  return !reply_builder_->GetError();
}
```

The problem is that for transactional commands, `SendReply()` may trigger `SendLong()` which
calls `FinishScope()` from within `ReplyBatch()`'s `batched_=true` scope — so it should
already be coalesced. **Investigate whether `ReplyBatch()` is actually being called for ZADD
replies, or if they are being sent inline from `DispatchCommand()`'s callback.**

**Option B: Ensure batch mode survives the fiber suspension**

Instead of an `absl::Cleanup` that resets batch mode when the scope exits, store the intended
batch mode per-command and restore it when the fiber resumes:

```cpp
// Before suspending:
bool saved_batch = reply_builder_->IsBatchMode();
// After resuming:
reply_builder_->SetBatchMode(saved_batch);
```

This is harder to implement correctly since the resume point is deep inside helio's transaction
machinery.

**Option C: SetBatchMode in IoLoopV2 before ReplyBatch() (simplest)**

In `IoLoopV2`, before calling `ReplyBatch()`, always set batch mode based on whether more
commands are still queued:

```cpp
reply_builder_->SetBatchMode(HasInFlightCommands() || parsed_cmd_q_len_ > 0);
ReplyBatch();
reply_builder_->SetBatchMode(false);
```

This guarantees that replies for any command (sync or transactional) are batched as long as
more work is queued, regardless of what happened during `ExecuteBatch()`.

### Investigation First

Before implementing any fix, confirm the hypothesis by looking at `rb_sends` vs `flush_syscalls`
in Task 14's benchmark output:
- `rb_sends ≈ cmds` AND `flush_syscalls ≈ 0` → confirmed: FinishScope auto-flush fires, idle-
  await `profiled_flush` always sees empty buffer.
- `rb_sends ≈ cmds/p` AND `flush_syscalls ≈ cmds/p` → ZADD is already batching (different
  root cause).

### Expected Impact

For ZADD-heavy workloads at p≥10: reduce syscalls from 1-per-command to ~1-per-batch, matching
SET's behavior. This is the same 6–52× syscall reduction that SET already achieves at p=10–100.

### Relationship to Task 13

Task 13 (Conditional SquashPipeline) addresses execution batching for transactional commands —
reducing per-command dispatch overhead. Task 16 is complementary and independent: it addresses
reply-flush coalescing regardless of how commands are dispatched. Task 16 is lower risk and
should be investigated/implemented first.

### Implementation

**Effort: Small.** Primary work is confirming which code path emits ZADD replies (Option A
investigation), then adding 3–5 lines of batch-mode management. The `absl::Cleanup` pattern
for batch mode already exists in `ReplyBatch()` and `ExecuteBatch()`.

### Risk

Low. `SetBatchMode(true)` only suppresses `FinishScope()`'s auto-flush; it does not change
command execution logic. The final `Flush()` at idle-await always runs as a safety net.

### Dependencies

Task 14 benchmark data to confirm the hypothesis. No other task dependencies.

---

## Why Task 16 Was Cancelled

Task 14's `OnSendCallback` instrumentation (added to `SinkReplyBuilder::Send()`) captures every
real `sendmsg` syscall universally — including those triggered by `FinishScope()` — regardless
of whether they go through `profiled_flush` or not. This closed the instrumentation blind spot
that motivated Task 16 and, in doing so, disproved the hypothesis.

### Benchmark Evidence (3 Jun 2026)

| Workload | p  | density | sys (sends) | avg_qdepth |
|----------|----|---------|-------------|------------|
| ZADD     | 10 | **10.0**  | 3 001      | 1.0        |
| ZADD     | 100| **49.7**  | 603        | 1.3        |

`density = cmds / sends`. At p=10 every `Send()` carries exactly 10 replies; at p=100 it
carries ~50. This is **optimal coalescing** — no per-command syscall regression.

### Why the Hypothesis Was Wrong

The original analysis assumed ZADD replies were sent inline from `DispatchCommand()`'s
transaction callback, at which point `batched_=false` (because `ExecuteBatch()`'s
`absl::Cleanup` already ran). That is not what happens:

1. `ExecuteBatch()` dispatches ZADD as a **deferred** command (`cmd->IsDeferredReply()`).
   The fiber may suspend while the cross-shard transaction runs, but no reply is emitted yet.
2. When the transaction completes, `CanReply()` becomes true.
3. On the next `IoLoopV2` iteration, `ReplyBatch()` drains all ready deferred commands under
   `SetBatchMode(true)` — held for the entire drain loop by its own `absl::Cleanup`. So all
   ZADD replies in the current TCP burst are coalesced into one `Send()`.
4. The idle-await `profiled_flush` fires next; for ZADD at p=10 it already finds the buffer
   empty (one `Send()` per pipeline burst, not per command).

The `absl::Cleanup` batch-mode reset in `ExecuteBatch` is irrelevant for transactional commands
because they never emit replies from inside `ExecuteBatch` — replies are always deferred to
`ReplyBatch()`.

### FinishScope Sends Are Negligible

`hidden = rb_sends − flush_syscalls = 1` across the entire ZADD benchmark run. One
FinishScope-triggered send per run is a rounding artifact, not a regression.
