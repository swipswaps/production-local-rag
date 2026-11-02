"""
Module: test_chunker.py
Description: Contract tests for RecursiveMarkdownChunker. Enforces the
             documented size bound, the metadata shape, and the regressions
             that previously produced chunks larger than chunk_size.
"""

import random
import string
import unittest

from src.chunker import RecursiveMarkdownChunker


class ChunkerContractTest(unittest.TestCase):
    def assert_contract(self, text: str, chunk_size: int, chunk_overlap: int) -> None:
        chunker = RecursiveMarkdownChunker(
            chunk_size=chunk_size, chunk_overlap=chunk_overlap
        )
        chunks = chunker.chunk_text(text, source_name="contract.md")
        for chunk in chunks:
            self.assertEqual(chunk["source"], "contract.md")
            self.assertEqual(chunk["content"], chunk["content"].strip())
            self.assertEqual(chunk["length"], len(chunk["content"]))
            self.assertLessEqual(len(chunk["content"]), chunk_size)
        if text.strip():
            self.assertTrue(chunks)

    def test_size_bound_regressions(self) -> None:
        for chunk_size, chunk_overlap in [(100, 50), (400, 50), (50, 49), (10, 0), (10, 9)]:
            unit = max(1, chunk_size // 2)
            text = "\n\n".join(["x" * unit for _ in range(6)])
            with self.subTest(chunk_size=chunk_size, chunk_overlap=chunk_overlap):
                self.assert_contract(text, chunk_size, chunk_overlap)

    def test_giant_token_is_split(self) -> None:
        self.assert_contract("z" * 5000, 400, 50)

    def test_long_sentence_is_split(self) -> None:
        self.assert_contract("short one. " + ("word " * 500) + "end.", 200, 30)

    def test_random_texts_obey_bound(self) -> None:
        rng = random.Random(1234)
        alphabet = string.ascii_letters + string.digits + " .,!?\n\n#_"
        for _ in range(200):
            text = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 2500)))
            chunk_size = rng.randint(5, 500)
            chunk_overlap = rng.randint(0, chunk_size - 1)
            with self.subTest(chunk_size=chunk_size, chunk_overlap=chunk_overlap):
                self.assert_contract(text, chunk_size, chunk_overlap)

    def test_empty_text_returns_empty_list(self) -> None:
        self.assertEqual(
            RecursiveMarkdownChunker().chunk_text("   \n\n", "empty.md"), []
        )


if __name__ == "__main__":
    unittest.main()
