# Current Defragmentation Mechanism — Code Walkthrough

### 1. Registration: DefragTask as an Idle Task

The defrag task is registered during shard initialization. In engine_shard.cc:

```cpp
defrag_task_id_ = pb->AddOnIdleTask([this]() { return DefragTask(); });
```

This is called from `StartPeriodicHeartbeatFiber()`. The proactor calls `DefragTask()` when the thread has idle CPU cycles. The return value is a **priority** — higher means "call me again sooner."

### 2. Gate: DefragTask() — Should We Run?

engine_shard.cc — `DefragTask()`:

- Returns `0` (low priority) if `namespaces` is null
- Calls `defrag_state_.CheckRequired()` which returns a `SkipReason` enum
- If `NotSkipped` → creates a `PageUsage` object with **150µs quota** and calls `DoDefrag()`
- If skipped → increments the appropriate skip counter and returns priority `6` (low)

### 3. Decision: CheckRequired() — Is Fragmentation High Enough?

engine_shard.cc — `DefragTaskState::CheckRequired()`:

This is a multi-step gating function with 5 possible skip reasons:

1. **Cursor already active** (`cursor > 0`): A scan is in progress → return `NotSkipped` (continue it)
2. **MemoryTooLow**: Per-shard memory < 64KB → don't bother
3. **MemoryBelowThreshold**: RSS < `mem_defrag_threshold` (default 0.7) × `maxmemory` → not enough pressure
4. **CheckWithinInterval**: Less than `mem_defrag_check_sec_interval` (default 60s) since last check → too soon
5. **NotEnoughFragmentation**: Actually walks mimalloc's page bins **incrementally** (one bin per call) via `zmalloc_get_allocator_fragmentation_step()`. Sums committed vs wasted memory across all bins. If `wasted / committed < mem_defrag_waste_threshold` (default 0.2) → not fragmented enough

The bin-walk is the key insight — `CheckRequired()` is called repeatedly, and each call processes one mimalloc size-class bin. It returns `CheckInProgress` until all bins are visited. Only then does it compare wasted vs committed.

### 4. Fragmentation Check: zmalloc_get_allocator_fragmentation_step()

zmalloc_mi.c:

Walks mimalloc's internal page queues per size-class bin:
```
for each page in heap->pages[bin]:
    committed = page->capacity × page->block_size
    used = page->used × page->block_size
    if used < committed × threshold:
        wasted += (committed - used)
```

Skips `MI_BIN_FULL` (fully utilized pages). Iterates one bin per call, advancing `info->bin`. Returns `-1` (continue) or `0` (done).

### 5. Execution: DoDefrag()

engine_shard.cc — the core loop:

```
for each (dbid, cursor) position in the DashTable:
    Traverse(cursor, callback) where callback does:
        it->second.DefragIfNeeded(page_usage)  // value only, NOT key
    stop when quota depleted OR cursor wraps to 0
```

After the main table scan, it extends the quota by 50µs and also defragments **search indices** via `shard_search_indices_->Defragment(page_usage)`.

The cursor state is saved in `defrag_state_` so the scan resumes where it left off on the next idle invocation.

### 6. Per-Object: CompactObj::DefragIfNeeded()

compact_object.cc:

Dispatches based on the object's internal tag:

| Tag | Behavior |
|-----|----------|
| `ROBJ_TAG` | Delegates to `RobjWrapper::DefragIfNeeded()` |
| `SMALL_TAG` | `SmallString::DefragIfNeeded()` |
| `JSON_TAG` | `JsonWrapper::DefragIfNeeded()` (if not disabled by flag) |
| `SDS_TTL_TAG` | Checks page, reallocates sds string if underutilized |
| `INT_TAG` | No allocation, skip |
| `EXTERNAL_TAG` | Tiered/offloaded, skip |
| inline string (≤18 bytes) | No external alloc, skip |

### 7. Type-Specific: RobjWrapper::DefragIfNeeded()

compact_object.cc:

| Type | Function | Strategy |
|------|----------|----------|
| `OBJ_STRING` | `ReallocateString()` | allocate new → memcpy → free old |
| `OBJ_HASH` | `DefragHash()` | listpack: copy whole blob. StringMap: iterate nodes, `ReallocIfNeeded()` per node |
| `OBJ_SET` | `DefragSet()` | intset: copy blob. StringSet: iterate, realloc per entry |
| `OBJ_ZSET` | `DefragZSet()` | listpack: copy blob. SortedMap/ScoreMap: `DefragIfNeeded()` per tree node |
| `OBJ_LIST` | `DefragList()` | listpack: copy blob. QList: `DefragIfNeeded()` walks quicklist nodes |

