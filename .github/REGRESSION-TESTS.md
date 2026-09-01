# Manual Regression Tests

The `Regression Tests` and `Epoll Regression Tests` workflows run automatically on
schedule. Their `workflow_dispatch` inputs also support short, targeted runs when
you need to reproduce or repeat a regression test.

For the workflow UI, open **Actions**, select the workflow, choose **Run workflow**,
and fill in only the inputs needed for the scenario.

## Workflow Input Fields

The following names match the `workflow_dispatch` fields in the YAML exactly.

## Pytest Inputs

- Pytest runs in every scheduled and manually dispatched regression job. With every
  Pytest input at its default, it runs the full `tests/dragonfly` suite once.
- `test-suites`: Comma- or space-separated Python test filenames. A filename without
  a path is resolved under `tests/dragonfly/`. Leave empty to use the full
  `tests/dragonfly` suite.
- `test-cases`: An extended regular expression matched against collected pytest
  node IDs. Leave empty to run all cases in the selected suites. The same regex
  applies to every suite in `test-suites`; it is not a separate filter per file.
- `iterations`: A non-negative integer controlling how many times the selected
  pytest tests run. It defaults to `1` when left empty. Set it to `0` to skip
  Pytest entirely, for a GoogleTest-only manual run. The run count and
  `max-run-time` are both limits: whichever occurs first ends the test family.

Examples:

`test-suites`:

```text
pymemcached_test.py
```

`test-cases`:

```text
test_basic
```

`iterations`:

```text
2
```

For another Python selection:

`test-suites`:

```text
connection_test,eval_test
```

`test-cases`:

```text
test_timeout|test_eval
```

`iterations`:

```text
5
```

To run only two cases from `connection_test` and every case from `eval_test`, put
the following in the `test-cases` field. The suite names in the regex scope each
alternative to its file:

`test-cases`:

```text
(^|/)connection_test\.py::(test_case_one|test_case_two)$|(^|/)eval_test\.py::
```

Set `test-suites` to `connection_test,eval_test` as well. Pytest node IDs use `::`
to separate the file, test class, and test function, for example
`eval_test.py::TestEval::test_basic`. The trailing `::` after `eval_test.py` is
therefore needed to scope that alternative to node IDs from `eval_test`; it is not
an extra test name and does not need to appear at the end of the complete regex.

Pytest receives the resulting collected node IDs as explicit test arguments. A
short regex such as `test_case_one|test_case_two` is global and can select matching
case names from both suites. There is currently no per-suite filter syntax.

## GoogleTest Inputs

GoogleTests run only in a manually dispatched workflow. Every manual dispatch runs
both the full Pytest and GoogleTest suites once by default. Scheduled regression jobs
run Pytest only and never build or run GoogleTests. The GoogleTest fields refine a
manual run; they do not enable it. A failure in one test family does not prevent the
other family from running.

Manual dispatches support GoogleTest-only runs by setting `iterations` to `0`.
Pytest still runs before GoogleTest when it is enabled, and `gtest-iterations` must
be positive. To minimize Pytest work when it is enabled before a targeted GoogleTest
run, select a single fast Pytest case. Scheduled runs are Pytest-only and do not run
GoogleTests.

- `gtest-suites`: Comma- or space-separated target names discovered under
  `src/core`, `src/facade`, and `src/server`. You may also provide a target path or
  `.cc` suffix; only the target name is used. Leave it empty to run every discovered
  target once. Avoid leaving it empty when `gtest-cases` is intended for tests in
  only one or a few binaries: the workflow first builds every discovered target and
  then evaluates the filter against each one. Specify the relevant target names
  instead. Empty `gtest-suites` remains supported; targets with no matching filtered
  tests are skipped.
- `gtest-cases`: A value passed directly to GoogleTest as `--gtest_filter`. Leave it
  empty to run all cases in the selected targets, or all cases in every target when
  `gtest-suites` is also empty.
