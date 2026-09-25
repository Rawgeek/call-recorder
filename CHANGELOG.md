# Changelog

All notable changes to Call Recorder are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions use semantic
versioning.

## [0.1.32] - 2026-09-25

A stage that another pass takes the call away from is written down as superseded instead of being
reported as a failure, so a call that finished keeps looking finished.

### Fixed

- **A stage that loses its claim is superseded, not failed.** Naming a voice rewrites the saved
  transcript, and saving a transcript queues the call's indexing stage again and clears the claim
  the processing loop holds. The stage that was running then fails over a call that is already back
  in the queue: the 2026-09-25 16:21 call was named a voice while its finalizing stage ran, the
  stage threw "ArtifactRecoveryError.callNotReady", and the store refused the failure because the
  claim was gone, which rolled the record back with it. The only trace was an error line over a call
  that was ready four seconds later, and that error line is what the fault watcher woke on. The run
  is now written down as a warning that names the stage and the stage the call moved to, and a
  failure the store refuses to record is no longer logged as one.

## [0.1.31] - 2026-09-25

A voice the separation heard and the transcription wrote no word against is dropped instead of
asked about, and the audio it held is let go with it.

### Fixed

- **A voice with no words is dropped, and is not a question.** The 2026-09-25 16:21 call carried a
  voice of 52 seconds that the separation heard and the transcription wrote nothing against: its
  card said "Transcript sample unavailable", and the only answers on it were a guess and Keep
  Anonymous. The user answered it by hand and asked for voices like it to be dropped, and an
  unanswered voice also holds the call's audio while it waits for an answer nobody can give. Each
  pass now drops the voices of its own separation that no word of the call points at, which is read
  from the labelled words of the same pass, and a voice that was named keeps what was learned from
  it: the sample belongs to the person, and only the reference back to the dropped fragment goes.

### Changed

- **A pass that labelled no word at all drops its voices before it reports the fault.** The voices
  are created before the words are attributed, so a pass that could not label one word used to leave
  them behind for the review window to ask about. They are dropped now, and the fault is reported
  the same way, so a retry starts from the voices it finds rather than from the ones it left.

## [0.1.30] - 2026-09-24

The picture names a voice by what the user named it and by nothing else, and the person recording
gets the one row that says which words of the call are theirs.

### Fixed

- **A voice waiting to be named is drawn by its number, not by a name off its own lines.** Moving
  one line of a voice onto a person is not naming the voice. The row of the 21-minute voice of the
  2026-09-23 14:16 call read "Alexey Ponomaryov" while the card under it read "Speaker 1", because
  five of that voice's lines had been moved onto him by hand; the user read the two names as one
  voice and asked for it to be named after himself. A row now takes a name only from the store's
  decided voices, and a voice the store still holds as a question keeps its number, which is the
  number its card carries.
- **Moved lines no longer count their voice as named.** The same call's header read "11 of 11
  named" beside a button that read "1 to name", for the same five lines. The count of named voices
  reads the store's waiting voices as unnamed, so the header and the button agree.

### Added

- **The person recording has a row of their own.** The picture drew the voices the separation
  found and dropped the microphone track, so the user's own words had no row: on 2026-09-24 he read
  his own speech out of the remote voice whose bars run under it and asked for that voice to be
  named after him. The microphone track carries no voice number and does carry the name the app
  knows, and it is drawn named, with its turns as the bars to jump to. It is the one row that is not
  a question: nobody has to name the person recording.

## [0.1.29] - 2026-09-24

A voice on the picture carries one number wherever it is read, the samples are ready for every voice
the picture draws, and a stage stopped while its claim is already back in the queue no longer ends
the processor loop.

### Fixed

- **A voice clicked on the picture has its samples.** The window loaded the samples of the voices
  still waiting to be named, and a voice named on an earlier pass has no card until it is clicked.
  The card it gets then said "Loading samples…" and nothing ever loaded it, which is what it did on
  the 2026-09-24 calls. The samples of every voice the picture draws are loaded now, by the same
  rule that builds the picture, so a row and the card it opens cannot disagree about which voice
  they are.
- **One voice, one number.** The picture numbered a voice by its place, the card under it by the
  separation's own label, and the transcript counted from one. A real call made all three disagree:
  the first voice of the 2026-09-23 14:16 call carries the label SPEAKER_07, so its row read
  "Speaker 0" and the card opened from it read "Speaker 7", while the transcript said "Speaker 1".
  Every surface now writes the number the transcript writes, which is the voice's place plus one,
  and the stored label stays what it always was: the separation's internal name for a voice.
- **A stopped stage whose claim is already back in the queue no longer ends the processor loop.**
  The surface that stops a stage puts the claim back in the queue, and the stage then ends itself;
  the loop asked the store to put that same claim back a second time, was told no row was running,
  and threw that out of the loop, which ended the drain and logged "Processor loop failed" over a
  call that was exactly where it belonged: the 2026-09-24 report. The same is true of a stage that
  fails after its claim has gone, which a transcript rewrite causes. Both are reported and the loop
  goes on, and the surface that stopped the work is still told.

## [0.1.28] - 2026-09-24

The picture of a call draws every voice the call holds, and clicking one opens that voice directly
under the picture: its samples, its picker, and the way to change a name that is already there.

### Added

- **A voice on the picture is a control.** Clicking a row's name, or any bar that voice owns, opens
  its card as the first card under the picture: the samples to listen to, the participant picker,
  and Confirm or Keep Anonymous. The row and the card carry the same stroke, so the voice that was
  clicked is the voice being answered. A voice named on an earlier pass had no card at all, so a
  name on the picture could not be corrected from the picture: a card is built for it where it was
  clicked, and it offers **Reassign** and **Return to review**, which takes the name off the voice
  and puts it back among the voices waiting to be named.
- **Twelve rows of the picture are on screen at once, and the voices past them scroll.** The picture
  drew the first eight voices of a call and left the rest off it entirely, which is how two voices
  waiting on a name were missing on 2026-09-24 from a call that held sixteen of them, and how one
  of them could not be given a name from the window that exists to name it. Every voice of the call
  now has a row, and the overview strip and the playhead still cover the whole call.

### Changed

- **A sample plays the call's recording, not a clip cut out of it.** The cards and the picture share
  one player, so pressing play on a sample moves the playhead onto the timeline and the words are
  heard where they were said. The sample also passes over what is not the voice's: a voice speaks at
  minute five and again at minute nine, the four minutes in between belong to whoever spoke in them,
  and the playhead moves to the voice's next turn instead of playing through it.
