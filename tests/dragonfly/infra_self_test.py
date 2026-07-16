"""Self-test for the async-aware per-test timeout watchdog (dataplane-private#255).

These tests do **not** exercise Dragonfly. They are a regression guard for the
*test infrastructure* itself: they verify that a hung/deadlocked test is aborted
at its own per-test ``--timeout`` **cleanly** -- i.e. it is recorded as a normal
failure (so JUnit is written), fixture teardown still runs (so Dragonfly would be
stopped), and the run continues to the next test -- instead of hanging until the
outer ``timeout 80m`` job wrapper kills the whole suite.

The behavioural check drives a *child* ``pytest`` that loads the real watchdog
module (``tests/dragonfly/_timeout_watchdog.py``) and runs a deliberately-hung
async test and a deliberately-hung sync test, each followed by a passing test.
It then asserts the hung tests are reported as failures in JUnit, the teardown
of every test ran, and the passing test still executed.
"""

import configparser
import os
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

import pytest

# Directory holding the real watchdog module + this file.
_DRAGONFLY_DIR = os.path.dirname(os.path.abspath(__file__))

# Short per-test timeout for the self-test (production uses 300 s).
PER_TEST_TIMEOUT_S = 5
# Hard backstop: if the watchdog fails to abort the hung child tests, stop
# waiting after this many seconds and fail loudly.
BACKSTOP_S = 60

# A child conftest that registers the REAL watchdog hooks and a teardown marker
# fixture (stands in for the Dragonfly-stopping teardown that must still run).
_CHILD_CONFTEST = """
import os
import sys

import pytest

sys.path.insert(0, {dragonfly_dir!r})
from _timeout_watchdog import (  # noqa: F401
    pytest_timeout_set_timer,
    pytest_timeout_cancel_timer,
)

_MARK_DIR = os.environ["SELFTEST_MARK_DIR"]


@pytest.fixture
def fake_server(request):
    # Teardown here MUST run even when the test is aborted by the timeout,
    # otherwise a real Dragonfly instance would be leaked.
    yield
    with open(os.path.join(_MARK_DIR, request.node.name), "w") as f:
        f.write("torn-down\\n")
"""

_CHILD_TESTS = """
import asyncio
import time

import pytest


@pytest.mark.asyncio
async def test_async_hang(fake_server):
    await asyncio.Event().wait()  # realistic async deadlock (loop idle)


def test_sync_hang(fake_server):
    time.sleep(3600)  # sync deadlock (no event loop)


def test_runs_after(fake_server):
    assert True  # proves the run CONTINUES after the hung tests are aborted
"""


def _find_pytest_ini():
    directory = _DRAGONFLY_DIR
    for _ in range(6):
        candidate = os.path.join(directory, "pytest.ini")
        if os.path.isfile(candidate):
            return candidate
        parent = os.path.dirname(directory)
        if parent == directory:
            break
        directory = parent
    return None


def test_hung_tests_are_aborted_cleanly_with_junit_and_teardown(tmp_path):
    """A hung async/sync test is aborted cleanly: failure recorded in JUnit,
    fixture teardown runs, and the run continues -- no os._exit, no whole-suite
    hang."""
    mark_dir = tmp_path / "marks"
    mark_dir.mkdir()
    (tmp_path / "conftest.py").write_text(_CHILD_CONFTEST.format(dragonfly_dir=_DRAGONFLY_DIR))
    (tmp_path / "hang_case_test.py").write_text(_CHILD_TESTS)
    junit = tmp_path / "result.xml"

    env = dict(os.environ)
    env["SELFTEST_MARK_DIR"] = str(mark_dir)
    # Keep escalation fast so the self-test stays quick if a stage is needed.
    env["DFLY_TIMEOUT_GRACE1_S"] = "5"
    env["DFLY_TIMEOUT_GRACE2_S"] = "5"

    cmd = [
        sys.executable,
        "-m",
        "pytest",
        "-p",
        "no:cacheprovider",
        "-o",
        "asyncio_mode=auto",
        "-o",
        "timeout_func_only=true",
        f"--timeout={PER_TEST_TIMEOUT_S}",
        f"--junitxml={junit}",
        "-q",
        ".",
    ]

    start = time.monotonic()
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(tmp_path),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=BACKSTOP_S,
            env=env,
        )
    except subprocess.TimeoutExpired as expired:
        elapsed = time.monotonic() - start
        output = expired.output or ""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        pytest.fail(
            "The timeout watchdog did NOT abort the hung child tests: the child "
            f"pytest was still running after {elapsed:.1f}s (backstop {BACKSTOP_S}s).\n"
            f"--- child output ---\n{output}"
        )
    elapsed = time.monotonic() - start
    output = proc.stdout or ""

    # 1) JUnit was written (this is the whole point -- os._exit would skip it).
    assert junit.exists(), f"JUnit was not written:\n{output}"
    suite = ET.parse(str(junit)).getroot()
    suite = suite if suite.tag == "testsuite" else suite.find("testsuite")
    cases = {tc.get("name"): tc for tc in suite.findall("testcase")}

    # 2) Both hung tests are recorded as failures (attributed to the right test).
    for name in ("test_async_hang", "test_sync_hang"):
        assert name in cases, f"{name} missing from JUnit:\n{output}"
        kinds = [c.tag for c in cases[name]]
        assert "failure" in kinds or "error" in kinds, f"{name} not failed (got {kinds})\n{output}"

    # 3) The run CONTINUED: the test after the hung ones executed and passed.
    assert "test_runs_after" in cases, f"run did not continue past the hung tests:\n{output}"
    assert [
        c.tag for c in cases["test_runs_after"]
    ] == [], f"test_runs_after did not pass\n{output}"

    # 4) Fixture teardown ran for EVERY test, including the aborted ones.
    torn_down = set(os.listdir(str(mark_dir)))
    for name in ("test_async_hang", "test_sync_hang", "test_runs_after"):
        assert name in torn_down, f"teardown did not run for {name} (leak!):\n{output}"

    # 5) It aborted near the per-test timeout, not the backstop.
    assert elapsed < BACKSTOP_S, f"took too long: {elapsed:.1f}s"


def test_pytest_ini_enforces_func_only_timeout():
    """Guard: the suite must apply the timeout to the test function only, so the
    watchdog can abort a hung test and still let teardown (stopping Dragonfly)
    run. See dataplane-private#255."""
    ini_path = _find_pytest_ini()
    if ini_path is None:
        pytest.skip("pytest.ini not found next to this test")
    parser = configparser.RawConfigParser()
    parser.read(ini_path)
    func_only = parser.get("pytest", "timeout_func_only", fallback=None)
    assert func_only == "true", (
        f"{ini_path} must set 'timeout_func_only = true' (got {func_only!r}); the "
        "async-aware timeout watchdog relies on it so teardown runs after an abort."
    )
    # The old os._exit-based 'thread' method must NOT be configured -- it skips
    # teardown (leaking Dragonfly) and JUnit.
    method = parser.get("pytest", "timeout_method", fallback=None)
    assert method != "thread", (
        "tests/pytest.ini sets 'timeout_method = thread', which uses os._exit and "
        "skips teardown/JUnit. Remove it; the watchdog handles timeouts cleanly."
    )
