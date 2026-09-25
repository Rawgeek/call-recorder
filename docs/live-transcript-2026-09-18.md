# Live transcript, quick chat, and speakers while a call is running

Status: Phase 1 planned, Phase 2 designed. Owner: Stas. Date: 2026-09-18.

**Removed in 0.1.33.** The live window, the running summary, and the quick chat were built and then
removed by request, because each was a second reader of the same recording and the sum of them was
more than the machine should carry. The post-call brief went with them. This note is kept as the
record of what was designed and measured; every engine it names was replaced in 0.1.33 by Qwen3-ASR
on MLX, which is what reads a call now.

## 1. Problem

Call Recorder writes the transcript after the call ends. During the call the screen holds nothing
but a timer, so a person who joins late, or who missed a minute while answering something else,
has no way to catch up until the meeting is over. They asked for three things: the words as they
are said, a way to ask a short question about what has been said, and a better answer than "some
voice" to the question of who is talking.

Intended users: the person recording, on their own Mac, in the same call.

Outcome: while a recording runs, a window shows the words so far with who said them; a question
typed into it is answered from the words so far; the window can be turned off or put away.

Success measures: text appears within about 20 seconds of being spoken; a question is answered in
under 15 seconds on this Mac; the batch transcript, diarization, and brief are unchanged.

Exclusions: nothing about the saved transcript changes; the live view is a reading aid, not a
record. Cloud services are out of scope for the same reason they are out of the rest of the app.

## 2. What exists (evidence)

| Fact | Evidence |
| --- | --- |
| Audio arrives in real time as 32-bit float PCM on two queues, microphone and system | `AudioLevelMeter.observe`, `AudioCaptureRouter.stream` |
| The recording is written to disk continuously, one file per source per segment | `AudioSampleWriter`, `CaptureSegmentManifest` |
| A partial recording file cannot be read while it is being written | `ffprobe` on `.system-001-*.partial.m4a`: "moov atom not found" |
| `whisper-server` ships with the same Homebrew package the app already requires, with Metal | `whisper-server --version`, whole run through whisper.cpp |
| Chunked transcription keeps up with a call | measured: 15 s chunk in 1.6 s (9.5x realtime), 20 s chunk in 1.5 s (13x), large-v3-turbo q5_0, this Mac |
| The app already builds the whisper prompt from participants and the glossary | `PromptBuilder.whisperContext`, `WhisperCommand.arguments` |
| A local model and its runtime are already a dependency, for briefs | `SummarizerServer`, `SupportingModel.callBriefID` |
| Batch diarization is pyannote 4.x in a Python venv; 58 s of audio took 21 s including model load | `diarize.py`, timed on this Mac |
| Windows are declared scenes, opened with `openWindow`, and promote the accessory app | `CallRecorderApp`, `WindowPresentation`, `MenuBarView` |
| Settings carry a fallback per key, so an older blob keeps working | `AppSettings.init(from:)` |

## 3. Requirements

| ID | Requirement | Priority |
| --- | --- | --- |
| R1 | A live transcript window opens when a recording starts; a setting turns this off | must |
| R2 | The window can be hidden while the recording continues | must |
| R3 | Speech appears in the window within about 20 s, with a time and a speaker as far as it is known | must |
| R4 | A question typed in the window is answered from the words so far | must |
| R5 | The window offers a few recommended questions | must |
| R6 | The saved transcript, diarization, and brief are produced by the existing pipeline and are unchanged | must |
| R7 | The live path never slows the recording; if it falls behind, the window says so | must |
| R8 | Remote speakers are told apart and named where the voice library allows it | Phase 2 |
| R9 | The live model can be chosen separately from the batch model | Phase 2 |

## 4. Five implementations compared

1. **Capture tap and a long-lived whisper-server (chosen).** The router hands each buffer to a tap
   that keeps 16 kHz mono PCM per source and writes a chunk every 15 s; one `whisper-server`
   process, started when the live view starts, transcribes closed chunks in order. Reuses the
   capture, the whisper prompt builder, and the tool locator. Cost: a second consumer of the audio
   and a new subprocess to manage. It is the only candidate that reads audio that is still being
   written and it pays the model load once.