- **The renderer can draw a voice clicked, and the review window at any height.** A click comes from
  a pointer and an off-screen render has none, so the environment variable
  CALL_RECORDER_CLICKED_VOICE=<speaker index> draws the seeded call with that voice selected.
  CALL_RECORDER_SNAPSHOT_SIZE now sizes the review window as well: its page is taller than the
  window on any call with more than a few voices, so the cards under the picture were outside every
  picture that had been taken of it.

### Fixed

- **The seeded review card plays the recording it names.** The card a render builds resolved the
  call's audio from the folder the call's markdown sits in, and that markdown is written beside the
  call's folder as well as inside it: the card offered play buttons on samples of a recording it
  could not open, and the player row said so. It is resolved from the call's own folder, which is
  how the window resolves it.
- **The invented call a render draws has people on it.** The invented cast was seeded before the
  metadata load that replaces it, so the invented call's voices had nobody to be named after and
  every one of them drew as waiting, which is the one state of this window that explains nothing.

## [0.1.27] - 2026-09-24

The model that writes a brief and answers questions about a live call is told how much prompt cache
it may keep, because llama.cpp's own default for that cache is eight gigabytes of RAM.

### Fixed

- **The model server behind the live window no longer grows to eight gigabytes on a long call.**
  llama.cpp's server remembers the state of every prompt it has processed, so a later prompt that
  starts the same way is restored rather than read again, and it will spend up to 8192 MiB of RAM
  doing that: its own default, which this app never asked for. The live window holds one server for
  a whole recording and sends it a prompt every ninety seconds, so on 2026-09-24 that cache filled
  over the first hour of a call. The server's physical footprint was 3.7 GiB sixteen minutes in and
  9.0 GiB at the hour, where it stopped moving; 8.1 GiB of it was host heap, and a Mac with 68 MB of
  free pages pushed it into swap. Thirty-three requests had left entries of 230-330 MiB each, and
  the log said so: "making room for prompt cache entry, removing oldest entry". The server is now
  started with a 512 MiB ceiling, which holds the one entry a summary update and a question trade
  between them, and it is asked for as `LLAMA_ARG_CACHE_RAM` rather than as `--cache-ram`, because a
  llama-server older than that option ignores a variable it does not know and refuses to start on an
  argument it does not know.

## [0.1.26] - 2026-09-24

A keychain dialog answered with Cancel is read as a decision rather than as a fault, and the calls
that were waiting on that key are asked about again the moment it is read.

### Fixed

- **A cancelled keychain dialog is no longer recorded as the app's last error.** The keychain
  answers -128 when the person presses Cancel in the access dialog, and the app treated it the way
  it treats a locked keychain or a refused password: the error was written to the diagnostics
  record, kept as the app's last error, and shown as a fault. Nothing is broken when a dialog is
  cancelled, the key stays where it was, and the next attempt asks again; the state now says the
  keychain has no answer yet, which is what is true, and the surfaces offer the same Try Again.
  On 2026-09-24 a cancelled dialog woke the fault watcher this lane runs on, which is built to wake
  on faults and not on choices.
- **A call that could not be separated while the key was locked finishes once the key is read.**
  The separation needs the stored voice profiles to name the voices it finds, so while the
  keychain had not answered it failed the call outright: the 2026-09-24 11:13 call was refused
  five times over half an hour, and when the key was read thirty seconds later nothing asked again,
  so a call whose only problem had been a locked keychain stayed failed. Reading the key is the
  moment that reason goes away, so it is now the moment the calls that failed for want of it are
  queued again. A call that failed for its own reasons is left alone: the record of the failure is
  what says which of the two it was, and guessing would start work nobody asked for.

## [0.1.25] - 2026-09-24

A recorded call is read by Parakeet, which reads Russian and English in one pass on the Neural
Engine, and whisper.cpp is kept for the languages it was not trained for.

### Added

- **Calls are transcribed by Parakeet TDT 0.6B v3.** One pass reads a call that mixes Russian with
  English product names without being told which language it is in, which is the call this app
  meets every day. The model runs on the Neural Engine, and it reads the file the recorder wrote
  itself. Measured on this Mac through this app's own reader: a four-minute thirty-six second
  recording of English speech is read in 2.4 seconds, after a model that loads in 0.2 seconds.
  whisper.cpp reads the same file in 16.2 seconds. Twenty-five European languages are read this
  way, Russian and Ukrainian among them.
- **The engine is a setting.** Settings, Models, Components names it, and the row says which engine
  would read the next call rather than which one was asked for, because a setting that cannot be
  honoured falls back instead of failing the call: a language Parakeet was not trained for, or a Mac
  whose Parakeet model has not been downloaded, keeps reading with whisper.cpp and says so in the
  row. This is the engine that reads the saved transcript; the live window beside a recording still
  reads with whisper.cpp.
- **The Parakeet model is a download, not part of the app.** Four Core ML graphs and a vocabulary,
  fetched from the publisher into the folder the other models live in, with the fraction that has
  arrived shown in the row while it runs. Deleting it gives the space back and falls the app back on
  whisper.cpp.

### Changed

- **A recording is no longer cut into five-minute pieces before it is read.** The pieces existed
  because whisper.cpp reads one at a time; Parakeet takes a file of any length and holds a constant
  amount of memory while it does, so the turns of a transcript are no longer decided by where a
  piece happened to end.
- **Nothing is written to disk to read a call.** The wave file converted with ffmpeg and the chunk
  files beside it are whisper.cpp's requirement, not the reader's: the track the recorder wrote is
  handed over as it is, resampled and mixed by the model itself.
- **A recording that holds nothing reads as no words rather than as a fault.** A muted microphone
  and a room with nobody in it land on the app's own "No speech" answer, which is what whisper.cpp
  with its silence filter already produced. Words the reader could not give a time stay a fault,
  because nothing honest can be placed in the call with them.
- **The whisper model file is needed only by the engine that will read the call.** A Mac that
  switched to Parakeet and gave the whisper files their space back still transcribes; one that kept
  the engine on whisper without a model is told before the call is claimed for work that could not
  finish.

## [0.1.24] - 2026-09-24

The voices of a call are drawn against its recording, so naming one starts with hearing it: a row
per voice on a timeline, a bar for every stretch that voice spoke, and a click that plays the bar.

