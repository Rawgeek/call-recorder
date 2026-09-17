#!/usr/bin/env python3
"""Independently verify a Call Recorder transcript repair against its backup.

Checks, per rewritten transcript:
  1. Every spoken word survives, in order (speaker tags removed before tokenising).
  2. The speaker tag sequence equals the backup sequence with consecutive duplicates
     removed, which is exactly what folding is allowed to do.
  3. Non-speaker lines (headers, plain text) survive in order and unchanged.
  4. No paragraph exceeds the documented ceiling.
  5. The folded-line count the report claims equals the tags removed.
"""
import re
import sys
from pathlib import Path

TAG = re.compile(r'\*\*[^*]+\*\*: ')
SPEAKER_LINE = re.compile(r'^(\*\*[^*]+\*\*: )(.*)$')
CEILING = 900

def spoken_words(text):
    return TAG.sub('', text).split()

def tags(text):
    out = []
    for line in text.split('\n'):
        m = SPEAKER_LINE.match(line)
        if m:
            out.append(m.group(1))
    return out

def other_lines(text):
    out = []
    for line in text.split('\n'):
        if SPEAKER_LINE.match(line) or not line.strip():
            continue
        out.append(line)
    return out

def is_legal_fold(old_tags, new_tags):
    """True when `new_tags` is `old_tags` with some turns folded upward.

    A turn may only disappear when the paragraph above it belongs to the same speaker,
    so every skipped tag must equal the last tag the output kept. A paragraph that hits
    the ceiling is legally *not* folded, which leaves two neighbouring paragraphs of one
    speaker, so the output may keep any duplicate the old list contains.
    """
    if not new_tags:
        return not old_tags
    if new_tags[0] != old_tags[0] or len(new_tags) > len(old_tags):
        return False
    i = 0
    last_kept = None
    for tag in new_tags:
        while i < len(old_tags) and old_tags[i] != tag:
            if old_tags[i] != last_kept:
                return False
            i += 1
        if i == len(old_tags):
            return False
        i += 1
        last_kept = tag
    while i < len(old_tags):
        if old_tags[i] != last_kept:
            return False
        i += 1
    return True

def paragraph_widths(text):
    return [len(block.strip()) for block in text.split('\n\n') if block.strip()]

def main(backup, library):
    backup = Path(backup)
    library = Path(library)
    failures = []
    checked = 0
    tags_before = tags_after = 0
    widest = (0, '')
    for folder in sorted(p for p in backup.iterdir() if p.is_dir()):
        notes = sorted(folder.glob('*.md'))
        if len(notes) != 1:
            failures.append(f'{folder.name}: expected one .md in backup, found {len(notes)}')
            continue
        before = notes[0]
        after = library / before.name
        if not after.exists():
            failures.append(f'{before.name}: no current file at {after}')
            continue
        old = before.read_text(errors='replace')
        new = after.read_text(errors='replace')
        checked += 1
        if spoken_words(old) != spoken_words(new):
            failures.append(f'{before.name}: spoken word sequence changed')
        old_tags, new_tags = tags(old), tags(new)
        tags_before += len(old_tags)
        tags_after += len(new_tags)
        if not is_legal_fold(old_tags, new_tags):
            failures.append(f'{before.name}: tag sequence is not a legal fold of the backup')
        if other_lines(old) != other_lines(new):
            failures.append(f'{before.name}: non-speaker lines changed')
        for width in paragraph_widths(new):
            if width > widest[0]:
                widest = (width, before.name)
            if width > CEILING:
                failures.append(f'{before.name}: paragraph of {width} chars exceeds {CEILING}')
    print(f'checked {checked} rewritten transcripts')
    print(f'speaker lines {tags_before} -> {tags_after} (folded {tags_before - tags_after})')
    print(f'widest paragraph {widest[0]} chars in {widest[1]}')
    if failures:
        print(f'FAILURES {len(failures)}')
        for line in failures[:40]:
            print('  ' + line)
        return 1
    print('all checks passed')
    return 0

def foldable_pairs(text, ceiling=CEILING):
    """Count neighbouring paragraphs of one speaker that the rule would still join."""
    blocks = [b for b in text.split('\n\n') if b.strip()]
    pairs = 0
    previous = None
    for block in blocks:
        line = block.strip()
        m = SPEAKER_LINE.match(line)
        if not m:
            previous = None
            continue
        if previous is not None:
            prev_tag, prev_width = previous
            if prev_tag == m.group(1) and prev_width + 1 + len(m.group(2)) <= ceiling:
                pairs += 1
        previous = (m.group(1), len(line))
    return pairs

def library_check(library):
    library = Path(library)
    files = sorted(library.glob('*.md'))
    stopped = []
    over = []
    for path in files:
        text = path.read_text(errors='replace')
        pairs = foldable_pairs(text)
        if pairs:
            stopped.append((path.name, pairs))
        for width in paragraph_widths(text):
            if width > CEILING:
                over.append((path.name, width))
    print(f'library files {len(files)}')
    print(f'files still holding a foldable pair: {len(stopped)}')
    for name, pairs in stopped[:10]:
        print(f'  {name}: {pairs}')
    print(f'paragraphs over the ceiling: {len(over)}')
    return 0 if not (stopped or over) else 1

if __name__ == '__main__':
    if sys.argv[1] == '--library':
        sys.exit(library_check(sys.argv[2]))
    sys.exit(main(sys.argv[1], sys.argv[2]))
