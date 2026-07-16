"""TEMPORARY intentional-bug experiment for the async-aware timeout watchdog.

!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
!!  TEMPORARY BUG -- DO NOT MERGE. This file contains a DELIBERATE hang used   !!
!!  only to prove, on CI, that the timeout watchdog aborts a hung test against !!
!!  a REAL Dragonfly cleanly. Remove this whole file AND the `real-dragonfly`  !!
!!  job in .github/workflows/timeout-watchdog-experiment.yml before merging.   !!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

TODO(dataplane-private#255): DELETE this temporary experiment file.

What it proves in CI (see the workflow's `real-dragonfly` job):
  * the hung test is aborted at its per-test timeout and recorded as a FAILURE
    in JUnit (not killed via os._exit),
  * fixture teardown still runs so the Dragonfly instance is stopped (no orphan),
  * the run continues -- the next class starts a fresh, working Dragonfly.
"""

import pytest


class TestTimeoutExperimentHang:
    @pytest.mark.asyncio
    @pytest.mark.timeout(10, func_only=True)
    async def test_intentional_hang(self, async_client):
        # TEMPORARY BUG: intentional deadlock against a real Dragonfly. BLPOP on
        # a missing key with a 0 timeout blocks forever; the watchdog must cancel
        # this task so the test fails cleanly and teardown stops Dragonfly.
        # TODO(dataplane-private#255): remove -- intentional bug for CI experiment.
        await async_client.blpop(["timeout-experiment-missing-key"], 0)


class TestTimeoutExperimentAfter:
    @pytest.mark.asyncio
    async def test_dragonfly_usable_after_hang(self, async_client):
        # Proves the run continued and this class's fresh Dragonfly works, i.e.
        # the previous (hung) class's instance was torn down cleanly.
        await async_client.set("timeout-experiment-key", "ok")
        assert await async_client.get("timeout-experiment-key") == "ok"