### Added
- **The review window draws a call's voices on a timeline.** One row per voice, in the order the
  voices were first heard, with the ruler of the recording above them and a playhead that moves
  while it plays. A row is the whole call, so a voice that spoke twice is two bars, and the pause
  between them is a pause: turns shorter than a quarter second are left out, and a gap under a third
  of a second is joined. Those are the two rules the separation itself writes with, so the picture
  agrees with the words beside it. A voice whose every turn is a fragment keeps its longest one,
  because a row that vanished would be a voice the user cannot see, place, or name.
- **The recording plays from the timeline.** A click on a bar plays that bar, a click anywhere else
  moves the recording there, and the position row above seeks on a drag. A Follow switch keeps the
  playhead on screen, the way the live transcript already does, and a scroll of the user's own turns
  it off rather than pulling the view back while they are reading.
- **The timeline zooms and pans.** Fit shows the whole call at once, and the minus and plus
  controls, a pinch, or a drag on the overview below move into the part being listened to. The
  overview is the whole recording in miniature, with the part on screen marked on it.
- **One colour follows one voice.** A voice is the same colour on its bar, on the chip that names
  its row, and on the card that names the voice, so the voice being named is the voice that was
  heard.

### Changed
- **A render of the review window no longer needs a recorded call.** The renderer could only draw
  the window's cards from a call the store already held, so a preview home that had never recorded
  one drew "Nothing to review" over the layout being looked at. The seed invents the call it draws
  and writes nothing down.

## [0.1.23] - 2026-09-24

The voices of a call are named by Nemotron 3, which counts them in seconds where the older separation
took minutes, and the voice prints the library is taught with are measured by the same embedder as
before, so the people already named keep matching.

### Changed
- **The separation is answered by Nemotron 3 Diarization.** The older separation read a call twice
  over, through a segmentation model and then an embedder, and on this Mac ten minutes of a
  two-voice call took 57 seconds of that. Nemotron answers who spoke when in one pass: the same ten
  minutes come back in 24 seconds, and it holds no count to be told. On a system track that was
  written and holds no sound, and on thirty seconds of digital silence, it answers no voice at all,
  which is the failure the previous release met with a guard, and the guard now has nothing to
  guard.
- **A voice print is still measured by the pyannote community-1 embedder, and its name is
  unchanged.** A voice print is only compared with one stored under the same name, and the embedder
  did not change -- only the moments it is asked about. Measured against the older separation on the
  same calls, one voice's print from its turns and from the older turns is 0.986 to 0.999 alike, and
  two different people are 0.10 to 0.56 alike, so a person confirmed on an older call is still
  matched on a call recorded today: the acceptance threshold is 0.82 and the review threshold 0.68.
- **The number of voices on a call still picks the count-aware separation, and that setting is now
  off by default.** Only the older separation can be held to a number, and it is the slower one, so
  a call is separated by the turn model unless the count is asked for: with the setting on, the
  people on the call decide how many voices are separated, and a number counted in the review window
  is answered exactly, both as before.

### Added
- **A call longer than twenty minutes is separated in eight-minute windows, and one voice keeps one
  name across them.** The turn model's cost grows with the square of the length it is handed:
  a seventy-minute recording built from two recorded calls took 4.3 GB of memory in one piece and 80
  seconds, against 2.0 GB and 79 seconds in windows, and the library holds calls of two and a half
  hours. The voices of one window
  are joined to the voices of the windows before them by the same rule the app already uses for two
  pieces of one voice. A voice that never talks alone for a fifth of one ten-second window is
  measured over every window it talks in, because a voice with no value cannot be joined to its own
  name and comes back as a second person: that alone turned 11 voices into 9 on the seventy-minute
  recording, whose older separation found 6.

### Fixed
- **A separation that answers no voice no longer fails the call.** The 2026-09-24 11:13 call is
  seventeen seconds long and its other side holds one short sound; the count-aware separation
  answered no voice at all, and the stage reported the call as failed rather than finishing it.
  Its words were already transcribed, so the call now finishes with the one voice that spoke, the
  same way a call whose other side was never captured already did. A separation that breaks still
  fails: a script that found nothing and a script that stopped are different answers.

## [0.1.22] - 2026-09-23

A call whose other side was never captured is finished with the words it has, instead of asking for
a separation that can only be given up.

### Fixed
- **A system track that holds no sound is not a side to separate.** The 2026-09-22 13:44 call had a
  microphone track and a system track that was written and held nothing; the only thing the other
  side left in the transcript is one period at 104 seconds. pyannote found a single voice on that
  track and its centroid came back empty, which ended the pass -- six times, four days apart -- so a
  call whose words were already transcribed could never be finished. The size of the track is what
  says it carried no sound, which is the same rule the row's "one side only" note uses, and a
  remote fragment too short to hold a turn of its own is not a voice to name. The call now finishes
  with the one voice that spoke, and its audio is cleaned up like any other finished call.
- **A fragment too short to hold a turn no longer asks for a separation.** The list of calls that
  need speaker detection counted every remote word with no voice over it, including a fragment that
  no separation would ever label. Such a call stayed in the list with a Retry that could answer
  nothing. A remote piece longer than two seconds is a turn waiting for a voice and still counts;
  anything shorter is passed by, as the separation itself already passes it.

## [0.1.21] - 2026-09-23

A repair the queue already holds is an answer, and one voice the model cannot measure no longer ends
a call's separation.

### Fixed
- **A speaker retry on work that is already on its way is no longer kept as a failure.** The store
  refuses a second request while a pass is queued or running, which is what keeps a retry from
  interrupting work in flight. The window reported that refusal as an error, so "Retry Speaker
  Detection" on the 2026-09-18 14:01 call stayed as the app's last error for five days while the job
  it named finished on its own on 21 September and the call came out fine. The retry now says the
  voices of the call are already being separated, and it goes ahead as before once the work has
  stopped. The repair that runs at launch reads the same answer the same way, so a queued job there
  is no longer reported as a launch failure.
- **A voice pyannote cannot measure no longer ends the whole separation.** pyannote returns a
  centroid of the wrong size, or one holding a value that is not a number, for a voice it heard too
  little of. Raising on it ended the pass, so the 2026-09-22 13:44 call stood at the speaker stage
  for five attempts, every one of them stopped by a single such voice. The voice is passed over
  instead: its turns stay in the transcript and it can be named by hand, which is what already
  happened for a centroid of no length. Only matching that voice to a person is given up, and the
  app logs how many voices a pass could not measure.

## [0.1.20] - 2026-09-23