Each sub-allocation calls `page_usage->IsPageForObjectUnderUtilized(ptr)` to check before moving.

### 8. Page Check: PageUsage::IsPageForObjectUnderUtilized()

page_usage_stats.cc:

```cpp
bool PageUsage::IsPageForObjectUnderUtilized(void* object) {
  mi_page_usage_stats_t stat;
  zmalloc_page_is_underutilized(object, threshold_, collect_stats_, &stat);
  return ConsumePageStats(stat);
}
```

`ConsumePageStats` returns `true` if `stat.flags == MI_DFLY_PAGE_BELOW_THRESHOLD`.

### 9. Allocator Level: mi_heap_page_is_underutilized()

Defined in mimalloc patch 2_return_stat.patch:

Given a pointer `p`:
1. `_mi_ptr_page(p)` → gets the mimalloc page containing `p`
2. Checks `page_heap == heap` (heap mismatch → flag `MI_DFLY_HEAP_MISMATCH`)
3. Checks `page->flags.x.in_full` (full page → flag `MI_DFLY_PAGE_FULL`)
4. Checks `page->prev == NULL` (head of page queue, used for new mallocs → flag `MI_DFLY_PAGE_USED_FOR_MALLOC`)
5. If no flags set AND `page->used ≤ page->capacity × ratio` → flag `MI_DFLY_PAGE_BELOW_THRESHOLD`

The `mi_page_usage_stats_t` struct ([patch 1_add_stat_type.patch](patches/mimalloc-v2.2.4/1_add_stat_type.patch)) returns: `page_address`, `block_size`, `capacity`, `reserved`, `used`, `flags`.

### 10. String Reallocation (The Actual Move)

compact_object.cc:

```cpp
void RobjWrapper::ReallocateString(MemoryResource* mr) {
  void* old_ptr = inner_obj_;
  inner_obj_ = mr->allocate(sz_, kAlignSize);
  memcpy(inner_obj_, old_ptr, sz_);
  mr->deallocate(old_ptr, 0, kAlignSize);
}
```

Allocate on a (likely different, better-packed) page → copy → free old. mimalloc will reclaim the old page when its last block is freed.

### 11. Configuration Flags

| Flag | Default | Purpose |
|------|---------|---------|
| `mem_defrag_threshold` | 0.7 | Min RSS / maxmemory ratio before defrag runs |
| `mem_defrag_check_sec_interval` | 60 | Seconds between fragmentation checks |
| `mem_defrag_waste_threshold` | 0.2 | Wasted/committed ratio to trigger defrag |
| `mem_defrag_page_utilization_threshold` | 0.8 | Page usage ratio below which objects are moved |

### Summary Flow

```
ProactorBase idle tick
  └─ DefragTask()                           [engine_shard.cc:419]
       ├─ CheckRequired()                   [engine_shard.cc:271]
       │    ├─ RSS < 70% maxmem? skip
       │    ├─ < 60s since last check? skip
       │    └─ zmalloc_get_allocator_fragmentation_step()  [zmalloc_mi.c:177]
       │         └─ walks mimalloc bins, computes wasted/committed
       │              └─ wasted < 20%? skip
       └─ DoDefrag(&page_usage)             [engine_shard.cc:338]
            └─ DashTable::Traverse(cursor, cb)
                 └─ for each value (NOT key):
                      CompactObj::DefragIfNeeded()      [compact_object.cc:1067]
                        └─ RobjWrapper::DefragIfNeeded()  [compact_object.cc:588]
                             └─ PageUsage::IsPageForObjectUnderUtilized(ptr)
                                  └─ mi_heap_page_is_underutilized()  [mimalloc patch]
                                       └─ page->used ≤ capacity × 0.8?
                                            └─ YES: allocate new, memcpy, free old
                 stop when 150µs quota depleted
```

**Key limitation:** Only `it->second` (values) are defragmented. `it->first` (keys) are never touched. This is the gap the hackathon project targets.

# Proposal - New Dragonfly Defragmentation: Unified Multi-Analysis Report

**Contributors:** Claude, Gemini, Perplexity, Gemini (follow-up)
**Date:** May 4, 2026

---

## 1. Universal Consensus (All 4 Agree)