2. **A tap and `whisper-cli` per chunk.** Same tap, one process per chunk. Simpler code, but each
   chunk pays the 574 MB model load, and the batch transcriber's process runner is built for one
   job at a time. Rejected on latency and churn.
3. **whisper.cpp's own streaming example fed from stdin.** Lowest latency in theory, but the
   example is not part of the app's verified toolchain, its output is printed text rather than
   JSON, and a second transcription of the same audio at the same time as the batch path risks
   differing text for the same words. Rejected on control and on a second source of truth.
4. **Re-transcribe the growing recording file.** No new tap; read the partial file at increasing
   offsets. Rejected on evidence: the partial file has no `moov` atom and cannot be decoded until
   the recording is finalized.
5. **Remote transcription service.** Best latency and accuracy, but it sends the call off the Mac,
   which is the property this app exists to keep. Rejected on privacy.

## 5. Phases

**Phase 1 (this release).** The tap, the live transcriber, the window, quick chat, recommended
questions, the setting, and speaker labels from the capture source: the person recording is named
(their own name when the library knows it, "You" otherwise), the other side is "Others".

**Phase 2 (designed, not built).** Remote voices told apart and named live: a long-lived Python
process holding pyannote, sent a rolling 60 s window of the system track every ~45 s with overlap;
centroids matched to each other to keep labels stable, then to the learned voiceprints through the
existing `SpeakerMatcher` to put names on them. Evidence it can work: the same model and matcher
already name voices after the call, 58 s of audio costs 21 s with the model load included, and the
load is paid once in a persistent process. Trigger to start: Phase 1 in use, and the window's
"Others" grouping found to be the limitation that matters.

## 6. Phase 1 concepts

The window opens when the red dot appears. The top says what is happening: `Listening`, or
`Reading the last 40 seconds` when the transcriber is behind. The body is a conversation: each
entry is a time, a speaker, and the words, and the view follows the end. A question typed at the
bottom is answered above the field with the words it used, and can be asked again. Below the field
are four questions that fit any call: "What have I missed?", "What was decided?", "What are the
action items?", "What numbers came up?". Hiding the window leaves the recording and the transcript
alone; the red dot in the menu bar brings it back.

## 7. Phase 1 elements

| ID | Element | Requirements |
| --- | --- | --- |
| E1 | Capture tap: buffers to 16 kHz mono PCM, 15 s chunks per source | R3, R6, R7 |
| E2 | Live transcriber: whisper-server, ordered queue, prompt from the call | R3, R7 |
| E3 | Live transcript: entries, text for prompts, recommended questions, status | R3, R4, R5 |
| E4 | Live chat: question, transcript tail, answer, running state | R4, R5 |
| E5 | Live window: entries, status, field, chips, Hide | R1, R2, R4, R5 |
| E6 | Wiring: start with the recording, stop with it, open on start when the setting is on | R1, R2, R7 |
| E7 | Setting: "Show the live transcript while recording", default on | R1 |

Contracts and the acceptance criteria are in the code beside each element (this plan is the
concept; the code is the contract). The rules that matter:

- E1 never blocks the audio thread: buffers are appended under a lock and written by a worker.
- E1 keeps the recording's own writers untouched; the tap reads the same buffers and nothing else.
- E2 transcribes one chunk at a time, in capture order, and drops a chunk only if it falls more than
  ten chunks behind, saying so.
- E3 marks an entry as coming from the microphone or the system and never merges the two.
- E4 sends at most the last 8,000 characters of the transcript, asks for an answer under 120 words,
  and refuses a question with an empty transcript.
- E5 shows a failure as a line in the window, not a dialog.
- E6 stops the whole live path when the recording stops or is discarded, and deletes the live
  audio it wrote.
- E7 off means no window, no tap, and no transcriber.

## 8. Phase 1 execution plan (dependency order)

