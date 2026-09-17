"""Reads the spoken text of a saved transcript, without its header.

A transcript file opens with a title, the people on the call, and -- in files an earlier version
wrote -- a copy of the glossary. Splitting on the text "Glossary: " used to find where the speech
starts, which stopped working the moment the glossary left the header: a file written since then
holds no such text and was read as a header-only file, so every scan over a folder silently
skipped every transcript.

The header is a run of blank lines and prefixed lines at the top of the file. The first line that
is neither is the first line of speech.
"""

HEADER_PREFIXES = ("# ", "Participants:", "Glossary:", "Language:", "Model:", "Duration:", "Date:")


def transcript_body(text):
    """The spoken text of a transcript, or the whole file when it has no header."""
    lines = text.split("\n")
    saw_header_line = False
    for index, line in enumerate(lines):
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith(HEADER_PREFIXES):
            saw_header_line = True
            continue
        return "\n".join(lines[index:]) if saw_header_line else text
    return ""