| Topic | Verdict | Notes |
|-------|---------|-------|
| Keys defrag is correct | Keys pin their own pages in their size class. Adding keys to the movable set dramatically increases reclaimable pages. | All 4 confirm this is the highest-ROI change. |
| State machine is the right architecture | `IDLE → CENSUS → SELECT → EVACUATE → (VERIFY) → IDLE` with `DefragTaskState` struct, explicit invariants per phase. | Testable, debuggable, evolvable. |
| Top-k PQ with generations is over-engineered | Use `unordered_map` during census + `vector` + `partial_sort` at the end. Ship PQ post-hackathon. | All 4 agree this is a hackathon time-sink trap. |
| Double-walk (O(2N)) is the critical performance risk | Census walks all objects, EVACUATE walks again. This is the #1 concern. | Resolved: Bounded read-only CENSUS + Full-DB EVACUATE is the safest path for the hackathon. |
| VERIFY is low-priority for hackathon | Log stats at end of EVACUATE, transition to IDLE. Real VERIFY later. | Suggested as a post-hackathon stretch goal. |
| Revalidation in EVACUATE is mandatory | Pages mutate between census and evacuation. Must re-check flags/threshold before moving. | All 4 emphasize this. |
| `--experimental_defrag` flag | Branch in `DefragTask()`. Clean, reversible, safe. | Standard feature-flag pattern. |
| `cap/used` score is acceptable for v1 | Not optimal, but simple, monotonic, directionally correct. | Complex formulas have degenerate edge cases. |
| Testing plan is solid | Controlled fragmentation + snapshots + CSV/JSON + plotting. | All 4 validate the approach. |
| Census memory must be bounded | `max_census_pages` (configurable) prevents OOM on mass-deletion scenarios. | Default 1024–4096 for hackathon. |

---

## 2. The Key Insight: Why Defragging Keys Matters

### The Argument (All 4 Agree)

Currently `DoDefrag` only calls `it->second.DefragIfNeeded(page_usage)` — values only. Keys are never touched. The consequence:

- After bulk deletions, key-string pages become sparse but never get compacted.
- Even if all values are moved off a page, a single remaining key allocation pins the page.
- Keys are *numerous* (one per DB entry) so their pages have many blocks.

### Size-Class Segregation Reality

**Critical insight:** mimalloc segregates pages by block size class. Keys (~20-50 bytes) and values (variable, often larger) will **never share a mimalloc page**. Therefore:

- Defragging keys does NOT help unpin value pages.
- It unpins **key pages** (in the small-block size classes).
- You are effectively running **two parallel defrag optimizations**: compacting key-string arenas AND compacting value-object arenas.

### The 18-Byte Inline Rule

Dragonfly stores strings ≤ 18 bytes **inline** inside the `CompactObj` union. These:
- Do NOT have an external heap allocation.
- Do NOT live on a defragmentable mimalloc page.
- Live directly inside the DashTable's segment array.

**Implementation consequence:** Your code MUST check if the key is external before attempting to defrag it. Running `mi_page_of()` on an inline key pointer will return the DashTable segment page — which you **cannot** defrag via simple reallocation.

### Synergy with the New Algorithm

In the OLD algorithm, defragging keys helps incrementally. In the NEW algorithm, defragging keys is **transformative** — it converts pages from "has ghost bytes, skip" to "fully movable, high-score target." The two features (census-based targeting + key defrag) are synergistic.

---

## 3. Architecture: The State Machine

### Phase Model

```text
IDLE → CENSUS → [SELECT_TARGETS] → EVACUATE → [VERIFY] → IDLE
```
*(Brackets indicate phases that can be collapsed/run synchronously for the hackathon).*

### DefragTaskState Struct

```cpp
struct DefragTaskState {
    enum Phase { IDLE, CENSUS, EVACUATE } phase = IDLE;
    size_t dbid = 0;
    uint64_t cursor = 0;
    time_t last_check_time = 0;

    // Census output
    std::unordered_map<void*, PageAgg> census_map;

    // Target selection output (fast lookup for EVACUATE)
    std::unordered_set<void*> target_pages;

    // Stats
    CycleStats cycle_stats;
};
```

### IDLE Phase Invariants

When phase is IDLE:
- cursor and dbid in reset position.
- census_map and target_pages empty.
- cycle_stats zeroed.
*(If phase is IDLE but state is populated → `DCHECK` failure).*

### Transitions