1. `LiveTranscript` in Core: entries, prompt text, questions, status wording. Tests.
2. `LiveAudioTap`: PCM conversion and chunk files. Test the chunk writer with synthetic buffers.
3. `LiveTranscriber`: whisper-server lifecycle, request/response, queue order. Test decoding and
   ordering against a stub runner.
4. `LiveChat`: prompt, answer, running state, recommended questions. Tests.
5. `LiveTranscriptView` and the scene; wiring in `AppModel`; setting and toggle.
6. Run the app, record a short call, read the window, and check the saved transcript is unchanged.
7. Release notes, version, publish, install.

## 9. Review findings

| Finding | Severity | Correction |
| --- | --- | --- |
| The live text and the saved transcript could disagree, and a reader may treat the live one as the record | high | The window says it is a reading aid and that the transcript is written at the end; the live text is never written into the library |
| Two whisper processes would compete for the machine | medium | The live path stops the moment the recording stops, and the batch path runs after it |
| A question could be answered from a transcript that holds almost nothing | medium | A question with no entries is refused with a sentence that says why |
| The tap could slow the audio thread | medium | Fixed, small work on the audio thread; conversion and file writing on a worker queue |
| Live audio left behind after a crash | low | Live chunks are deleted when the session ends and live under the call's own folder, which the existing cleanup already handles |

## 10. Open decisions

| Decision | Default taken |
| --- | --- |
| Live model separate from the batch model | Phase 2; Phase 1 uses the selected model, measured to keep up |
| Whether Phase 1 should also name remote voices | No; Phase 2 does it properly rather than guessing |

## 11. What amanu already paid for

Amanu (github.com/gsamat/amanu) is a Mac meeting recorder with a shipped live transcript and a
`docs/pitfalls.md` of things that compiled, passed tests, and failed in a real call. Read on
2026-09-18; each row is a rule this build follows because that one cost somebody a meeting.

| Their finding | What this build does about it | Where |
| --- | --- | --- |
| An app that takes no activity assertion is throttled: IPC answers seconds late, timers drift, a request is obeyed after the caller gave up | Hold `userInitiated` for the app's life, and `idleSystemSleepDisabled` while recording | `AppModel.startActivityAssertions` |
| The microphone hears the speakers, so the far end appears twice: once as `Others`, once as `You`. Measured at −3 dB on their own track for 35 minutes | A microphone line is dropped when, within 4 s of a system line, it shares an anchor of 3 words and 90 % of its words cover the system text in the same minute | `LiveEchoFilter` |
| A short reply is not an echo, and a repetition four seconds later is a person answering | Fewer than 5 words is never an echo; a match further than 4 s away is never an echo | `LiveEchoFilter` |
| A speaking side that decodes nothing for two seconds of *audio* has paused; two seconds of clock reads a loading model as a pause | Chunks are cut by samples, never by a timer | `LiveAudioAccumulator` |
| Live audio is handed over on a bounded queue; overflow stops live rather than growing memory or delaying the recording | The tap keeps a bounded buffer queue, the transcriber a bounded chunk queue, and both report what they dropped | `LiveAudioTap`, `LiveTranscriber` |
| A result that arrives after the session it belongs to has ended must not be drawn | Every event carries the session's token, and the model ignores one from an older token | `AppModel.applyLiveEvent` |
| Live model memory must be released before the batch pass loads its own model | The live server is stopped and waited for before the finished call is queued | `AppModel.finishLiveSession` |
| A live failure must not touch recording, the queue, or the library | Every failure is a line in the live window; nothing else changes state | `LiveTranscriptStatus.failed` |
| No audio that was captured while live was off, or before it started, is replayed | The tap exists only while a recording runs; pause flushes and closes it | `AudioCaptureRouter`, `AppModel` |
| Asking for a window ordered it to the front of the app's own layer only, so it stayed behind the meeting app and the menu item read as broken | The window is opened through `WindowPresentation.present`, which activates the app | `CallRecorderApp`, `WindowPresentation` |
| Live text must never be written into the library | The live text is held in memory and the chunk files are deleted when the recording ends | `LiveTranscriptSession.finish` |
| A live feature must not start a model download during a meeting | A missing model is a sentence in the window, and nothing is fetched | `LiveTranscriptionServer.start` |

