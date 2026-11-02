"""
Module: test_cli.py
Description: Smoke tests for the non-interactive CLI. These exercise argument
             parsing only, so they run without the runtime dependencies.
"""

import io
import unittest
from contextlib import redirect_stderr, redirect_stdout

from src.cli import main


class CliSmokeTest(unittest.TestCase):
    def test_help_exits_zero(self) -> None:
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                main(["--help"])
        self.assertEqual(caught.exception.code, 0)

    def test_unknown_command_exits_two(self) -> None:
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as caught:
                main(["nope"])
        self.assertEqual(caught.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
