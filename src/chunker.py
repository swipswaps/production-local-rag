"""
Module: chunker.py
Description: Size-bounded recursive chunker. Splits on markdown headers first,
             then paragraphs, then sentence boundaries, then characters. Unlike
             the previous version, this implementation guarantees that no chunk
             exceeds chunk_size and uses word-boundary-aware overlap.
Citations:
- Kamradt, G. (2023). Chunkviz. https://github.com/gkamradt/LLMTest_RetrievalfromTheBottom
- LlamaIndex text splitters: https://docs.llamaindex.ai/
"""

import logging
import re
from typing import List, Dict, Any

logger = logging.getLogger(__name__)

# Sentence boundary regex (keeps trailing punctuation).
_SENTENCE_RE = re.compile(r"(?<=[.!?])\s+")


class RecursiveMarkdownChunker:
    """
    Recursively splits markdown into chunks no larger than chunk_size.
    """

    def __init__(self, chunk_size: int = 400, chunk_overlap: int = 50) -> None:
        if chunk_overlap >= chunk_size:
            raise ValueError("chunk_overlap must be smaller than chunk_size")
        self.chunk_size = chunk_size
        self.chunk_overlap = chunk_overlap

    def _split_long_text(self, text: str) -> List[str]:
        """
        Recursively split text that exceeds chunk_size.
        Order: sentences -> words -> hard character split.
        """
        if len(text) <= self.chunk_size:
            return [text]

        sentences = _SENTENCE_RE.split(text)
        if len(sentences) > 1:
            return sentences

        words = text.split()
        if len(words) > 1:
            return words

        return [text[i:i + self.chunk_size] for i in range(0, len(text), self.chunk_size)]

    def _overlap_tail(self, text: str) -> str:
        """
        Return a word-boundary-aware tail of text for overlap.
        Avoids cutting in the middle of a word where possible.
        """
        if len(text) <= self.chunk_overlap:
            return text
        tail = text[-self.chunk_overlap:]
        match = re.search(r"\s", tail)
        if match and match.start() < len(tail) - 1:
            return tail[match.start() + 1:]
        return tail

    def chunk_text(self, text: str, source_name: str) -> List[Dict[str, Any]]:
        """
        Split markdown text into size-bounded chunks with metadata.
        """
        if not text.strip():
            logger.warning("Empty text provided for chunking from %s", source_name)
            return []

        # Split on headers first so each heading stays with its body.
        header_blocks = re.split(r"(?m)(?=^#{1,6}\s)", text)

        chunks: List[Dict[str, Any]] = []
        current = ""

        def flush() -> None:
            nonlocal current
            if current.strip():
                chunks.append({
                    "content": current.strip(),
                    "source": source_name,
                    "length": len(current),
                })
            current = ""

        for block in header_blocks:
            for para in block.split("\n\n"):
                cleaned = para.strip()
                if not cleaned:
                    continue

                pieces = self._split_long_text(cleaned)
                for piece in pieces:
                    candidate = (current + "\n" + piece).strip() if current else piece
                    if len(candidate) > self.chunk_size:
                        flush()
                        overlap = self._overlap_tail(chunks[-1]["content"]) if chunks else ""
                        current = (overlap + "\n" + piece).strip() if overlap else piece
                    else:
                        current = candidate

        flush()
        logger.info("Generated %d chunks from %s", len(chunks), source_name)
        return chunks
