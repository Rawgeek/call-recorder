# Pitfalls this app has already paid for

Every entry here cost a debugging session, and most of them cost more than one. They are written
down so that the next person to meet the same shape recognises it in a minute instead of an
afternoon, and so that a change which looks harmless is seen against what it broke the first time.

The rule at the end of each entry is what the session bought. It is not a suggestion.

## Building, signing, and permissions

### A bundled app does not inherit the shell's environment

`ffmpeg` and `ffprobe` were installed with Homebrew and on the `PATH` of every terminal on
the Mac. The app, launched from Finder, reported them missing at the start of every recording,
which reads in the panel as "ffmpeg and ffprobe are required to save recordings" while both are
installed and working.

A bundled app is started by `launchd` with a minimal environment. `/opt/homebrew/bin` is not
on it, and nothing the app spawns can put it there without guessing.

**Rule:** find an external tool by probing the directories it is installed to, in order, and name
the copy that was found. Never resolve one from `PATH`. See `ToolLocator`.

### A permission belongs to the signature that asked for it

The microphone, Screen Recording, and the keychain trust a specific signed copy. After a rebuild
with a new signature, the switch in System Settings is still on and the app still gets nothing:
the grant was made to a copy that no longer exists. The shape is "it is already enabled and it
still asks for permission", and the answer is always that the app is not the app that was granted.

**Rule:** after changing how the app is built or signed, re-grant the permissions before
concluding that the permission code is broken. Keep the app's identity stable between builds when
possible, and ask for each permission explicitly rather than reading a switch that may be stale.

### A refused permission is not a capture that went wrong

ScreenCaptureKit reports a missing Screen Recording grant as a stream error, and the sentence it
carries names no permission and no way to grant one. A recording that failed this way read as the
app being broken, and the card that names the permission never appeared, because the flag behind it
started as granted and nothing ever read it from the system.

**Rule:** read the grant with `CGPreflightScreenCaptureAccess` when the app starts, and treat the one
error code that means "declined" (-3801) as a fact about the permission rather than a capture
failure: say what is missing, keep the framework error in the diagnostics, and leave the recorder
idle -- or paused, when the refusal arrives on a resume -- so no audio is thrown away.

### Signing asks for the keychain, once per session

`codesign` needs the signing key unlocked. A locked keychain turns a packaging run into a
password prompt, which is a wall for a build that is meant to run unattended.

**Rule:** unlock the login keychain once, then package. `scripts/package-app.sh` prints that
line when it fails, and an unsigned build is available for a layout check.

### The microphone detector sees the recorder itself

Automatic recording looks for *another* app holding the microphone. The recorder's own capture
holds it too, so a detector that asked "is anything on the microphone" would restart the
recording it is in the middle of, for ever.

**Rule:** exclude the app's own process identifier before asking the question. See
`AudioActivityDecision`.

### More than meetings open the microphone

A voice memo, a dictation, and the system assistant all hold the microphone, and each of them
started a recording that had to be thrown away. In the other direction, a call app can keep the
microphone open after the meeting ends: one library holds fifteen hours recorded that way, in
three recordings nobody asked for.

**Rule:** a recording the app starts by itself is thrown away below a floor, stopped at a ceiling,
and never started for the devices a person talks *to*. A recording started by hand is exempt from
all three. See `AutomaticRecordingRails`.

### A headset microphone drops to call quality

A Bluetooth headset switches to the hands-free profile the moment its microphone opens, and the
audio of the meeting that follows is narrowband. It is the microphone people choose for a reason,
and it records a meeting worse than the built-in one.

**Rule:** say so in the microphone row, and name the system's current input rather than pinning
one silently.

## Packaging, releases, and updates

### The app is not at the root of its own archive

An archive made by the Finder, by `ditto`, or by a release pipeline wraps its contents in a
folder whose name nothing the app can see controls. An updater that looked for the bundle at the
archive root found nothing, and reported a release it could not install.

**Rule:** walk the unpacked archive for the bundle, then verify what is inside it: identifier,
version, build, and signature. The name of the folder is not evidence.

### Two archives of one tree had two hashes

The runtime archive was rebuilt from an unchanged tree and came out with a different SHA-256,
because the entries carried their file times and were written in whatever order the file system
returned them. Every launch after an update fetched and unpacked all 36 MB again.

**Rule:** an archive that is compared by hash has to be byte-for-byte reproducible: flatten the
times, sort the entries, and check that building the same tree twice produces one hash.

### A part-finished file whose extension is not last