| From | To | Condition |
|------|----|-----------|
| IDLE | CENSUS | Harness detects defrag needed (RSS threshold, waste ratio, interval). |
| CENSUS | EVACUATE | Census complete (cursor wraps) OR max_census_pages hit → run SELECT synchronously → transition. |
| CENSUS | IDLE | Census complete but 0 viable target pages found. |
| EVACUATE | IDLE | Full DB traversal complete, or all target pages fully evacuated (early termination). |
| Any | IDLE | Shutdown/abort → single cleanup function. |

---

## 4. Detailed Phase Design

### 4.1 CENSUS Phase

**Purpose:** Build a page-level picture of the DB without side effects.

**Mechanism:**
1. Iterate DashTable using existing cursor semantics.
2. For each entry, visit the **value** (all sub-allocations) AND the **key** (if external, > 18 bytes).
3. For each allocation pointer, call `zmalloc_page_is_underutilized()` to get `mi_page_usage_stats_t` (page address, block size, capacity, used blocks, flags).
4. Update `census_map[page_addr]` with a `PageAgg` entry.
5. Stop when quota is depleted (resume next invocation), **OR** full scan completes (cursor wraps to 0), **OR** `max_census_pages` limit is reached mid-scan. *(Log which condition triggered completion)*.

**Visiting complex types:**
The same tree-like visitor that `DefragIfNeeded` uses must be replicated in "census mode".
- **Recommendation:** Add a `DefragMode` enum (`kNormal`, `kCensus`) to the visitor signatures, or create a dedicated `CensusVisitor` to avoid conditional branches in hot paths.

**Memory cap behavior:**
- Global `max_census_pages` (default 2048–4096).
- When hit: **stop CENSUS immediately**, run SELECT, transition to EVACUATE.

**Early page filtering during CENSUS:**
- `flags & MI_DFLY_PAGE_FULL` → skip (page is full, nothing to gain).
- `flags & MI_DFLY_HEAP_MISMATCH` → skip (page belongs to different heap).
- `usage > threshold` → skip (page already well-utilized).

### 4.2 SELECT_TARGETS Phase

Keep this as a **logical function** called synchronously at the end of CENSUS, not a separate harness phase.

**Algorithm:**
1. Dump `census_map` values into `vector<PageAgg>`.
2. Apply strict filters (see §7).
3. Compute scores for survivors (`cap_blocks / used_blocks`).
4. `std::partial_sort` to find top-K (e.g., K=256).
5. Insert their `page_addr` into `target_pages` unordered_set.
6. Clear `census_map` (save RAM).
7. Set phase = EVACUATE, reset cursor to 0 for a full DB pass.

### 4.3 EVACUATE Phase

**Purpose:** Re-traverse the DB and reallocate objects that reside on target pages.

**Mechanism:**
1. Iterate DashTable using cursor (resumable across quota slices).
2. For each entry's key (if external) and value:
   - Get page address via `mi_page_of(ptr)`.
   - Check `target_pages.contains(page_addr)` — O(1) hash lookup.
   - If hit: **re-validate** (check flags, check usage still below threshold).
   - If still valid: call existing `DefragIfNeeded()` logic.
   - Update per-page stats.
3. Stop when quota depleted OR traversal complete.

**Re-validation details:**
Before moving an object, re-check that page flags are not head/full/mismatch, and usage is still below threshold. If re-validation fails, mark page as "stale" in the target set.

**Early termination optimization:**
Maintain a running counter of `pages_fully_evacuated`. If it equals `target_pages.size()`, abort EVACUATE immediately to save CPU.

### 4.4 VERIFY Phase (Stretch Goal)

**For hackathon:** Skip. Log stats at end of EVACUATE and go to IDLE.

---

## 5. Critical Risks & Disagreements

### 5.1 The O(2N) Double-Walk Problem & Batch Scoping

**The problem:** CENSUS walks objects to build the page map. EVACUATE walks objects to find those on target pages.

There was debate over doing "opportunistic reallocation" during CENSUS or limiting EVACUATE to a small "batch scope" (e.g., only scanning keys 0 to 100k).

**Final Resolution:** 1. **Batch-scoped EVACUATE is conceptually broken.** Objects on target pages can come from *anywhere* in the keyspace. A batch-scoped EVACUATE will miss objects outside the batch that reside on the target pages, rendering them unfreeable.
2. **Opportunistic reallocation during CENSUS is rejected for the hackathon.** Mixing read/write operations during CENSUS creates staleness (new allocations land on pages in the map), violating the single-responsibility principle and making debugging/metrics inaccurate.