A call is kept when the only thing wrong with it is a line the cleaning pass could not have touched.

### Fixed
- **Six "да" in one breath are speech, not a decoder loop.** The repetition guard, which exists to
  stop a call being saved full of one phrase the model could not stop saying, counted every start
  position of a phrase instead of the copies a person would say. Six "да" in a row held four
  overlapping three-word runs and 53% of the line, so the guard refused it -- and the cleaning pass
  it is measured against removes copies that sit end to end, so it could remove none of them and the
  line stayed exactly as it was. On 2026-09-23 the 68 minute call that ran from 14:16 to 15:24 failed
  transcription twice on one such line in the system track, and its transcript was never written at
  all. Copies are now counted the way they are taken out: the same line holds three pairs end to
  end, under the floor, and the recording is transcribed. A word the model really does repeat
  eighteen times is six pairs end to end, and is still refused.

## [0.1.19] - 2026-09-18

The model that is already on disk keeps being used after the catalog renames it, so briefs keep
working across the 0.1.18 model change.

### Fixed
- **An installed model is read under the name it was downloaded with.** 0.1.18 moved the brief to
  Qwen3.5, which renamed both the repository and the file. The installed copy was looked for under
  the catalog's new names and found nowhere: the brief model was reported as not downloaded while
  2.5 GB of it sat on the disk, and the pane offered to download the same weights again under a
  name they never had. The installed record is what describes the copy on disk, so its repository,
  revision, and file names are what the app reads. The copy already there is used until the update
  is taken, and the pane's own "A newer copy is published" row is where taking it is offered.

## [0.1.18] - 2026-09-18

A name that was confirmed stays confirmed, and the brief of a long call is written by a newer model
and finishes the sections it starts.

### Fixed
- **A confirmed voice no longer comes back to review at every launch.** The repair that takes a
  person's name off a fragment that does not sound like them compared the fragments with each other,
  so a voice the diarizer split across two fragments was handed back at the start after every
  confirmation, and the hand-back deleted the voiceprint that confirmation had just stored. A
  voiceprint does not move when the same comparison is run again, so no answer could end the loop:
  the same voice was confirmed, returned, and confirmed again over two days. The repair now asks the
  question its own message states -- whether the fragment sounds like the person at all -- and it
  hands a fragment back once. The answer given after that stands until someone hands the fragment
  back by hand.
- **A call with many people on it is no longer cut off.** The brief of a long call is asked for
  under 150 words and was capped at 512 tokens, which a fifteen-person call reached: the saved brief
  stopped inside its last section, and one came back with a section heading and nothing under it.
  Every run measured at the new cap of 700 tokens finished on its own.

### Changed
- **The brief is written by Qwen3.5 4B**, quantised the same way the model before it was (4-bit
  Q4_K_M, 2.7 GB, Apache-2.0). On the call this was measured with, it read the transcript in 17
  seconds where the previous model took 30 and wrote its answer in 10 where that one took 13; its
  tokenizer spends about 15% fewer tokens on the same Russian, which is context and time both. The
  model reasons before it answers unless its template is told not to, so the request asks it not to,
  and a reasoning block that arrives anyway is removed before the brief is saved.
- **The prompt names the language of the call after the transcript**, not only in the rules above
  it. Handed a long Russian call and a sheet of English instructions, the new model answered in
  English: a translation nobody asked for, and the failure the language rule exists to prevent.
  Named in words, as the last thing read, it answered in Russian in every measured run.
- **A supporting model's row says which copy is installed.** The model's own version -- the size and
  the quantisation, which is what decides how much memory the run needs -- was written in the
  catalog and shown nowhere, so one download could not be read apart from another.

## [0.1.17] - 2026-09-18

The Models pane stops saying the host does not publish a file it does publish, and the runtime the
app fetches is published with the release.

### Fixed
- **The JavaScript runtime is published with the release.** The app does not carry the runtime: the
  bundle records the archive's hash and fetches it from a release of its own, named for those bytes.
  0.1.16 was published without that release, so the runtime download answered with a page that was
  not the archive, the Models pane said the download did not match the hash recorded when the app
  was built, and Retry asked for the same missing address. The archive is published now, and
  publishing it is part of the release: it is created when it is not there, and a release is not
  called verified until the runtime it fetches is published with the hash the bundle records.

### Changed
- **A small file is checked by the name the host publishes for it.** A host hashes what it publishes
  one of two ways: a large file carries a SHA-256, and a small file carries only the name it has in
  the host's repository, which is a hash of the contents too. The update check understood the first
  and ignored the second, so the embedding model, whose files include a config.json and a tokenizer
  configuration, was reported as one the host had stopped publishing, with no verdict possible for
  as long as it was installed. The app computes the same name for the copy on disk and compares
  them, which is a check of the contents rather than a size, and a copying update is verified the
  same way when it arrives.

## [0.1.16] - 2026-09-18

Calls recorded before briefs existed can be written up now, without recording them again, and the
panel stops keeping the room of a notice that has gone away.

### Added
- **Write a brief**, on the menu-bar row of any call that has a transcript and no brief yet. The
  button appears when the runtime and the model are ready, and the row shows the work while it
  runs. It is the same path the pipeline takes, so a brief written on request is the brief a call
  would have been given had it finished after the update.

### Changed
- **A development run keeps its voice-profile key in a file instead of the keychain.** Voice
  profiles are sealed with a key that lives in a keychain item, and the keychain decides whether a
  program may read one of its items by the program's signature: every rebuild is a new program to
  it, so starting a build from the build directory waited on a password dialog with nothing on
  screen to explain it. Those runs keep the key in a file only this account can read, inside the
  app's own folder. The file holds the key the installed app keeps in the keychain, because both
  programs read one library: the first development run that finds profiles already sealed copies it
  out of the keychain, which is the one question it asks, and every run after that reads the file.
  `CALL_RECORDER_VOICEPRINT_KEY=keychain` asks for the keychain throughout. The installed app keeps
  using the keychain.
- **Packaging signs ad-hoc unless an identity is named**, so building an app for this machine needs
  no signing key and no password. `scripts/release.sh --publish` names the release identity, so a
  published build is still recognised by macOS across updates and keeps the permissions it was
  granted.

### Fixed
- **The strip under the menu bar, when a notice went away.** The panel is sized once, from the
  tallest content it was shown, and it is drawn from the middle of the window it was given: the
  notice that reported older calls it could not read left its room behind as a gap, and the panel
  sat lower for as long as it stayed open. The panel now takes the height the content was measured
  at every time that height changes, so the room goes back when the notice does. The measurement
  has to come from the content: the panel's own content view reports a fitting size of zero, which
  is what the first attempt at this fix relied on and why it changed nothing on screen.

