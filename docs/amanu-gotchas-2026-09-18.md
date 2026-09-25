# Amanu's gotchas, and where this app stands on each

Read on 2026-09-18 from `github.com/gsamat/amanu` at the clone in
`/tmp/amanu-inspect.oPbsbo`. Their own introduction to the list says it best:
"Each one was paid for once. Breaking any of them compiles, passes the tests, and fails
somewhere else." The sources read were `docs/pitfalls.md`, the closed `.issues/003`-`.010`
post-mortems, `rca-001`-`rca-003`, `docs/specs/2026-08-18-live-transcription-design.md`,
`docs/testing/window-shots.md`, and the two 2026-09-06 audit directories.

Every row below was re-checked against this repository, not copied. "Covered" means the
shape exists here and the check was read in the code; "open" means the failure can still
happen, and the paragraph says what would close it.

**Read this as of 2026-09-18.** The live transcript, the running summary, and the post-call brief
were removed in 0.1.33, and calls are read by Qwen3-ASR on MLX rather than by whisper.cpp. Rows that
rest on those engines describe the app as it was when this was written; the lessons do not depend on
which engine was reading.

## Open items

### 1. Quitting or installing an update during a recording destroys the open segment

Amanu measured the cost on a real call: replacing the app mid-meeting lost roughly three
minutes of a Telegram call, and nothing in the places a person looks before quitting said a
recording was running (`.issues/005`). Their fix was two-fold: a `.recording.json` marker
that `doctor` and the setup command read, and a `QuitGate` that turns quitting into a
question. The same trap sits here in two places (both read on 2026-09-18):

- `MenuBarView.swift:616` runs `NSApplication.shared.terminate(nil)` with no question.
- `AppModel.observeApplicationTermination()` swaps in a staged update and ends the model
  servers on `willTerminate`, after which the process exits. The updater stages while the
  app runs and installs at quit, so an automatic update has the same shape.

Segment writers are only closed on pause, stop, or discard; nothing rotates them (see item
2), so the audio since the last pause is what a quit costs. The next launch recovers what
was closed: `CallStore.interruptedRecordings()` closes out rows still marked `recording`
(read at `CallStore.swift:1692`), and the `segment-%03d.json` manifests name the files.
But the row is written *after* capture starts — in `AppModel.beginRecording`, `startSegment`
runs before `pipeline.start` — so a kill in that window leaves a folder with audio that no
row points at. That is the same smaller thing amanu fixed by writing the manifest before
either recorder starts (`.issues/009`).

**Account for it:** an explicit quit/restart question while `recorderState.phase` is
recording or paused, naming the recording's length and what is lost; the update row in
Settings can say the install waits for the recording to end; and the call row should be
written before `startSegment` (rolled back if capture fails to start) so recovery can see
every folder that holds audio. Amanu's `UpdateGate` and `QuitGate` are the pattern, and
their audit lists "quit during recording" as a manual step that was never run — so it
needs a test double of the quit path, not just a dialog.

### 2. A long call is one unclosed AAC segment

Amanu killed an AAC CAF mid-file and `afinfo` answered `estimated duration: 0.000000 sec`.
That measurement is why they moved the recorder to 16-bit LPCM written straight through: a
`SIGKILL` then leaves a decodable file (`.issues/006`). Here, `AudioCaptureSession` writes
`.m4a` through `AudioSampleWriter`, and the only thing that closes a segment is pause,
stop, or discard (read: `AppModel.swift:2891`, `:3031`, `:3079`; no rotation timer exists).
Our own `docs/pitfalls.md` already states the consequence: "A recording in progress is an
AAC file with no index. Read before its writer closes it, its length is zero." What is
missing is the other half: the window of loss is the whole call, not the last minute.

**Account for it:** rotate capture segments on a timer (five minutes would cap the loss at
five minutes and give the recovery path something to adopt), and/or write the audio path in
a format a kill leaves readable. Either way, `BackgroundAudioFinalization` and the
`segment-%03d.json` manifests already exist to adopt what was closed.

### 3. A digitally silent system track looks healthy

