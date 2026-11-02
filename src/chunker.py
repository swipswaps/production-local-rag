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
        Recursively split text until every piece is at most chunk_size.
        Order: sentences -> words -> hard character split. A piece is never
        returned larger than chunk_size, which is what makes the class-level
        size guarantee hold for callers.
        """
        if len(text) <= self.chunk_size:
            return [text]

        sentences = [s for s in _SENTENCE_RE.split(text) if s]
        if len(sentences) > 1:
            pieces: List[str] = []
            for sentence in sentences:
                pieces.extend(self._split_long_text(sentence))
            return pieces

        words = text.split()
        if len(words) > 1:
            pieces = []
            current = ""
            for word in words:
                if len(word) > self.chunk_size:
                    if current:
                        pieces.append(current)
                        current = ""
                    pieces.extend(
                        word[i:i + self.chunk_size]
                        for i in range(0, len(word), self.chunk_size)
                    )
                    continue
                candidate = f"{current} {word}".strip() if current else word
                if len(candidate) > self.chunk_size:
                    pieces.append(current)
                    current = word
                else:
                    current = candidate
            if current:
                pieces.append(current)
            return pieces

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
            content = current.strip()
            if content:
                chunks.append({
                    "content": content,
                    "source": source_name,
                    "length": len(content),
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
                        budget = self.chunk_size - len(piece) - 1
                        if budget <= 0:
                            overlap = ""
                        elif len(overlap) > budget:
                            overlap = overlap[-budget:]
                            match = re.search(r"\s", overlap)
                            if match:
                                overlap = overlap[match.start() + 1:]
                        current = (overlap + "\n" + piece).strip() if overlap else piece
                    else:
                        current = candidate

        flush()
        logger.info("Generated %d chunks from %s", len(chunks), source_name)
        return chunks