### Verified
- 648 tests pass in 83 suites. The request path shares the pipeline's transcript read, so it is
  covered by the tests that already cover the brief. The panel was measured on the machine the
  strip was reported on: with the notice it is 603 points tall, the notice goes, and it is 576 with
  its top edge in the same place.

## [0.1.15] - 2026-09-18

A release about reading less. A call now comes with a brief: what it was about, what was agreed,
who owes what, and what was left open, in the language the call was held in, written on this Mac
by a model that runs on this Mac. The panel also stops sitting a strip below the menu bar, and
clicking the app's own menu no longer turns it into a bar.

### Added
- **Briefs.** After a call is transcribed, a local model writes under a hundred and fifty words
  about it: the ticket numbers, the decisions and who made them, the tasks and whose they are.
  Settings -> General -> "Write a brief" turns it off; Settings -> Models downloads the model,
  which is 2.4 GB and is used for nothing else.
- **The brief travels with the call.** The menu-bar row marks a call that has one and copies it
  when the brief button is pressed, and the MCP server returns it from `get_call`, so a task that
  needs the call's context reads a hundred and fifty words instead of the whole transcript.
- **llama.cpp is named where it is needed.** The runtime that loads the brief model is found on
  PATH, its version is shown in Settings -> Models, and the row says what to install when it is
  missing: `brew install llama.cpp`.

### Fixed
- The menu-bar panel sits against the menu bar on a display whose menu bar hides itself. Its
  visible frame is the whole screen there, so the panel was placed against the top of the screen
  and drew over the bar; the row the icon is drawn in is the measure that is right on both kinds
  of display.
- The panel is placed again as it appears. The system places its own window while it comes on
  screen, which landed after the correction the app made, and left a strip between the bar and
  the panel for as long as it was open.
- Clicking the app's name in the menu bar no longer turns that menu into a bar. The fit walked
  every borderless window of the app, and an open menu is drawn in one of those.

### Verified
- 641 tests pass in 82 suites, twenty-five of them new: the words a brief is asked for in, the way
  a transcript is read without its header, the cut a long call is made at, the brief table and its
  replacement, the model host's own digests, the port the runtime is given, and the arithmetic the
  panel is placed with on a display whose menu bar hides itself.
- The brief was written by the real model on this Mac, through the same code the app runs: a
  fifteen-minute invented call came back in 7.4 seconds with the ticket number, the names, and the
  tasks in it, under two hundred words. The suite skips that test where the model is not installed.
- The panel geometry is measured, not guessed. The running app's panel was found at 65 points
  down a screen whose menu bar ends at 30, which is the strip: the numbers the fix is written
  against are the numbers the window server reports.

## [0.1.14] - 2026-09-18

A release about how many people were speaking. The detector counts voices on its own, and on a long
standup it counted one too many: fourteen remote voices came back as sixteen, and two of those
voices had to be named by hand with a name the transcript already used.

### Added
- **Settings -> General -> Separate voices by the people on the call**, on by default. The detector
  answers exactly the number it is given, and the count is the people on the call less the person
  recording. Measured on a real thirty-four minute standup: sixteen voices in a hundred and
  forty-four seconds before, fourteen voices in eighty-six seconds after, with no hand naming.
- **Review Speakers counts the voices of a call and can separate them again.** The number beside
  the count is used for that call ahead of the list of people, so a call that came out wrong in
  either direction - two voices where one person spoke, or one voice holding two people - is fixed
  from the window that showed the problem.

### Fixed
- The count is only asked for when the recording held room for that many voices to have spoken:
  fifteen seconds each. A two-minute call with fourteen people named on it is left to the detector,
  because a count that is too low writes two people into one voice, and that is the mistake that
  costs a transcript.

### Verified
- 616 tests pass in 78 suites. Nine are new: the count the app asks for on a standup, a small
  call, a short call, a call with one other person, no local participant, the setting off, and the
  floor measured against the number of voices rather than the length of the call - plus one that
  the count reaches the speaker script under the name it knows.
- The count was measured, not guessed. On the standup: sixteen voices in a hundred and forty-four
  seconds with the detector deciding, fourteen in eighty-six with the count. On a three-person
  call: four voices with two fragments with the detector deciding, exactly two with the count.
- Loose bounds were tried and do nothing: asking for between ten and sixteen voices returned the
  same sixteen as asking for nothing.

## [0.1.13] - 2026-09-18

A release about the two sides of a call. A recording that held one side said nothing about why, and
on a Mac with no audio input at all it could not be made. Both are answered here, together with the
speaker runtime that could not find the libraries it decodes with.

### Added
- **Settings -> General -> Record when there is no microphone**, on by default. A Mac mini has no
  audio input, and ScreenCaptureKit records the call's system audio on its own, so the other side is
  captured and the transcript holds it. Turning the switch off keeps the older refusal, which is the
  choice for a Mac that has a microphone and wants every recording to hold both sides.
- The Screen Recording permission is read when the app starts, so the card that names it is on the
  surface before a call rather than after one that failed. The card opens the pane that holds the
  switch.

### Fixed
- A start or a resume that macOS refuses for lack of Screen Recording now says so. It was reported
  as a ScreenCaptureKit failure, and the sentence named no permission and no way to grant one. The
  diagnostics still record the framework error, and a resume that fails this way leaves the call
  paused, with the audio it holds, instead of ending it.
- Speaker detection finds FFmpeg's shared libraries. TorchCodec loads them at runtime, and a GUI app
  does not inherit the shell setup that makes them findable, so the check reported a runtime that
  could not decode. The library directory of the FFmpeg the app selected is now passed to the child
  process that does the speaker analysis, and nothing else in the app's environment changes.
- The Speaker setup check decodes a real, one-second WAV through TorchCodec instead of loading the
  model and stopping there. A runtime that cannot decode audio no longer reports itself ready.
- Every capture refusal has a sentence a person can act on. Without one, a missing microphone
  reached the surface as "The operation couldn't be completed".
- The release signature carries the microphone entitlement.

### Verified
- 607 tests pass in 77 suites. Eight are new: the two permissions, the absent microphone, the
  FFmpeg library path, and the stored setting that records without one.