The clip cutter wrote its part-finished file as `clip.m4a.partial`. ffmpeg chooses a container
from the last extension, so it refused to write the file at all and no clip was ever cut.

**Rule:** the extension a file is read with goes last, whatever else the name carries. See the
`partial.m4a` names in `ModelManager` and `MediaFinalizer`.

### The app cannot replace itself while it runs

An update has to move the running bundle aside. macOS holds the executable open, and the swap
fails in the one moment it matters.

**Rule:** download and verify while the app runs, and swap at quit, which is the moment nothing is
using the bundle. Keep the version that was replaced, and repair a swap that was interrupted
between its two renames.

### CI runs on a push, not on a tag

The workflow starts on a push to `main`, on a pull request, and on demand. A tag starts nothing,
so a release published from a tag carries a commit that nothing built or tested.

**Rule:** publish a release from a commit the push workflow has already built and tested. The
workflow also cancels a run a newer push has replaced, which is what keeps a day of small commits
from queueing a day of runners.

## Capturing

### The audio writer is not finished until it is finished

A recording in progress is an AAC file with no index. Read before its writer closes it, its length
is zero and its frames are unreadable. Every stage downstream -- mixing, diarization, transcription
-- then sees nothing, or an error that names the wrong thing.

**Rule:** nothing reads a segment until its writer has closed it. Finalisation is a stage with its
own state, and a call that reached it is never left looking as though the audio never arrived.

### A child's output read through a pipe is a race with a clock on it

Diarization read its script's standard output through a pipe, on a thread the parent then waited
five seconds for after the script had exited. On a busy machine that thread could still be waiting
to be scheduled when the five seconds ran out, and a run that had failed for a real reason --
"No Hugging Face token found" -- was reported as an empty output instead. The error sent a reader
to the wrong place, and the fault the script had described was thrown away.

**Rule:** send a child's streams to files and read them after it exits. There is nothing to wait
for, and a file cannot be truncated by the reader being late. Every command this app runs does
this; the diarizer was the one that did not.

### An empty microphone track is not an empty call

The two sources are captured separately, and one of them can be silent for a whole recording: a
muted microphone, a call where only the other side spoke, or a device that was not there.

**Rule:** warn on a one-sided call rather than treating it as a fault, and never judge a call by
one source.

### A missing microphone is one source fewer, not a failed recording

A Mac mini has no audio input at all. The capture resolved the microphone first and refused when it
found none, so a machine that could record the other side of every call perfectly well recorded
nothing, and the error it produced named a device the person never had.

**Rule:** treat the microphone as an optional source. ScreenCaptureKit records the system audio on
its own, the segment manifest already allows one track, and the finaliser already accepts one. The
refusal is kept behind a setting for the Macs that do have an input, and a device plugged in later
is picked up by the next segment.

## Transcribing

### Whisper answers silence with words

Over music, a tone, or nothing at all, the model does not return nothing. It returns the phrases
it was trained to see printed next to no speech: "Thank you for watching", "Продолжение следует",
the word for music in brackets, and a count from one to ten. The library held 174 lines of prompt
echo, 271 bracketed markers, and 383 lines of one repeated sentence before these were measured.

**Rule:** judge a line by what it is, not by how often it appears. A prompt echo has the shape
`TERM (also TERM)`, a marker is a bracket that fills a line, and a loop is a long line repeated
many times. See `TranscriptArtifacts`.

### The same sentence reaches the model twice

Transcription runs in five-minute chunks that overlap, so the last words of one chunk are also the
first words of the next, and a microphone that hears the speakers writes the meeting down a second
time. One call in the library held 473 repeated runs; across four calls, 17.2% of the words were
said twice.

**Rule:** remove a repeat only when it is the same words, at least five of them, close by, and
keep the first copy. A word the model heard differently is left alone, because choosing between
two spellings is how a transcript stops being a record. See `TranscriptDeduplicator`.

## The library

### One database file, two writers

The app and the MCP server read the same local database, and a save from one arrived while the
other was writing. What the person saw was a foreign key constraint, which names neither of them.

**Rule:** one writer. A change asked for through MCP is queued as a request and applied by the
signed app, so the library has a single author and every change has somewhere to be undone.

### Nothing is deleted before what it produced is verified

The working folder of a call was removed once its transcript was promoted. When the order slipped
-- a cleanup that ran before the participant screen, a repair that ran before the file was written
back -- the recording was gone and the transcript had never been written.

**Rule:** a delete runs after the artefact it exists to produce is on disk and verified, and it
moves what it removes somewhere it can be brought back from. Audio goes to Recently Deleted for a
day; a recording that was discarded goes to the same place rather than to nothing.
