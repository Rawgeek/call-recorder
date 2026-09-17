#!/usr/bin/env python3
"""Find near-miss spellings of glossary terms in the transcript bodies.

    scripts/glossary-nearmiss.py "path/to/transcripts" "path/to/glossary.json"

The glossary's job is to repair a word the transcriber heard wrong. A term that is already spelled
correctly in the body needs no alias, so this looks for the other thing: a token close enough to a
term that it is almost certainly the same word heard badly, and not the term itself.

Distance is Damerau-Levenshtein over lowercase tokens, bounded at two edits. One edit on a short
word is usually a real word (cat/car), so a one-edit match needs a token of eight characters or
more to count. Two edits need six.
"""
import json
import re
import sys
from pathlib import Path

from transcript_text import transcript_body


def distance(a, b, limit):
    if abs(len(a) - len(b)) > limit:
        return limit + 1
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        best = i
        for j, cb in enumerate(b, 1):
            cost = 0 if ca == cb else 1
            value = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            if i > 1 and j > 1 and ca == b[j - 2] and a[i - 2] == cb:
                value = min(value, previous[j - 2] + 1)
            current.append(value)
            best = min(best, value)
        if best > limit:
            return limit + 1
        previous = current
    return previous[-1]


def main():
    folder = Path(sys.argv[1])
    terms = json.loads(Path(sys.argv[2]).read_text())["structuredContent"]["terms"]
    preferred = {t["preferred"] for t in terms}
    known = {t["preferred"].lower() for t in terms}
    for t in terms:
        for alias in t.get("aliases") or []:
            known.add(alias.lower())

    body_tokens = set()
    bodies = []
    for path in sorted(folder.glob("*.md")):
        text = path.read_text(encoding="utf-8", errors="replace")
        body = transcript_body(text)
        bodies.append(body)
        body_tokens.update(re.findall(r"[A-Za-z][A-Za-z'\-]{2,}", body))
    blob = "\n".join(bodies)

    word = re.compile(r"\b[A-Za-z][A-Za-z'\-]{2,}\b")
    hits = []
    for target in sorted(preferred):
        low = target.lower()
        if " " in low:
            continue
        for token in body_tokens:
            tlow = token.lower()
            if tlow == low or tlow in known:
                continue
            limit = 2 if len(low) >= 6 else 1
            if limit == 1 and len(low) < 8:
                continue
            if distance(low, tlow, limit) <= limit:
                count = len(re.findall(r"\b" + re.escape(token) + r"\b", blob))
                hits.append((count, token, target))
    hits.sort(reverse=True)
    print(f"near-miss candidates: {len(hits)}")
    for count, token, target in hits[:60]:
        print(f"{count:5d}  {token:24s} looks like  {target}")


main()
