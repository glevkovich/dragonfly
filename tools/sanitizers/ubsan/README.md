# UBSan tooling

Helpers for running Dragonfly under Clang's UndefinedBehaviorSanitizer (UBSan).
See [docs/build-from-source.md](../../../docs/build-from-source.md) ("Running
UBSan locally") for how to configure a sanitized build and the full list of
`UBSAN_OPTIONS`.

## Files

| File | Purpose |
|---|---|
| `ubsan_selftest.cc` | `RunUbsanSelfTest()` — deliberately triggers one example of every enabled UBSan check. Not compiled into dragonfly by default. |
| `inject_ubsan_selftest.patch` | Wires a hidden `--run_ubsan_selftest` flag into `dfly_main.cc` and adds `ubsan_selftest.cc` to the dragonfly target. Applied, run, then reverted. |
| `ubsan-ignorelist.txt` | Compile-time `-fsanitize-ignorelist`: excludes third-party / vendored code so findings point at first-party code. |
| `ubsan-suppressions.txt` | Runtime `UBSAN_OPTIONS=suppressions=`: silences specific false positives. |

## Verifying UBSan is live

Build dragonfly with UBSan, then prove every enabled check actually fires:

```bash
# 1. configure a sanitized clang build (extended checks default ON)
./helio/blaze.sh -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DWITH_UBSAN=ON -DWITH_AWS=OFF -DWITH_GCP=OFF

# 2. inject the self-test hook and build
git apply --whitespace=nowarn tools/sanitizers/ubsan/inject_ubsan_selftest.patch
cd build-dbg && ninja dragonfly && cd ..

# 3. run it — prints one finding per enabled check (recoverable mode)
UBSAN_OPTIONS="print_stacktrace=1:report_error_type=1" \
  ./build-dbg/dragonfly --run_ubsan_selftest

# 4. revert the hook
git apply -R --whitespace=nowarn tools/sanitizers/ubsan/inject_ubsan_selftest.patch
```

`RunUbsanSelfTest(0)` runs all cases; pass a case number (1..12) to run just one.

## Checks covered

| # | Check | Tier | Notes |
|---|---|---|---|
| 1 | implicit-unsigned-integer-truncation | strict | the PR #7562 pattern |
| 2 | implicit-signed-integer-truncation | strict | |
| 3 | implicit-integer-sign-change | strict | |
| 4 | local-bounds | strict | |
| 5 | nullability | strict | |
| 6 | float-divide-by-zero | strict | |
| 7 | signed-integer-overflow | `-fsanitize=undefined` | true UB |
| 8 | unsigned-integer-overflow | strict (`integer`) | |
| 9 | unsigned-shift-base | strict (`integer`) | |
| 10 | function | strict | needs RTTI |
| 11 | vptr | strict | needs RTTI |
| 12 | object-size | strict | only at `-O1+` |

The extended (strict) checks come from `WITH_UBSAN_STRICT` and are Clang-only —
GCC implements none of them.

## Running UBSan locally

The UBSan CI job (`.github/workflows/ubsan.yml`) does this automatically.
To reproduce on your machine:

```bash
# 1. configure a UBSan (strict, -O1) clang build. -O1 is required for object-size.
./helio/blaze.sh -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
  -DWITH_UBSAN=ON -DWITH_AWS=OFF -DWITH_GCP=OFF -DCMAKE_CXX_FLAGS="-O1"
cd build-dbg && ninja dragonfly && cd ..

# 2. run a functional test under UBSan, logging every finding to a file.
#    halt_on_error=0 keeps the server alive so one run captures everything.
ROOT="$(pwd)"
mkdir -p build-dbg/ubsan-logs
cd tests
DRAGONFLY_PATH="$ROOT/build-dbg/dragonfly" \
UBSAN_OPTIONS="halt_on_error=0:print_stacktrace=1:report_error_type=1:dedup_token_length=3:strip_path_prefix=$ROOT/:suppressions=$ROOT/tools/sanitizers/ubsan/ubsan-suppressions.txt:log_path=$ROOT/build-dbg/ubsan-logs/pytest" \
  python3 -m pytest -m "not large" dragonfly/connection_test.py
cd "$ROOT"
```

UBSan writes `build-dbg/ubsan-logs/pytest.<pid>` files (one per dragonfly process).

## Summarizing findings (`ubsan_summarize_findings.sh`)

`ubsan_summarize_findings.sh <logs-dir> <arch>` turns those `pytest.*` logs into a
markdown report (the same one CI posts to the job summary): a total count, then
two sections — **undefined behavior** (real C++ standard violations) and
**suspicious / defined-but-flagged** (the noisy integer / implicit-conversion
checks) — each grouped by check type, with locations deduplicated by file:line.

```bash
# render the report from a local run
bash tools/sanitizers/ubsan/ubsan_summarize_findings.sh build-dbg/ubsan-logs local | less

# or point it at logs downloaded from a CI run's ubsan-logs-<arch> artifact
bash tools/sanitizers/ubsan/ubsan_summarize_findings.sh ./ubsan-logs-x86_64 x86_64 > findings.md
```

The summary lists headline + file:line only; for the **full symbolized stacks**
read the `pytest.*` log files directly (or the uploaded `ubsan-logs-<arch>`
artifact on CI).