**Recommendation:**
- CENSUS is strictly read-only.
- Bound CENSUS by `max_census_pages` (stop early if map fills).
- **EVACUATE must be a Full-DB pass** (cursor reset to 0) to guarantee all objects on targeted pages are moved.

### 5.2 Filter Strictness: `movable < used → skip`

**Resolution:** For the hackathon, skip a page only if `movable_blocks == 0`. Allow partial pages. The filter `movable < used` is too strict before keys are fully movable because almost every page contains some "ghost bytes" (tracking structs, etc.).

### 5.3 Scoring Formula

**Resolution:** Use `cap_blocks / used_blocks` for the hackathon. It directly represents "biggest bang for buck" (free blocks gained per object moved). Complex formulas (like multiplying movable bytes by occupancy) conflate "total absolute gain" with "effort required," resulting in degenerate scoring for highly valuable, nearly-empty pages.

---

## 6. Data Structures

### PageAgg (Census Output)

```cpp
struct PageAgg {
    void* page_addr;          // mimalloc page address
    uint32_t block_size;      // bytes per block in this page
    uint32_t cap_blocks;      // total capacity (blocks)
    uint32_t used_blocks;     // live blocks (allocator view)
    uint32_t movable_blocks;  // DB objects we observed on this page
    uint8_t flags;            // mimalloc page flags

    // Derived
    uint32_t movable_bytes() const { return movable_blocks * block_size; }
    uint32_t ghost_bytes() const { return (used_blocks - movable_blocks) * block_size; }
    float score() const { return static_cast<float>(cap_blocks) / used_blocks; }
};
```

### TargetPage (Evacuate Input + Output)

```cpp
struct TargetPage {
    // Copied from CENSUS (read-only context)
    void* page_addr;
    uint32_t block_size;
    uint32_t planned_movable_blocks;
    uint32_t cap_blocks;
    float score;

    // Updated by EVACUATE (metrics)
    uint32_t moved_blocks = 0;
    uint32_t bytes_copied = 0;
    uint32_t stale_skips = 0;
    bool deactivated = false;
};
```

---

## 7. Scoring & Filters (Final Specification)

### Filters Applied During CENSUS (Cheap, Fast)

| Filter | Action | Reason |
|--------|--------|--------|
| `flags & MI_DFLY_PAGE_FULL` | Skip, don't insert | Page is full, nothing to gain |
| `flags & MI_DFLY_HEAP_MISMATCH` | Skip, don't insert | Wrong heap, can't defrag |
| `usage_ratio > threshold` (e.g., 0.8) | Skip, don't insert | Page already well-utilized |
| Inline key (≤ 18 bytes) | Don't observe as movable | No external allocation to defrag |

### Filters Applied During SELECT_TARGETS (Strict)

| Filter | Action | Reason |
|--------|--------|--------|
| `movable_blocks == 0` | Remove from candidates | Nothing we can move |
| `used_blocks == 0` | Remove from candidates | Page is already empty |
| `movable_blocks > used_blocks` | Remove (sanity check) | Census data is corrupted/stale |
| `flags indicate head page` | Remove | Cannot evacuate |

---

## 8. Hackathon Implementation Plan

### Day 1: Scaffolding & Flag
- Add `ABSL_FLAG(bool, experimental_defrag, false, "Use new census-based defragmentation")`.
- Define `PageAgg`, `TargetPage`, `CycleStats` structs.
- Extend `DefragTaskState` with phase enum, `census_map`, `target_pages`, `cycle_stats`.
- Branch in `DefragTask()`: if flag on, call new path; else call old path.
- Stub out `RunCensus()`, `SelectTargets()`, `RunEvacuate()` functions.

### Day 2: Census + Key Observation
- Implement `RunCensus()`:
  - Traverse DashTable with cursor.
  - Call existing visitor in "census mode" (via `DefragMode` enum or a new `CensusVisitor`).
  - For external keys (> 18 bytes) and values, call `zmalloc_page_is_underutilized()`.
  - Populate `census_map` with `PageAgg` entries.
  - Stop when quota depleted, cursor wraps to 0, or `max_census_pages` is reached.
- Implement `SelectTargets()`:
  - Dump map to vector, apply filters, `std::partial_sort` by score, take top-K.
  - Build `target_pages` set and clear `census_map`.

