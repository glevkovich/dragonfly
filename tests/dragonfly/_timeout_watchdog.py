"""Async-aware per-test timeout watchdog for the Dragonfly test suite.

Why this exists
---------------
The regression suites run ``pytest --timeout=300``. pytest-timeout's default
``signal`` method raises ``pytest.fail`` inside the running test, but for async
tests the asyncio event loop catches that ``BaseException`` inside
``Handle._run`` and only logs it, so a hung async test is **never** aborted and
the run hangs until the outer ``timeout 80m`` job wrapper kills the whole suite.
pytest-timeout's ``thread`` method *does* abort, but via ``os._exit`` -- which
skips fixture teardown (leaking/orphaning Dragonfly processes) and JUnit output.

This plugin replaces the mechanism (via pytest-timeout's public
``pytest_timeout_set_timer`` / ``pytest_timeout_cancel_timer`` hooks) with an
**async-aware, staged escalation** that aborts a hung test *cleanly* whenever
possible, so fixture teardown runs (Dragonfly is stopped), the test is recorded
as a normal failure (JUnit is written) and the run continues:

  * stage 1 (t = timeout):            async test -> cancel its asyncio task(s);
                                      sync test  -> raise via SIGALRM.
  * stage 2 (t = timeout + grace1):   SIGALRM the main thread. Covers a
                                      non-yielding ``while True`` coroutine that
                                      ``task.cancel`` can't reach (the alarm is
                                      raised during ``coro.send`` and captured by
                                      ``Task.__step``).
  * stage 3 (t = timeout + grace1 + grace2):  os._exit(1) as an absolute last
                                      resort (dumps all thread stacks first),
                                      for a test that swallows the abort.

``timeout_func_only = true`` (set in pytest.ini) makes pytest-timeout wrap only
the test function, so ``pytest_timeout_cancel_timer`` runs right after the
function and **before** teardown. A clean abort therefore lets teardown run
undisturbed, and the escalation timers can never clobber a slow-but-legitimate
teardown.

Known limitation: a pure-C, GIL-holding loop (e.g. ``sum(range(10**10))``) never
reaches a bytecode boundary, so no in-process mechanism -- signal *or* thread,
this plugin or pytest-timeout's own -- can interrupt it. That pathological case
is left to the external ``timeout 80m`` job wrapper.
"""

import asyncio
import os
import signal
import sys
import threading
import traceback

import pytest

# Seconds to wait between escalation stages. Only relevant for a test that does
# NOT abort at the previous stage (rare); a normally-cancellable hang dies at
# stage 1 and these never elapse. Overridable for tests via env vars.
_GRACE_1_S = float(os.environ.get("DFLY_TIMEOUT_GRACE1_S", "15"))
_GRACE_2_S = float(os.environ.get("DFLY_TIMEOUT_GRACE2_S", "15"))


def _cancel_all_tasks(loop, nodeid, timeout):
    """Cancel every not-done task on ``loop``. Runs *in* the loop thread."""
    msg = "pytest-timeout: %s exceeded %ss" % (nodeid, timeout)
    for task in asyncio.all_tasks(loop):
        if not task.done():
            try:
                task.cancel(msg)
            except TypeError:  # Python < 3.9 has no cancel message
                task.cancel()


def _sigalrm_handler(signum, frame):
    __tracebackhide__ = True
    pytest.fail("pytest-timeout: test exceeded its timeout")


def _emit_hardkill_dump(item, nodeid, timeout):
    """Dump all thread stacks to the real output before an os._exit.

    os._exit skips report generation, so we suspend pytest's (fd-level) global
    capture and write via the terminal writer -- otherwise the dump is lost.
    Mirrors pytest-timeout's own ``thread`` method.
    """
    try:
        config = item.config
        tw = config.get_terminal_writer()
        capman = config.pluginmanager.getplugin("capturemanager")
        if capman:
            capman.suspend_global_capture(in_=True)
            out, err = capman.read_global_capture()
            if out:
                tw.sep("~", "Captured stdout for %s" % nodeid)
                tw.write(out)
            if err:
                tw.sep("~", "Captured stderr for %s" % nodeid)
                tw.write(err)
        tw.sep(
            "+",
            "Timeout >%ss: %s could NOT be aborted -- HARD KILL os._exit(1)" % (timeout, nodeid),
        )
        for tid, frame in sys._current_frames().items():
            tw.sep("~", "Stack of thread %s" % tid)
            tw.write("".join(traceback.format_stack(frame)))
        tw.sep("+", "Timeout")
        tw.flush()
    except Exception:  # pragma: no cover - best effort under a wedged interpreter
        try:
            os.write(2, ("\n+++ pytest-timeout HARD KILL (dump failed) %s +++\n" % nodeid).encode())
        except Exception:
            pass


