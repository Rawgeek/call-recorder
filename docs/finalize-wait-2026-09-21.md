# Why the app sat at "Writing the audio file" (2026-09-21)

The popover said **Saving Audio — Writing the audio file** for nine minutes after a call ended. Two
separate things were wrong, and only one of them was about writing audio.

## 1. Nothing was writing: the capture stop never answered

Evidence, in the order it was taken:

- The call's folder held only the two `.partial.m4a` files, last written when the call ended.
- `lsof` showed the app still holding both of them open, and `sample` showed two idle CoreMedia
  writer threads per file (`formatwriter.qtmovie`, `mediaprocessor.audiocompression`).
- No `ffmpeg` process was running, and the call row in `calls.db` still said `recording`.
- `ffprobe` on either file: *moov atom not found*. An m4a written this way carries its index only
  in `finishWriting`, so an hour and twelve minutes of audio was on disk and unreadable.

`AppModel.stopRecording` asks `AudioCaptureSession.finishSegment` for the last segment first, and
that call waits for `SCStream.stopCapture()`. That answer never came, so the writers were never
finished and nothing else in the stop path ran.

**Fixed**: the stop is raced against a 15 s timer. When the timer wins the segment is closed
anyway, which writes the index of everything already recorded; the cost is the tail of the call.
The failure is logged as a notice.

## 2. The work it does when it does run was mostly waste

The finalize step had three costs, and the transcript needs none of the last two:

| Step | Cost for 6 minutes of one track | For the 72-minute call |
| --- | --- | --- |
| Decode the track into a PCM wave | 0.44 s, 66 MB written | ~5 s, ~800 MB |
| Encode that wave back to m4a | 5.53 s | ~66 s |
| Mix both sides into `call.m4a` | ~6 s | ~70 s |
| **Remux the track as it is** (what it does now) | **0.06 s** | **~1 s** |

Two causes:

1. The cheap path — remux instead of decode-and-encode — was taken only when a track's duration was
   known, and a finished recording arrives without durations, because `SegmentSnapshot` carried
   only URLs. Every normal call therefore took the wave path.
2. `call.m4a` was written before the call was queued, and the pipeline never reads it: the
   transcriber reads `system.m4a` and `microphone.m4a` apart, and the diarizer reads the system
   side. With the default settings the file was then moved to Recently Deleted with the rest of the
   audio, unread.

**Fixed**:

- `SegmentSnapshot` carries each side's start and duration, and a single source is copied whenever
  it can be, whatever the durations say.
- `MediaFinalizer.finalizeTracks` writes the two sides and stops there;
  `writeCompatibilityMix` is the separate, expensive step.
- The mix is written by the tidying stage (`finalizingArtifacts`), after the transcript exists, and
  only when the person keeps the audio. A call whose audio is removed stores the recorded side in
  `audioPath` instead of a file that is about to be deleted.
- Guards that asked whether the *mix* exists now ask whether the call's audio is on disk
  (`AppModel.audioIsOnDisk`): the mix is one file inside a folder that also holds the sides.

## What is still open

- A crash or a force quit during a recording still costs that recording, because the writers are
  never finished and an m4a without its index cannot be read. Writing fragmented (`moof`) output
  would fix it, but `movieFragmentInterval` was set on the `.m4a` writers and produced no fragments
  in a test, so it was reverted rather than shipped on trust.
- The 2026-09-21 14:02 call cannot be recovered by the app. Its frames are on disk with no sample
  table, and the encoder's frame sizes vary (437 distinct sizes in a reference recording from the
  same app), so the boundaries cannot be reconstructed without a decoder-assisted search.