### Day 3: Evacuate + Key Defrag
- Implement `RunEvacuate()`:
  - Traverse DashTable with cursor (reset to 0 from CENSUS).
  - For external keys and values: get page addr, check `target_pages`, re-validate, `DefragIfNeeded()`.
  - Update `TargetPage` stats. Early termination if all targets cleared.
- Add key defrag support:
  - Verify `CompactObj::DefragIfNeeded()` works for keys.
  - Ensure hash lookup invariants are preserved (string content is identical, so bucket placement is safe).

### Day 4: Testing & Metrics
- Write fragmentation generation script (populate → delete every 2nd key).
- Run comparison: old algo vs new algo, same workload.
- Metric of success: **RSS reduction per CPU-microsecond spent**.

---

## 9. Post-Hackathon Production Roadmap

### Stage 1: Hardening
- Proper VERIFY phase with per-page outcome classification.
- Expose defrag metrics via `INFO DEFRAG` command.
- Handle edge cases: DB resize during census, key expiration during evacuate.

### Stage 2: Better Scoring & Eviction-Awareness
- **Advanced Scoring:** Incorporate movable fraction and block size weighting to avoid pages with heavy ghost bytes.
- **Eviction/maxmemory coordination:** Ensure defrag doesn't waste cycles planning or moving keys that are about to be evicted.
- *(Note: A previous idea to "query mimalloc directly for fragmented pages" is fundamentally flawed. Mimalloc knows page occupancy but does not know which blocks are DB objects vs internal structures. It cannot solve the ghost-byte problem and should be abandoned).*

### Stage 3: Advanced Optimizations
- Incremental top-k PQ with generations (for very large page sets).
- Evacuation short-circuiting (running counters).
- Prometheus/Grafana metrics export.

---

## 10. Testing Strategy

### Fragmentation Generation Script
- `FLUSHALL`
- `DEBUG POPULATE N` with S-byte string values (align sizes to mimalloc classes: 64, 128, 256, 512).
- Delete every Mth key.
- Sleep 5s (let lazy mimalloc/OS memory settle).
- Record: `INFO MEMORY`, `INFO STATS`, `DEBUG MEMORY ARENA`.

### Defrag Driver Script
- Loop: Snapshot → Trigger defrag → Sleep 3s → Snapshot again.
- Record deltas in a CSV to plot RSS reduction over time.

---

## 11. Corrections & Inaccuracies Addressed

### Claude / Gemini Corrections
1. **Keys and values share pages?** *Wrong.* mimalloc segregates by size class. Keys and values are on different pages. Keys pin their own pages.
2. **Externally-allocated key threshold:** The inline threshold is **18 bytes**, not 14.
3. **Redis SDS Strings?** *Wrong.* Dragonfly uses `CompactObj` with inline storage for ≤18 bytes and `SmallString`/`RobjWrapper` for larger. There is no `sds`.
4. **robj usage:** Dragonfly's `RobjWrapper` adapts `robj` semantics, but the underlying storage is still `CompactObj`. When defragging, we move the wrapped object, not the wrapper.

### Perplexity Corrections
1. **64KB pages?** *Misleading.* mimalloc "pages" are sized per block-size class, not uniformly 64KB.
2. **Scoring formula `movable_bytes × (1 - occ) × mov_frac`:** *Rejected.* Has degenerate cases where highly valuable, nearly-empty pages score lower than partially filled pages. `cap/used` correctly identifies ROI.
3. **Missing APIs?** *Already exists.* `zmalloc_page_is_underutilized()` returns all required `mi_page_usage_stats_t` data.

---

## 12. Critical Implementation Warnings

1. **Never call `mi_page_of()` on inline key pointers.** Check `CompactObj::IsInline()` (or equivalent) first.
2. **DashTable segment memory is NOT defragmentable.** Segments are large allocations holding many keys inline. You cannot reallocate a segment without invalidating entries. Only *external* key string payloads can be defragged.
3. **Iterator stability across fiber yields.** Client writes can modify the table between quota yields. The DashTable cursor guarantees progress without missing entries, though it may revisit some. This is acceptable.
4. **Key reallocation and hash invariants.** When defragging a key's external string payload, the *content* doesn't change, only its memory address. The hash remains identical, so the hash table bucket placement remains perfectly valid.
5. **Fiber-level exclusivity.** Defrag runs with exclusive access to the shard. No other fiber on the thread accesses the shard during the active quota slice.
