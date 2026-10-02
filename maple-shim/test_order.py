#!/usr/bin/env python3
"""Offline unit tests for the tier-selection rule: the healthy tier whose quota
resets soonest is preferred, health still dominates, and TIER_ORDER is only the
tie-break. No network, no credentials, no fleet access.

Run: python3 test_order.py
"""

import datetime as dt
import importlib.util
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))

# The module loads its keys at import time and exits if it cannot find them.
# Point it at a throwaway credential so the import succeeds offline.
_tmp = tempfile.mkdtemp()
with open(os.path.join(_tmp, "maple-keys"), "w", encoding="utf-8") as _fh:
    _fh.write("MAPLE_KEY_MAX=k\nMAPLE_KEY_PRO=k\n")
os.environ["CREDENTIALS_DIRECTORY"] = _tmp

_spec = importlib.util.spec_from_file_location(
    "maple_shim", os.path.join(HERE, "maple-shim.py")
)
shim = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(shim)

shutil.rmtree(_tmp, ignore_errors=True)
os.environ.pop("CREDENTIALS_DIRECTORY", None)


class TierOrder(unittest.TestCase):
    def setUp(self):
        shim.KEYS = {"max": "k", "pro": "k"}
        shim.RESET_DAY = {"max": 1, "pro": 15}
        shim.TIER_ORDER = ("max", "pro")

    def test_nearest_reset_wins_early_month(self):
        # Oct 2: Pro resets Oct 15, Max resets Nov 1 -> Pro is nearer.
        now = dt.datetime(2026, 10, 2, 12, 0)
        self.assertEqual(shim._tier_order({}, now), ["pro", "max"])

    def test_nearest_reset_wins_late_month(self):
        # Oct 20: Max resets Nov 1, Pro resets Nov 15 -> Max is nearer.
        now = dt.datetime(2026, 10, 20, 12, 0)
        self.assertEqual(shim._tier_order({}, now), ["max", "pro"])

    def test_latched_tier_sorts_last_even_when_nearer(self):
        # Pro is the nearer reset but is spent, so Max must win.
        now = dt.datetime(2026, 10, 2, 12, 0)
        state = {"pro": {"exhausted_at": "2026-10-01T00:00:00"}}
        self.assertEqual(shim._tier_order(state, now), ["max", "pro"])

    def test_cooled_tier_sorts_below_healthy(self):
        now = dt.datetime(2026, 10, 2, 12, 0)
        state = {
            "pro": {"cooldown_until": (now + dt.timedelta(minutes=5)).isoformat()}
        }
        self.assertEqual(shim._tier_order(state, now), ["max", "pro"])

    def test_equal_reset_day_tie_breaks_on_tier_order(self):
        now = dt.datetime(2026, 10, 2, 12, 0)
        shim.RESET_DAY = {"max": 15, "pro": 15}
        self.assertEqual(shim._tier_order({}, now), ["max", "pro"])

    def test_unconfigured_tier_is_excluded(self):
        shim.KEYS = {"pro": "k"}
        now = dt.datetime(2026, 10, 2, 12, 0)
        self.assertEqual(shim._tier_order({}, now), ["pro"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
