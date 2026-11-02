"""
Module: test_config.py
Description: Contract tests for the timeout settings. Skipped when the runtime
             dependencies are not installed, so the stdlib test suite still runs.
"""

import os
import unittest

try:
    from src.config import Settings

    HAVE_DEPS = True
except Exception:
    HAVE_DEPS = False


@unittest.skipUnless(HAVE_DEPS, "pydantic-settings not installed")
class ConfigTimeoutTest(unittest.TestCase):
    def test_chat_timeout_default(self) -> None:
        settings = Settings()
        self.assertEqual(settings.chat_timeout, 300.0)
        self.assertEqual(settings.request_timeout, 30.0)

    def test_chat_timeout_override(self) -> None:
        os.environ["RAG_CHAT_TIMEOUT"] = "123.5"
        try:
            settings = Settings()
            self.assertEqual(settings.chat_timeout, 123.5)
        finally:
            del os.environ["RAG_CHAT_TIMEOUT"]


if __name__ == "__main__":
    unittest.main()
