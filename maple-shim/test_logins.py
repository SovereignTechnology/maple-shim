#!/usr/bin/env python3
"""Offline unit tests for the account-login config (MAPLE_LOGIN_<TIER>_*) and
for the redaction of relayed error bodies. No network, no credentials.

Run: python3 test_logins.py
"""

import importlib.util
import os
import shutil
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))

# The module loads its keys at import time and exits if it cannot find them.
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

ID = "3f2a9c1e-1b4d-4e6f-8a7b-0c1d2e3f4a5b"


class LoadLogins(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        os.environ["CREDENTIALS_DIRECTORY"] = self.dir
        shim.TIER_ORDER = ("max", "pro")
        self.logged = []
        self._log = shim._log
        shim._log = self.logged.append

    def tearDown(self):
        shim._log = self._log
        os.environ.pop("CREDENTIALS_DIRECTORY", None)
        shutil.rmtree(self.dir, ignore_errors=True)

    def load(self, text):
        with open(os.path.join(self.dir, "maple-keys"), "w", encoding="utf-8") as fh:
            fh.write("MAPLE_KEY_MAX=k\nMAPLE_KEY_PRO=k\n" + text)
        return shim._load_logins()

    def test_email_and_id_logins(self):
        logins = self.load(
            "MAPLE_LOGIN_MAX_EMAIL=a@b.test\nMAPLE_LOGIN_MAX_PASSWORD=pw1\n"
            f"MAPLE_LOGIN_PRO_ID={ID}\nMAPLE_LOGIN_PRO_PASSWORD=pw2\n"
        )
        self.assertEqual(logins["max"], {"password": "pw1", "email": "a@b.test"})
        self.assertEqual(logins["pro"], {"password": "pw2", "id": ID})
        self.assertIn("loaded logins for tiers: max,pro", self.logged)

    def test_none_configured_is_not_an_error(self):
        self.assertEqual(self.load(""), {})
        self.assertIn("loaded logins for tiers: none", self.logged)

    def test_quotes_and_comments(self):
        logins = self.load(
            "# a comment\nMAPLE_LOGIN_MAX_EMAIL=\"a@b.test\"\nMAPLE_LOGIN_MAX_PASSWORD='p w'\n"
        )
        self.assertEqual(logins, {"max": {"password": "p w", "email": "a@b.test"}})

    def test_incomplete_tiers_are_skipped_never_half_used(self):
        cases = [
            "MAPLE_LOGIN_MAX_EMAIL=a@b.test\n",  # no password
            "MAPLE_LOGIN_MAX_PASSWORD=pw\n",  # no identifier
            f"MAPLE_LOGIN_MAX_EMAIL=a@b.test\nMAPLE_LOGIN_MAX_ID={ID}\nMAPLE_LOGIN_MAX_PASSWORD=pw\n",
        ]
        for text in cases:
            with self.subTest(text=text):
                self.logged.clear()
                self.assertEqual(self.load(text), {})
                self.assertTrue(any("login for tier max ignored" in m for m in self.logged))
                self.assertFalse(any("pw" in m for m in self.logged), "the password was logged")

    def test_unreadable_file_means_no_logins(self):
        os.environ["CREDENTIALS_DIRECTORY"] = os.path.join(self.dir, "missing")
        self.assertEqual(shim._load_logins(), {})


class RedactBody(unittest.TestCase):
    def setUp(self):
        shim.KEYS = {"max": "KEYMAX", "pro": "KEYPRO"}
        shim.LOGINS = {"max": {"password": "PWMAX", "email": "a@b.test"}}

    def tearDown(self):
        shim.LOGINS = {}

    def test_keys_and_passwords_are_replaced(self):
        body = b'{"error":"bad KEYMAX / KEYPRO / PWMAX"}'
        self.assertEqual(
            shim._redact_body(body), b'{"error":"bad <redacted> / <redacted> / <redacted>"}'
        )

    def test_other_bytes_are_untouched(self):
        body = b"\xff\xfe not utf-8 \x00 KEYMAX"
        self.assertEqual(shim._redact_body(body), b"\xff\xfe not utf-8 \x00 <redacted>")
        self.assertEqual(shim._redact_body(b'{"ok":1}'), b'{"ok":1}')

    def test_log_redaction_covers_passwords(self):
        self.assertEqual(shim._redact("x PWMAX y"), "x <redacted> y")


if __name__ == "__main__":
    unittest.main()
