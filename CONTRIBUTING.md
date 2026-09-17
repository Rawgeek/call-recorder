# Contributing

Thanks for looking at Call Recorder. This guide covers how to build it, how to run the
checks, and what a change is expected to prove before it is merged.

## Reporting a bug

1. Every error surface in the app has **Copy Error Details**. Copy it, then paste it into the
   issue. It contains the message, the context, and the stack trace, and no audio or
   transcript text.
2. For a processing failure, **Settings -> Recovery** can export a redacted diagnostics
   bundle. Attach it to the issue when the short error is not enough.
3. Remove personal data before pasting: names, transcript lines, and file paths that identify
   you are not needed to reproduce a bug.

## Development setup

Requirements: an Apple silicon Mac with macOS 15 or newer, Xcode 16 or newer (Swift 6.2
toolchain), and Homebrew.

```sh
brew install ffmpeg whisper-cpp bun
swift build
swift test
cd mcp && bun install && bun run typecheck && bun test
```

Useful during development:

- `swift run CallRecorder` runs the app from the build directory.
- `scripts/preview.sh <dir>` renders every window to PNG files without packaging, signing, or
  installing. Renders read the real library by default; set `CALL_RECORDER_PREVIEW_HOME` to
  an empty directory to render against a throwaway library instead.
- `scripts/package-app.sh <output>` builds the distributable bundle.

## Checks that run themselves

```sh
scripts/install-hooks.sh
```

points this clone at the hooks in `.githooks`. They run with every commit and push:

- **pre-commit** requires the documents to match the bundle (the version in `README.md` and
  `DISTRIBUTION_README.txt`, a changelog entry for it, and every screenshot the README shows) and
  runs the linters on the lines being committed: swift-format for Swift and Biome for `mcp`. Only
  changed lines are checked; the tree carries older style findings that are not yours to fix.
- **pre-push** repeats that check, runs `swift test`, and runs the MCP typecheck, lint, and tests
  when `mcp/` changed. `git push --no-verify` skips the gate when CI has already answered.

## Releasing

```sh
scripts/release.sh --check      # what the hooks run
scripts/release.sh --sync       # write the version into the documents, re-render docs/images
scripts/release.sh --publish    # test, package, publish, then download the release back and check it
```

Bump `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist` and write the
changelog entry first. `--sync` generates the version references and the screenshots from the
bundle; `--publish` refuses a `HEAD` that `origin/main` has not seen, and checks the published
archive the way the updater reads it: digest, the bundle at the top level of the zip, version,
build, and signature.

## Layout

| Path | Contents |
| --- | --- |
| `Sources/CallRecorderApp` | Menu bar, capture, finalization, transcription, settings, and the review windows. |
| `Sources/CallRecorderCore` | Database and migrations, the recorder reducer, speaker matching, glossary correction, transcript artifacts. |
| `mcp/src` | The MCP server, search (BM25 + vectors), chunker, and the indexer entry point. |
| `Tests/CallRecorderCoreTests` | Swift test suite. |
| `mcp/test` | MCP server test suite. |
| `scripts/` | Packaging, preview rendering, and measurement tools. |

## What a change must prove

- `swift test` passes, and `bun test` plus `bun run typecheck` pass inside `mcp/`.
- New behaviour has a test that fails without the change. Bug fixes get a test written from
  the failing case, not from the fixed one.
- User-visible text is plain and specific: say what happened, what it means, and what the
  user can do next. Avoid jargon and unverifiable claims.
- Keep the diff scoped. A change that also reformats or renames unrelated code makes the
  review harder and is usually asked to be split.
- Privacy is part of correctness here. Nothing may send audio, transcripts, voiceprints, or
  search text off the machine, and none of those may appear in diagnostics, logs, or MCP
  responses beyond the documented tool outputs.

## Pull requests

Describe the problem, the change, and the checks you ran. If a check could not be run, say so
explicitly rather than leaving it implied. Screenshots are welcome for UI changes; the
preview renderer can produce them without installing anything.