Two things amanu learned that this build does differently, on purpose:

- Their live text folds away when the meeting ends, because it lives in their status window and
  there is no reason for that window to stay tall. This app's live text is a window the person
  opened, so it stays until they close it: a window that vanishes while it is being read is worse
  than one that has nothing left to say.
- They transcribe both sides at once with a streaming model and hold provisional text. This build
  transcribes closed chunks with whisper.cpp, so every line is final when it is drawn and there is
  no revision to reconcile — at the cost of the ~15 s chunk it takes to close one.

The rest of what their post-mortems and audits hold — including the capture-path items this build
has not paid for yet — is mapped in [amanu-gotchas-2026-09-18.md](amanu-gotchas-2026-09-18.md).

## 12. The running summary (2026-09-21)

The window follows a call with the words as they are said, which is the wrong shape for somebody who
has to catch up in the middle of one. Every ninety seconds by default the model rewrites the call so
far, the window shows that instead of the words, and a switch at the top of the window moves between
the summary and the words. Nothing about the record changes: the transcript that is kept is still
written from the recording when the call ends.

| Rule | Why | Where |
| --- | --- | --- |
| A pass is asked for only after 900 characters of new speech | Speech arrives at about fifteen characters a second, so that is a minute of talking: an update is worth re-reading, a ten-second one is a flicker, and a quiet stretch costs nothing | `LiveSummary.isWorthUpdating` |
| The step is 30 s, 60 s, 90 s, or 3 min, ninety seconds by default | Ninety seconds of speech is about a page; five minutes is a chapter | `LiveSummaryInterval` |
| The summary already written is sent with the words | An update is a rewrite of one text, so it keeps what is still true instead of reading the whole call out again | `LiveChatRunner.summarize` |
| The summary and the window's questions share one model, started on first use | Loading a 4B model takes seconds, and a summary every minute would pay that cost every minute | `LiveChatRunner` |
| A failed pass is a log line, never a failure of the call | The words are still on screen and the next interval tries again | `LiveTranscriptSession.summarizeIfWorthIt` |
| The step is the person's choice, and separate from the brief | The window is a reading aid and the brief is the record; wanting one and not the other is normal | `AppSettings.summarizesLiveCalls`, `liveSummaryInterval` |

### The empty window of 2026-09-21

A recording that started at 14:02 showed "Listening", a green `Live` chip, and "Nothing said yet" for
fifteen minutes while the timer ran. The cause was the order of two calls:
`AppModel.beginRecording` asked for the audio tap before `beginLiveSession` started the session, and
`LiveTranscriptSession.makeTap` returned nil unless a reader already existed — which it did not until
`start()`. No tap meant no audio, no chunk files, and no text, while the model server started anyway,
which is why the window looked healthy.

Evidence: the call's folder held only the two `.*.partial.m4a` files with no `.live` folder beside
them, and the `live` log category had no lines for the length of the call.

The reader is now built in `init`, so a tap exists from the moment capture opens and the reader
queues what arrives before the model is up. `LiveTranscriptSessionTests` pins it: the tap is handed
over before anything is started, and a Mac without whisper.cpp gets no tap and a sentence instead.

## 13. An ending read from the wrong state (2026-09-22)

The 13:18 call showed "Recording finished" and a muted "Not live" chip in the window twenty seconds
in, over a panel that counted the seconds and offered Pause and Stop. The window held no words, and
the call's `.live` folder went on filling with chunks that nothing read.

The cause was the rule that ends the live path. `AppModel.apply` read the state the reducer handed
back and released the live path whenever that state was `idle` or `failed`. A manual start publishes
two events of its own — the microphone state, then the start — and the first of them leaves the
phase `idle`, so the live path was released on the way into the call instead of on the way out of
it.

Evidence: the call's folder was created at 13:18:20 and its `.live` folder at 13:18:37, with the
first chunk inside it at 13:18:37. The session that would have read those chunks was released before
the folder existed, which is why the release deleted nothing and why the `live` log category held no
lines for the whole call.