Amanu measured this twice. An unauthorised process tap returns `noErr`, reports a correct
2 ch / 48 kHz format, fires at the right rate for the whole meeting, and every sample is
zero (`rca-002`). The file grows normally, so even their stall watchdog could not see it,
and a manual tone test is the only check that ran — once, at setup (`010`).

Here, `SystemAudioCheck` compares the two files' sizes after the call. That catches a tap
that wrote almost nothing (the failure they measured first), and it cannot catch a tap that
wrote full-size zeros: the far end is missing, the transcript reads as one-sided, the call
scores as captured, and with the default `removeAudioAfterTranscription` the audio is gone.

**Account for it:** watch the system track's peak as buffers arrive, the way the mic path
has a level threshold (`AudioLevels.speechThresholdDecibels`, `AudioLevelMeter`). Warn only
when there is independent evidence sound was expected — their second audit specifically
rejected warning on fifteen ordinary seconds of quiet start (P2 in
`docs/audits/2026-09-06-fable/recording.md`) — which means mic speech plus a digitally zero
system track, after a grace period. Persist the answer so the badge and the Recovery pane
can say it after the fact; amanu's `doctor` fix was to report the age of the last tone test
rather than "unknowable".

### 4. A side that decoded to nothing completes as success and loses its audio

The highest-value finding in amanu's own audit was the shape, not the cause: one unreadable
track made per-track transcription swallow the error, a partial or empty transcript was
written, and `keep_audio=false` then deleted the sources — a successful-looking session
whose meeting was never transcribed (`docs/audits/2026-09-06-claude-code/README.md`, P1;
fixed so a failed or empty track is a failure and audio is kept for a retry).

Here, `Transcriber.transcribeSource` throws on a missing chunk file and on a repetitive
result, but an existing track that decodes to zero segments returns an empty
`WhisperTranscript` quietly (`Transcriber.swift:379-430`). The merge then holds only the
other side, `isRepetitive` sees nothing wrong, the markdown is non-empty, and
`ArtifactRecovery.finalizeReadyCall` removes the audio after the index stage. The case is
narrow (whisper usually fills silence with artifacts rather than nothing, and those are
filtered into zero), which is exactly why it would pass every test.

**Account for it:** after merging, refuse to complete when a source file that existed and
held audio contributed zero segments; make it a retryable failure so the audio stays and
the row says what is missing. The before/after pair amanu used as a regression test is
"one track failed after a successful prepare", which our suite also does not run.

### 5. The saved transcript deduplicates exactly; amanu's echo filter is fuzzy

Our `TranscriptDeduplicator` removes a repeated run of five or more *identical* words
within 200 words, and keeps the first copy. That handles both fault shapes it names — the
five-minute chunk seam and the room echo — when the two recogniser passes agree. Amanu
built a fuzzy, containment-based `EchoFilter` for the case where they do not agree, and
their audit then caught it erasing real speech: one mic label with 21 short "да" matches out
of 25 segments was declared an echo, and four further utterances went with it
(`.issues`-adjacent audit P1). Their fixed rule is worth copying before anyone ports it:
a direct echo drop requires *every* word of the mic segment to be accounted for in the
overlapping system text; short near-misses are only dropped when a channel-qualified
speaker is proven to be the far end's copy across at least twenty segments and an 80%
direct-match ratio. Our live filter cannot lose a speaker because it judges one line at a
time and never reclassifies what is already drawn, and the saved transcript never runs it.

**Account for it:** leave the batch pass strict, and if fuzziness is ever added, add it
with amanu's final constraints and their repro first: mixed echo plus local words must
survive, and a stack of short confirmations must never remove a speaker.

### 6. The live tap copies before the recording's own write

Amanu's live spec makes the ordering a rule: the file write stays first and authoritative,
the sink never awaits on the audio callback, and a missing sink costs no copy or allocation
(`docs/specs/2026-08-18-live-transcription-design.md`). Here `AudioCaptureRouter.stream`
calls `liveTap?.append(...)` before `systemWriter.append(...)`, and `LiveAudioTap.append`
copies the sample buffer synchronously before queueing it. The copy is small and the queues
are ScreenCaptureKit's own, not the real-time thread, so this is a hardening item rather
than a bug: the recording's writer should lead the tap, and the copy should be skipped when
the tap is closed (which the guard already does).