- `gtest-iterations`: A positive integer controlling how many times the selected
  GoogleTest targets run. It defaults to `1`. The run count and `max-run-time` are
  both limits: whichever occurs first ends the test family.

Example:

`gtest-suites`:

```text
generic_family_test
```

`gtest-cases`:

```text
StringMapTest.*:DashTest.*
```

`gtest-iterations`:

```text
2
```

## Common Inputs

- `max-run-time`: An optional positive integer from `1` through `360`, specifying a
  single time budget in minutes for every matrix job. It starts when the job begins
  and includes checkout, input validation, Dragonfly build, test setup, Pytest, and
  GoogleTest. The helpers also share a deadline started before the build, so time
  used by the build or one test family reduces the time available to the other.
  If the budget is too short, the job may stop during the build or before the first
  test iteration starts. The main build is not forcibly stopped by this shared
  deadline; the GitHub job timeout still applies to it.
  Manual runs default to `360` minutes (6 hours); scheduled runs retain an 80-minute
  shared job budget. A runner cannot exceed GitHub Actions' six-hour job limit. The
  budget stops the active build or test command immediately when it expires; it does
  not wait for the current iteration to finish. If all requested iterations complete
  first, the job continues with the next test family or post-test steps.
- `continue-on-test-failure`: A boolean that defaults to `false`. When `false`, the
  first failing iteration stops its own selected test family. Set it to `true` to
  complete every selected iteration in both Pytest and GoogleTest, then report a
  failure at the end. The two family steps are independent: a failure in one never
  prevents the other from starting. With `true`, each completed Pytest iteration is
  handled before the next begins. Every failed iteration archives all
  `/tmp/dragonfly_logs/` contents as
  `/tmp/regression-failed/iteration_<n>_logs.tar.gz` using gzip. Clean iterations are not archived or retained: their logs are
  deleted. Archive creation finishes before the next iteration starts, and its
  duration is printed in the job log.

  Each failed matrix job uploads a separately named `regression-logs-*` artifact
  containing failed-iteration archives at its root and a
  `pytest-failures-by-iteration.txt` report listing the failed test cases for every
  failed Pytest iteration. The archives are standard gzip tar files and can be
  inspected with local archive tools after downloading the artifact.

`max-run-time`:

```text
30
```

`continue-on-test-failure`:

```text
true
```

## Validation and scheduling

Manual inputs are validated immediately after checkout and before the Dragonfly
build. Invalid counts, suite names, targets, or regular expressions fail early.
The boolean failure setting is also validated by GitHub because it is a typed
workflow input.

Scheduled runs do not provide manual inputs. They skip the manual-input validation
step, run the full Pytest suite once, skip GoogleTests, and use the 80-minute shared
job budget described above. Manual runs execute both test families and use the longer
`max-run-time` budget. The job-level timeout is the hard deadline for the build and
selected test families, so GitHub may cancel a command immediately when the budget
expires before post-test uploads can run.

Both workflows fan out over their configured build matrix. Targeted inputs reduce
test execution time, but each matrix job still builds the configured Dragonfly
variant before running tests.

Before each Python or GoogleTest iteration, the regression action prints a green
iteration banner followed by the exact shell-escaped command it is about to run.
Expand the `Run regression tests action` step in the job log to see these lines.

## Runner Capacity And Iterations

A regression run in the pool uses one runner. A regular regression run fans out
across eight matrix runners and can use a ninth runner for the lint job. Plan the
`iterations` and `gtest-iterations` values accordingly: each iteration runs once
per matrix job, not once for the workflow as a whole. For example, setting
`iterations` to `3` in a regular run means 24 matrix test runs, not three total
runs. The optional
ninth runner performs linting and does not add test iterations.

Manual runs cannot filter the architecture, runner, Debug build, or Release build.
The configured variants always run together: all variants or none. Use suite, case,
and iteration inputs to control the test workload instead.

GoogleTest targets are validated after CMake configures the build. This avoids
rejecting a target merely because its source declaration is conditional on the
selected build configuration.