- Said plainly: a recording made without a microphone holds the other side only, and no local
  voice is in it. Diarization has one speaker to work with, and the person who recorded it is not
  in the transcript. The switch is there to be turned off where that is not wanted.

## [0.1.12] - 2026-09-18

A correction to when the recorder starts by itself. It started for any app that took the
microphone, and two recordings in the recent list carry one side and no speech because of it. A
voice message, a dictation session, and a voice search all take the microphone and play nothing.

### Fixed
- A recording that starts by itself now needs a two-way call. The app that holds the microphone
  must also play audio, and it must do both for five seconds. A call lasts longer than that; a
  voice message usually does not. The recorder's own capture never counts, and the ignore list for
  the voice recorder, dictation, and the assistant still applies.
- Every decision is written down, and the app that took the microphone is named in it:
  `starting by itself: <app> held the microphone and played the other side for 5 seconds`, or
  `not starting: <app> holds the microphone and plays nothing`. Read them in Console under the
  subsystem `local.callrecorder.app`, category `automatic`.

### Verified
- 599 tests pass in 77 suites. Five of them are new: a microphone alone is not a call, a
  microphone with the other side is, the recorder's own audio never qualifies, the holder is
  named, and the window is longer than a voice message.
- The rule was seen to fail before it was trusted. With the playing side ignored, "a process that
  holds the microphone and plays nothing is not a call" fails.
- Not covered, and said plainly: an app that holds the microphone **and** plays audio still
  qualifies an automatic start. An assistant in a voice chat and a read-aloud are two of them. The
  log line names the app, so the ignore list can grow from evidence instead of from a guess.

## [0.1.11] - 2026-09-18

The discarding question answers again. It was a system confirmation dialog, drawn as a window of
its own over a popover that never takes the keyboard, so its buttons could not be pressed.

### Fixed
- Discarding a running recording is confirmed inside the popover. The question, the consequence,
  and its two buttons sit in the row the popover already answers: Discard, in the destructive tone,
  and Keep Recording. The timer keeps running while the question is on screen, and the recording is
  untouched until one of the two is pressed.

### Verified
- 594 tests pass. No automated test pins the buttons: the state is reachable only by pressing a
  button during a recording, so the evidence is the rendered state, read by eye, plus the fact that
  the buttons are the same control every other button in the popover uses and the popover is the
  surface that already answers clicks.

## [0.1.10] - 2026-09-18

A correction to 0.1.9. The strip above the panel's content was still there, because the fit added
in that release never reached the window it was written for.

### Fixed
- The menu bar panel is put back under the menu bar every time the system moves or resizes it. The
  0.1.9 fit looked for a borderless window, and the panel is not one: the system gives it a title
  bar that is never drawn, so the rule that was meant to leave a person's own windows alone skipped
  the panel as well. The panel is now found from the inside. The popover's content reports the
  window it is drawn in, and that window is the one that is fitted. The fit also runs after every
  move and resize, because the system keeps the corner it placed and grows the window from there;
  that is what slides the top edge down the screen and leaves the desktop showing above the content
  as the popover changes height.
- The panel no longer keeps the app in the Dock. Promotion to a regular app counts titled windows,
  and the panel carries a title bar, so an open popover used to put a Dock icon and a menu bar on
  screen. The panel is named and excluded.

### Verified
- 594 tests pass. Five of them are new: the titled panel is placed under the menu bar, a resize of
  the panel is corrected, the sweep fits the panel and leaves a titled window that is not the panel
  alone, a panel shorter than its content is placed but never grown, and the panel is not counted
  when the app decides whether it stays a menu bar app. Each of the first four was run against the
  code without the fix, where it fails for the reason it was written for.

## [0.1.9] - 2026-09-18

A reading release. Every row in the recent list says how long its call ran, and the panel no
longer opens with a strip of nothing above its content.

### Added
- Each row in the recent list carries the length of its call as a clock: `1:04:22`. All three
  fields are always drawn, so a column of lengths can be read against the next one at a glance,
  and the digits are fixed-width so the column lines up. A call that has not ended — one still
  being recorded, or one whose end was never written — says nothing rather than showing a length
  it does not have.

### Fixed
- The menu bar panel no longer opens with a transparent strip above its content. SwiftUI sizes the
  panel window from the surface inside it, and that size only ever grows: a list that loses rows,
  or a card that is sent away, leaves the window at the tallest height the surface has had. The
  leftover strip sits above the content, nothing is drawn in it, and the desktop shows through it,
  which reads as a stray transparent header. The window is now given the height of what it holds,
  and its top edge is put against the menu bar, every time the panel comes on screen.

### Verified
- 590 tests pass. Six of them are new: four pin the panel's height and position, and two pin the
  length a row shows and the length it refuses to show.
- The invented library the published pictures are drawn from now carries three different call
  lengths, so the row's new field is visible in the documentation and not only in a test.

## [0.1.8] - 2026-09-17

A settings release. A version that is waiting installs when you ask for it, the check runs on a
step you choose, and a model you picked from the folded list stays in sight.

### Added
- The Updates card installs a waiting version at a press. A downloaded and checked version used to
  wait for the app to quit, which is the one moment the bundle is idle. Restart starts a small
  shell that waits for this process to end and then opens the app, and quits: the swap runs in the
  quit, as it always did, and the next launch is the new version. A restart during a call is
  refused, because the audio of a call still being captured has not been finished into a file that
  anything could put back. When that shell cannot be started at all, nothing quits and the row says
  what to do instead.
- Check for updates chooses how often the app looks for a release while it stays open: every 30
  minutes, every hour, every 2, 6, or 12 hours, or once a day. The app shipped with one step, six
  hours, and a settings file written before the choice existed lands on it. Changing the step ends
  the wait that is already running, so choosing half an hour does not mean waiting out the twelve
  hours the app was told before.
- A model chosen from the folded list is shown with the rows above it. Its row is where the file's
  state and its Delete control live, and a choice that can only be found by unfolding twenty-nine
  rows reads as though it had been forgotten.

### Changed
- A check that finds a release already waiting no longer fetches it again. The check repeats every
  few hours, and each one repeated the whole download, the unpack, and every check over the copy
  that was already waiting.

### Verified
- 584 tests pass. Eleven of them are new: the waiting shell and its log line, the restart that
  quits and the one that must not, the six steps and what an unreadable step costs, the check a
  changed step must not cut short, the wait a changed step ends, and the model the models page
  keeps showing.
- The Updates card was rendered in the waiting state before it was published, which is what caught
  a Restart button drawn as "Rest…" beside a wrapping sentence.