### 7. The verification their team never got

Amanu's `docs/pitfalls.md` ends with a list of things "believed correct on reasoning
alone", and the first entry is the live transcript: never tested against a real call with
echo cancellation in front of it. Ours has the same gap, larger: the live window has not
been through a real two-sided call at all, and the batch pipeline's edge cases above have
never met a track that failed while the other succeeded. What to run, in order of evidence
value: a real call with speakers (far end audible in the room) and see the live window show
one copy; a pause/resume with a device switch between; a long call to check chunk latency
and memory; and one forced kill to see what recovery keeps.

## Covered, with the check that covers it

| Amanu's finding | Where this app already stands |
| --- | --- |
| An app with no activity assertion is throttled: late IPC, drifting timers (pitfalls) | `AppModel` holds a `userInitiated` assertion for its life and a sleep-blocking one while recording |
| One database, two writers produced a foreign-key error (pitfalls, `.issues/004`) | MCP writes are requests applied by the signed app; recorded as the single-writer rule in `docs/pitfalls.md` |
| Nothing is deleted before what it produced is verified (audit follow-up) | `ArtifactRecovery.finalizeReadyCall` runs only after transcript, index, and speaker review; audio goes to Recently Deleted |
| A permission belongs to the signature that asked for it (pitfalls) | Same rule in our `docs/pitfalls.md`, including the re-grant-after-rebuild trap |
| TCC answers about the *responsible* process when a shell launches the app | Our permission checks run inside the signed bundle; the pitfalls doc names the dev-run trap |
| The hardened runtime closes what the entitlements do not name, silently | Screen Recording is read with `CGPreflightScreenCaptureAccess` and the refusal is named as a permission, not a capture failure |
| A microphone route change restarts capture; echo cancellation and the wall clock must survive the rebuild (`rca-003`) | Not the same engine: capture is one ScreenCaptureKit stream per segment, so mic and system share a clock and there is no voice unit to re-enable. A route change is picked up by the next segment |
| The microphone has to be followed; a default-device change does not reconfigure a running engine (pitfalls) | The segment resolves the system input each time it starts; the UI names the system's current input rather than pinning one. The boundary to state in docs: a change mid-segment takes effect at the next segment |
| Setting a default device can silently do nothing; read the property back | This app only reads the default; it never sets one |
| Live partial text is cumulative and must be revised in place, never appended twice (live spec) | Different design by choice: closed whisper chunks produce final lines, so there is no provisional text to reconcile; the cost is chunk latency, stated in the window |
| A live queue must be bounded and must drop rather than grow or block recording (live spec) | `LiveAudioTap` keeps 200 buffers and drops the oldest; `LiveTranscriber` keeps 10 chunks and reports what it dropped |
| Paused audio must not reach the live path (live spec) | Pause closes the tap's gate before silence is written; resume starts a new offset |
| A late result must not be drawn into the session it no longer belongs to (live spec) | Every live event carries the session token and a stale token is ignored |
| Live model memory must be released before the batch pass loads its own (live spec) | `finishLiveSession` stops and waits for the server before the finished call is queued |
| A live failure must not touch recording, the queue, or the library (live spec) | Live failures are lines in the live window; nothing else changes state |
| A live feature must not download a model mid-meeting (live spec) | A missing model is a sentence in the window; nothing is fetched |
| Asking for a window stayed behind the meeting app; the menu item read as broken | `WindowPresentation.present` activates the app before ordering the window |
| Live text is disposable and must never become the record (live spec) | Held in memory; chunk files deleted when the session ends; the saved transcript is written from the recording |
| A child's output read through a pipe is a race with a clock (their audit P1, our pitfalls) | `ProcessRunner` sends stdout and stderr to files and reads after exit; the diarizer was the one that did not, and is fixed |
| Turns are closed by silence in *audio*, not by clock, or a loading model reads as a pause (pitfalls) | `LiveAudioAccumulator` cuts by samples; `LiveTranscriber` never uses a timer |
| Short replies and delayed repetition are not echoes (live tests, both projects) | `LiveEchoFilter` refuses under five words and beyond four seconds, and never revisits a drawn line |
| Model chosen but not yet downloaded must stay chosen (`.issues/007`) | The choice is `settings.selectedWhisperModelID`; downloading is a separate action, and the UI offers it when selected and absent |
| Recording in progress must be visible before quitting (`.issues/005`) | Half-covered: the menu bar shows it, and launch closes rows left in `recording` (`CallStore.interruptedRecordings`). The quit gate, the update-at-exit shape, and the row-after-capture ordering are item 1 |