class _TimeoutState:
    """Per-test escalation state; armed by set_timer, torn down by cancel_timer."""

    def __init__(self, item, settings, sigalrm_ok):
        self.item = item
        self.nodeid = item.nodeid
        self.timeout = settings.timeout
        self.main_tid = threading.main_thread().ident
        self.sigalrm_ok = sigalrm_ok
        self._timers = []
        self._cancelled = False
        self._lock = threading.Lock()

    def start(self):
        self._arm(self.timeout, self._stage1)

    def _arm(self, delay, fn):
        with self._lock:
            if self._cancelled:
                return
            t = threading.Timer(delay, fn)
            t.daemon = True
            t.name = "dfly-timeout %s" % self.nodeid
            self._timers.append(t)
            t.start()

    def cancel(self):
        with self._lock:
            self._cancelled = True
            timers, self._timers = self._timers, []
        for t in timers:
            t.cancel()

    def _get_loop(self):
        funcargs = getattr(self.item, "funcargs", None) or {}
        loop = funcargs.get("event_loop")
        if loop is not None and not loop.is_closed():
            return loop
        return None

    def _send_sigalrm(self):
        if not self.sigalrm_ok:
            return
        try:
            signal.pthread_kill(self.main_tid, signal.SIGALRM)
        except Exception:  # pragma: no cover
            pass

    def _stage1(self):
        # Do the CHEAP abort first. A stack dump here runs in this timer thread
        # and would be GIL-starved by a CPU-spinning test, delaying the abort.
        sys.stderr.write(
            "\n+++ pytest-timeout: %s exceeded %ss -- aborting +++\n" % (self.nodeid, self.timeout)
        )
        sys.stderr.flush()
        loop = self._get_loop()
        if loop is not None:
            loop.call_soon_threadsafe(_cancel_all_tasks, loop, self.nodeid, self.timeout)
        else:
            self._send_sigalrm()
        self._arm(_GRACE_1_S, self._stage2)

    def _stage2(self):
        sys.stderr.write(
            "\n+++ pytest-timeout: %s still running -- escalating (SIGALRM) +++\n" % self.nodeid
        )
        sys.stderr.flush()
        self._send_sigalrm()
        self._arm(_GRACE_2_S, self._stage3)

    def _stage3(self):
        _emit_hardkill_dump(self.item, self.nodeid, self.timeout)
        os._exit(1)


@pytest.hookimpl
def pytest_timeout_set_timer(item, settings):
    """pytest-timeout hook: arm our async-aware timeout instead of signal/thread."""
    sigalrm_ok = False
    try:
        item._dfly_prev_sigalrm = signal.getsignal(signal.SIGALRM)
        signal.signal(signal.SIGALRM, _sigalrm_handler)
        sigalrm_ok = True
    except (ValueError, AttributeError):
        # Not the main thread (e.g. xdist): SIGALRM unavailable; cancel + os._exit still work.
        item._dfly_prev_sigalrm = None
    state = _TimeoutState(item, settings, sigalrm_ok)
    item._dfly_timeout_state = state
    state.start()
    return True


@pytest.hookimpl
def pytest_timeout_cancel_timer(item):
    """pytest-timeout hook: disarm the timeout (runs before teardown w/ func_only)."""
    state = getattr(item, "_dfly_timeout_state", None)
    if state is not None:
        state.cancel()
        item._dfly_timeout_state = None
    prev = getattr(item, "_dfly_prev_sigalrm", None)
    if prev is not None:
        try:
            signal.signal(signal.SIGALRM, prev)
        except (ValueError, AttributeError):
            pass
        item._dfly_prev_sigalrm = None
    return True