## [0.1.7] - 2026-09-17

A quiet release. Automatic recording stops when the room goes silent, and a diarization failure
reports the fault it actually met.

### Added
- Automatic recording stops after ten minutes without speech. A meeting that ends can leave its
  app holding the microphone, and the recorder then holds an empty room until the ceiling, hours
  later. The capture measures both sources, and speech is counted at -50 dBFS: the room tone of
  the recordings in the library sits at -66 to -53 dBFS and speech reaches -42 and above. The rail
  has the same switch as the other three, it applies only to a recording the app started by itself,
  and it fails open. A meter that has read nothing, or a buffer whose format it does not
  understand, is not evidence of silence: the rail does nothing rather than stop a call it cannot
  hear.

### Fixed
- A diarization run that failed for a real reason could be reported as an empty output. The
  script's standard output arrived through a pipe read by a thread on the utility queue, and the
  parent waited five seconds after the script had exited for that reader to finish; on a busy
  machine the reader could still be waiting to be scheduled, and the error it was carrying was
  replaced by one that names the wrong fault. Both streams now go to files, as they do for every
  other command the app runs.

### Verified
- 573 tests pass. Seven of the new ones cover the level measure and the meter, including the two
  cases where the meter must refuse to answer.
- The threshold was measured before it was chosen: every 20 ms window of the microphone and system
  track of the four recordings still on this Mac, reported as a peak level.

## [0.1.6] - 2026-09-17

An accuracy release. A transcript holds each sentence once, and automatic recording stays inside
limits it was missing.

### Added
- Repeated speech is removed from a transcript, while a call is transcribed and over the saved
  library. Transcription runs in five-minute chunks that overlap, and a microphone also hears the
  speakers, so the same sentence reaches the model twice and both copies are written down: one call
  in the library held 473 repeated runs, and 17.2% of the words across four calls were said twice.
  A repeat is removed only when it is the same words, five or more of them, and the first copy is
  the one that stays, so a word the model heard differently is never chosen between. The repair
  that runs when the cleaning rules move applies the rule to the saved library as well, and
  Settings > Recovery reports the words it took out.
- Settings > General > Automatic recording: three backstops for the recordings the app starts by
  itself. The voice recorder, dictation, the system assistant, and the services behind them, which
  are matched by bundle-identifier prefix, no longer start a recording. A recording shorter than
  the floor, 30 seconds by default, is moved to Recently Deleted instead of being transcribed. A
  recording that reaches the ceiling, 180 minutes by default, is stopped and kept. Each of the
  three has its own switch. A switch and the number beside it are one setting rather than two, so
  they cannot disagree about whether the rail is on: switching a limit off leaves no limit, and
  switching it back on starts from the standard. A recording started by hand is outside all three.
- `docs/pitfalls.md`: the traps this app has already paid for, each with the rule it bought.

### Changed
- The transcript cleaning rules are at version five, so the saved library is repaired once on the
  next launch. The repair copies what it rewrites into the Backups folder first, as it does for a
  glossary repair.

### Verified
- 561 tests pass, 28 of them new: 12 over the repeat rule and 16 over the rails, including the
  cases where a rule has to stay out of the way.
- The repeat rule was measured on four recorded calls before it was written: 174 runs, 1 358 words
  of 7 917, which is 17.2% of the library, and the count is the same whether a copy sits 50 words
  away or 400.

### Fixed
- The transcript a call is saved from, the JSON the search index is built from, and the markdown a
  person reads are cleaned in one pass, so the three cannot disagree about what was said.

## [0.1.5] - 2026-09-17

The first release the app installs by itself, and the one that stops an update from fetching the
runtime again.

### Changed
- The runtime archive is built deterministically: file times are flattened and the entries are
  written in sorted order. Every earlier release produced an archive with a new hash even when
  nothing about the runtime had changed, so the first launch after an update fetched and unpacked
  all 36 MB again. One tree now always produces the same bytes, so an update that does not touch
  the runtime reuses the copy already unpacked beside the app.
- The package script unpacks the archive it built and refuses one whose `bun` did not come out
  executable, which is the part a sorted archive has to get right.

## [0.1.4] - 2026-09-17

An updates release. Call Recorder keeps itself current with the releases of its own repository,
and installs one when it quits.

### Added
- The app follows `Rawgeek/call-recorder` at launch and every six hours. A newer release is
  downloaded, compared with the digest the release published, and unpacked beside the app, where
  the bundle inside it is checked again: identifier, version, a valid signature, and the same
  signer as the copy that is running. Nothing is swapped while the app is in use.
- The swap happens as the app quits, which is the one moment the bundle is idle, so the next
  launch is the new version and no call is interrupted. The version that was working is kept in
  Application Support, and Settings > General > Updates can put it back the same way.
- Settings > General > Updates shows the version, the automatic option, a check now, download
  progress, and whatever is waiting. A version the user went back from is still offered, and is
  never installed by itself again.
- Every step is written to `~/Library/Logs/CallRecorder/app-update.log`, including the path of
  the copy that was kept.
- A swap interrupted between its two renames is repaired at the next launch, and a copy left
  behind by an earlier run is removed rather than trusted.

## [0.1.3] - 2026-09-17

A size release. The app bundle is 10 MB instead of 49 MB, and every Whisper model the model host
publishes can now be installed.

### Changed
- The JavaScript runtime travels as a release asset instead of inside the app. It was 36 MB of the
  49 MB bundle. The app fetches it once, with the same byte-counted downloader the models use, and
  Settings > Models shows it as a row with its own progress, Retry, and state. The archive is kept
  in Application Support, so a Mac that has fetched it once can rebuild the runtime with no
  network, and the runtime folder itself is 95 MB unpacked either way.
- Codex can start the MCP server with no app running, so the script at the registered path fetches
  the archive itself when it has to. Both paths write the same file, and the hash in the bundle
  decides whether what arrived is accepted. The registered path is unchanged.
- The app binary is stripped of the symbol table nothing reads: 13.1 MB to 8.5 MB.
- `scripts/package-app.sh` builds the small app by default and writes the runtime archive beside
  it as a release asset. `CALL_RECORDER_EMBED_RUNTIME=1` builds the self-contained app instead,
  which needs no network.

### Added
- Every model file the host publishes is in the catalog: 33 files instead of 11. Large v1 was
  missing, and so were the 21 quantized files. Quantization matters where memory is tight: a
  five-bit Large v3 Turbo is 574 MB and about 1.3 GB of working set, against 1.6 GB and 2.3 GB for
  the full file.