## Deliberate divergences, kept for a reason

- **Live text is final per chunk, not provisional per stream.** Amanu reconciles a
  cumulative decoder; we transcribe closed 15-second chunks with whisper.cpp and draw each
  line once. No revision pass exists because none is needed, and the window says the text
  is final but delayed.
- **The live window stays open when the meeting ends.** Their transcript folds away with
  their status window; a window the user opened here stays until they close it.
- **The batch echo pass is exact-match only.** Amanu's fuzzy pass cost them real speech
  before it was constrained. A duplicate a reader skips is cheaper than a sentence a
  speaker said and cannot get back (item 5).
- **System audio is judged by file size, not by a tone test at setup.** Theirs was a
  first-run experiment with a thirty-day memory; ours is a post-call comparison that feeds
  the "One side only" badge. The zero-sample case is item 3.

## Smaller rules worth keeping in reach

- **Sign nested code innermost first.** `codesign` seals what it finds; a framework signed
  after its container invalidates the container, and the failure appears on someone else's
  Mac (their pitfalls). Applies to anything bundled beside the app's own executable.
- **Test the thing that ships.** Their audits found that CI ran `swift test` while the
  bundle, its licenses, its universal slices, and the signing order were first exercised at
  release. Our release script runs the packaging and preview paths; keep at least one check
  that builds and inspects the real `.app`.
- **Release notes are rendered by code and need a fixture.** Their `notes-to-html.py`
  silently split one list into six and left `**bold**` markers across a line wrap in the
  window users see. Whatever renders ours should be tested with a wrapped bold span and a
  bullet list separated by blank lines.
- **Release fingerprints must be stable.** Git's abbreviated object IDs changed length
  between builds and made an identical source tree look different; hash with
  `--binary --full-index` when a digest is a gate.
- **The SSH agent the host selects can differ from `ssh-add`.** A publication failed with
  `Permission denied (publickey)` while the working key sat in the other agent; scope
  `IdentityAgent` per command rather than rewriting global settings (their pitfalls).
- **Cache permission queries within one run-loop turn.** Their `SMAppService` status cost
  14 ms and a redraw asked twelve times; a click spent a quarter second asking the same
  question (their pitfalls). Our screens read grants too — keep them out of draw paths.
- **A `CGColor` is a resolved number, not a rule.** AppKit layer colors keep the appearance
  they resolved in, unless re-tinted on change. The settings surfaces are SwiftUI now, but
  anything painting into a layer gets this check: render in one appearance, switch, and
  compare to the picture born in the other (their `window-shots.md` method).
- **Screenshots of machine state are not baselines.** Their gallery renders whatever the
  Mac says and refuses to keep pictures of real meetings. Our preview seed already invents
  names for public images — keep that rule when the release screenshots are regenerated.
- **State transitions, not extra assertions, are what the audits found missing.** Their
  green suites hid: a decode failure after a successful prepare, an ambiguous echo label,
  a queue mutating during a send, a permission denied after setup closed. Our equivalents
  are items 4 and 5, plus pause/resume across a device change and MCP writes during a
  recording.

## What this changes here

Items 1-6 are new open work; the live-transcript phase-1 table in
`docs/live-transcript-2026-09-18.md` covers the live-specific rows in both directions.
Nothing in this document was implemented as part of writing it: the app is running on a
live call, and the capture-path changes above (segment rotation, a quit gate) need their
own tests and a machine that is not mid-meeting.