| Rule | Why | Where |
| --- | --- | --- |
| The live path is held by `recording` and `paused` | It reads the same audio the recording writes, so it lives exactly as long as the capture does: `finalizing` is a capture that has already closed | `RecordingPhase.holdsLiveTranscript` |
| The live path ends when a phase that holds a call gives way to one that does not | A start reaches `recording` after its own bookkeeping, so the events of a start answer false here | `RecordingPhase.endsLiveTranscript(from:to:)` |
| The model reads the move between two phases, never the phase that comes back | The state a reducer returns says where the recorder is, not whether the call just ended | `AppModel.apply` |
| A live path released while the capture still runs reports a problem | The window must never read like the end of a call that is still recording, and nothing in the log said the path had gone | `AppModel.finishLiveSession` |

`RecorderReducerTests` pins the rule: "the events of a start do not end the live path", "the live
path outlives a pause and a resume", and "the live path ends when the call stops being recorded".

## 14. A crash on a microphone buffer the tap could not read (2026-09-23)

Two automatic recordings ended the process on 2026-09-23, at 11:31 and 13:01, four to five seconds
in. Both crash reports hold the same fault: `EXC_BAD_ACCESS`, `KERN_INVALID_ADDRESS at 0x0`, inside
`-[AVAudioPCMBuffer initWithPCMFormat:frameCapacity:]`, on the thread
`local.callrecorder.capture.microphone`.

The symbols lead to the live tap: `LiveAudioTap.copyOf` at line 242, called from `LiveAudioTap.append`
at line 96, called from `AudioCaptureRouter.stream(_:didOutputSampleBuffer:of:)` at line 45. The line
that named the shape came from a later call that ran: `live audio skipped a microphone buffer the tap
could not read: rate 48000, channels 3, bits 32, flags 9`. A browser call hands the microphone over as
three-channel interleaved packed float, and `AVAudioFormat` has no form for interleaved audio above two
channels.

Two probes pinned the halves of the fault. `AVAudioFormat(cmAudioFormatDescription:)` returns a format
with no channels at all for a LinearPCM description that carries no channel count, and
`AVAudioPCMBuffer(pcmFormat:)` ends the process on that format instead of failing. So the old code
reached the initializer with a buffer it could not describe, and the call died on a microphone buffer
the app never needed to lose.

| Rule | Why | Where |
| --- | --- | --- |
| Never build an `AVAudioFormat` from a CoreMedia description | It returns a format with no channels for a description that carries none, and `AVAudioPCMBuffer` ends the process on that format: a shape that cannot be read has to be refused, not crossed | `LiveAudioTap.format(from:)` |
| Describe a buffer from its stream description, and refuse what the type cannot hold | Rate zero, no channels, and layouts the app does not read are cases for a skip with a log line, not a crash | `LiveAudioTap.format(from:)` |
| Average the channels of an interleaved microphone above two | The three channels of a browser call carry different energy, so reading one of them loses voices; the mean keeps all of them | `LiveAudioTap.downmixed(_:stream:frames:)` |
| A buffer the writer cannot describe is dropped and counted | A throw from `append` cancels the whole side in `AudioCaptureRouter`, so one unreadable buffer would cost the call its audio | `AudioSampleWriter.append`, `droppedSamples` |
| One log line per call, not per buffer | Microphone buffers arrive about fifty times a second, and a line each would bury the log | `LiveAudioTap.noteUnreadableFormat`, `AudioSampleWriter.noteUnreadableFormat` |

The guard for the shape that crashed went in at 13:15, and the automatic call that followed logged the
three-channel skip once and ran on. The complete fix — the stream-description reader and the downmix —
ships as 0.1.19.

`LiveAudioTapTests`, suite "Live audio tap format", pins the shape: a description with no rate and one
with no channel are refused, a buffer with no channel is skipped instead of becoming a frame, a buffer
with no usable format does not cancel the side it belongs to, and three channels of `[1, 0.5, 0]` write
a chunk whose peak is 0.5 — a number only a true mean reaches — converted to 16 kHz mono.