- Quantized rows carry no word error rate of their own. The published figures belong to the full
  files, so repeating them beside a smaller file would claim an accuracy it does not have; the row
  says what it trades instead.
- The catalog was checked against the host: every file's byte count and SHA-256 match, the pin
  names the host's current revision, and the list is exactly the host's own file list.

### Verified
- The app fetches the runtime, verifies it, unpacks it, and indexes a call through it with the
  app's own entry point.

## [0.1.2] - 2026-09-17

A size release. The app bundle is 49 MB instead of 150 MB, and what it does is unchanged.

### Added
- A sentence behind an information glyph now appears in about a fifth of a second. The app draws
  it, because the system's own tooltip took three or four seconds on an 11-point glyph, and on
  many rows never appeared at all. Every settings pane uses it.
- A model that is downloading draws a ring that fills, with the share it has reached beside it.
  The bytes are counted as they arrive, so a slow transfer can be told from a stopped one.
- Settings > General > Storage: "Remove the audio of a finished call". Turning it off keeps each
  recording's audio beside its transcript. It is on by default, which is what the app did before
  the option existed, and the audio of a finished call is still recoverable for a day.
- The microphone menu offers the system's own choice first, named for the device macOS is set to
  use today, so following the system can be chosen and checked. Naming a device still pins it.

### Changed
- The JavaScript runtime ships as one compressed archive and is unpacked into
  `~/Library/Application Support/CallRecorder/runtime` on first use. The path Codex registers,
  `Contents/Resources/indexer/bun`, is still the entry point, so an existing MCP registration
  keeps working. The archive is checked against the hash recorded when the app was built.
- The Silero VAD filter is now a download of 865 KB from `ggml-org/whisper-vad`, managed like
  every other model: hashed before install, swapped in, revertible, and listed under
  Settings > Models > Components. The app fetches it at launch, and a transcription waits for
  it rather than failing.
- The packaged dependency tree carries only the files the runtime loads. The image library the
  embedding model imports at startup is answered by a stand-in that raises if anything ever uses
  it, the unused browser and CommonJS builds of that library are gone, and the ONNX library is
  stripped of its symbols. 78 MB of dependencies became 32 MB.
- Both JavaScript entry points are minified with identifier names kept, so a stack trace in the
  log still reads as code.
- `scripts/package-app.sh` can build without the signing key: `CALL_RECORDER_SKIP_SIGNING=1`.
- The clips the speaker review plays are now the excerpt with its silence removed, cut once and
  kept, so a turn that opens with seconds of room tone is judged on the words instead. A clip
  that cannot be cut leaves the recording playing as before.

### Fixed
- The app stopped starting index jobs when the runtime became one archive: it looked for a script
  that now lives inside the archive and quietly fell back to the command line. It reads the layout
  it was packaged with and names the entry point inside the archive.
- A row holding a download pushed its Cancel button off the edge of the card. The status chip,
  the ring, the share, and the button do not fit on one line; while a download runs the row shows
  the ring, the share, and the button.
- The runtime script treated a folder it could not create as another process holding the lock,
  and waited three minutes before failing for the wrong reason. It now reports what it could not
  create.
- The database client needs `detect-libc` to choose its native binding. The pruned tree keeps
  it; without it the MCP server stopped at its first query.
- The clip cutter wrote each part-finished file as `clip.m4a.partial`, a name ffmpeg refuses to
  choose a format for, so no clip was ever cut. The file keeps the extension it will be read
  with, and two tests now cut clips from real audio.

### Verified
- 485 tests pass, including new tests for the unpacking script and for the downloaded filter.
- The packaged runtime unpacks in under a second, serves all 17 MCP tools, and re-indexes a call
  against a copy of a real library, storing 256-dimension embeddings.

## [0.1.1] - 2026-09-17

Security update for the MCP package. Recording, transcription, and speaker behavior is
unchanged.

### Security
- Fixed all 18 open Dependabot alerts in `mcp/` by moving the affected transitive
  dependencies to their patched releases: `hono` 4.13.8, `fast-uri` 3.1.8, `qs` 6.16.0,
  `sharp` 0.35.4, and `adm-zip` 0.6.1.
- Added dependency overrides in both the npm and pnpm sections, so a fresh install resolves
  the patched versions even though the parent packages still declare older ranges.
- Pinned the MCP dependencies to exact versions. `latest` allowed the lockfile, CI, and the
  packaged app to drift apart.

### Verified
- `pnpm audit` reports no known vulnerabilities for the locked tree.
- The indexer still runs against the cached embedding model: `sharp` 0.35.4 loads under
  `@huggingface/transformers` 4.2.0 and produces 256-dimension query and document
  embeddings offline.

## [0.1.0] - 2026-09-17

First public release.

### Recording
- Both sides of a call: microphone plus system audio, saved as separate sources and one mix.
- Optional automatic start when another app opens the microphone, and automatic stop after
  the call ends.
- Manual start, pause, resume, stop, and discard from the menu-bar panel; the next call can
  start while an earlier one is still processed.
- One-sided-call detection: a row warns when the other side was never captured.

### Transcription
- Local Whisper transcription through whisper.cpp, with per-call language detection.
- Readable output: timestamps and non-speech annotations are removed, one line per turn.
- Glossary: preferred spellings reach the model as prompt context, and saved text is
  corrected with the same rules afterwards.

### Speakers
- Local diarization through pyannote.audio, with an optional Python environment.
- Encrypted voice profiles learn a voice when a name is confirmed, then suggest or apply
  that name on later calls. Voiceprints live in the macOS Keychain.
- Review Speakers with transcript samples and playable excerpts per voice, and line-level
  reassignment when one voice holds two people.

### Library and Codex
- Local Turso/libsql database with FTS5 (BM25) and 256-dimension vector search from a bundled
  local embedding model; hybrid ranking by default.
- MCP server with 17 tools for calls, transcripts, participants, glossary, and speaker
  review. Writes are queued as requests and applied by the signed app, so every change is
  undoable.

### Operations
- Self-updating models: download beside the model in use, verify SHA-256, swap atomically,
  keep the previous copy for revert.
- Recovery: database check and backup, working-file restore, failed-call retry, redacted
  diagnostics bundle, and Copy Error Details on every failure surface.
- Audio is moved to a 24-hour Recently Deleted area only after the transcript and index are
  verified; nothing is deleted silently.
