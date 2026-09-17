#!/usr/bin/env python3
"""List words the transcripts use that the glossary does not cover.

    scripts/glossary-gaps.py "path/to/transcripts" glossary.json [min-count]

glossary-candidates.py reports whole capitalised runs, so a run such as "Vendor Bill Bill"
counts as a gap even though "Vendor Bill" is saved, and a saved two-word term never covers the
single words inside it. This compares saved spellings against transcript words one token at a
time, so the answer is about the words themselves: a token is covered when it appears in any
preferred spelling or alias, in any casing.

Only capitalised words count, and never the first word of a sentence, because that one is
capitalised by grammar rather than because it is a name.
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

from transcript_text import transcript_body


def main():
    folder = Path(sys.argv[1])
    terms = json.loads(Path(sys.argv[2]).read_text())["structuredContent"]["terms"]
    minimum = int(sys.argv[3]) if len(sys.argv) > 3 else 2

    covered = set()
    for term in terms:
        for spelling in [term["preferred"], *(term.get("aliases") or [])]:
            for token in re.findall(r"[A-Za-z][A-Za-z0-9'\-]{2,}", spelling):
                covered.add(token.lower())

    sentence = re.compile(r"(?<=[.!?])\s+|\n+")
    word = re.compile(r"\b[A-Z][A-Za-z0-9'\-]{2,}\b")
    counts = Counter()
    files = sorted(folder.glob("*.md"))
    for path in files:
        body = transcript_body(path.read_text(encoding="utf-8", errors="replace"))
        for chunk in sentence.split(body):
            chunk = chunk.strip()
            if not chunk:
                continue
            words = chunk.split(" ")
            # A word after a full stop starts a sentence and is capitalised by grammar.
            for token in word.findall(" ".join(words[1:])):
                counts[token] += 1

    gaps = [
        (count, token)
        for token, count in counts.items()
        if count >= minimum and token.lower() not in covered
    ]
    gaps.sort(key=lambda item: (-item[0], item[1]))
    print(f"files={len(files)} saved-spellings={len(covered)} gaps={len(gaps)}")
    for count, token in gaps:
        print(f"{count:5d}  {token}")


if __name__ == "__main__":
    main()

