# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released version needs its own `## [x.y.z] - YYYY-MM-DD` section: the
release workflow extracts it with `scripts/changelog-extract.sh` to build the
release notes, and fails if it is missing.

## [Unreleased]

### Removed

- **Per-meeting rules.** `RecordingRule`, `RuleMatcher`, `RuleEngine`, the
  never/ask/always table in Settings → Regeln, the `rules` setting, and the `--rule`
  debug flag are gone. Every detected meeting now shows the suggestion, once, and the
  answer is a click — which is what the rules could express anyway, at the price of a
  settings screen to maintain and a behaviour to explain. The watchlist moved to a
  renamed **Erkennung** tab, which is all that tab holds now.
- **Calendar titles.** `CalendarTitleReader`, the `useCalendarTitles` setting, the
  `import EventKit`, and `NSCalendarsFullAccessUsageDescription` in `Info.plist`. The
  calendar existed to name a meeting *before* the popup was shown, for Zoom and Google
  Meet whose windows carry a product name and a room code. The popup no longer waits
  for a name, so reading somebody's calendar bought nothing that a window title does
  not. Steno now requests no calendar access at all, and the meeting title has exactly
  one source: the triggering app's window.
- Settings blobs written by an earlier build still decode: the `rules` and
  `useCalendarTitles` keys are ignored and dropped the next time the blob is written.
  There is a test for it.

### Changed

- **Screenshot file names carry the time since the recording started, not the wall
  clock.** A frame taken 18.42 s in is now `screens/000018_d1_active.jpg` and not
  `screens/143012_d1_active.jpg`: `HHMMSS` is the entry's `t` floored to the second,
  which is character for character the stamp `transcript.md` prints in front of the
  line that was being spoken (`[00:00:18]`). Lining an image up with the talk is what
  both files are for, and the wall clock made it a subtraction against `meta.started`
  that the reader had to do first. Hours count upwards rather than wrapping, so a long
  meeting keeps its order, and the same-second collision suffix (`_2`, `_3`) is
  unchanged. `ElapsedClock` in `StenoCore` is now the single formatter for both files,
  so they cannot drift apart. The wall clock is not lost: every `screens.jsonl` line
  gained an **`at`** key — `{"t":18.42,"at":"2026-09-09T14:30:30+02:00","file":…}` — in
  the same ISO-8601-with-offset form and the same zone `meta.json` uses, in second
  place, before `file`. A deliberate deviation from specification §4, listed in
  `README.md` under "Abweichungen von der Spec" and described in `docs/FORMAT.md`.
  Folders recorded by an earlier build are read as they are: an index line without `at`
  decodes, keeps its wall-clock name, and `scripts/verify-recording.sh` reports such a
  folder as old rather than broken — it tells the two apart by the presence of `at`,
  never by the digits, which look alike. The script also learned `--fixture` for a
  documentation folder whose images and audio are deliberately absent.
- **The suggestion no longer waits for the meeting's name.** It used to appear only
  after the window-title search had finished, which for a Teams call meant up to ten
  seconds of nothing while the meeting started without the user. Now the panel goes up
  in the same turn of the run loop as the trigger, with
  `Teams-Meeting erkannt. Aufnehmen und transkribieren?`, and the title search runs
  beside it: a name that arrives while the question is up rewrites the headline
  (`„Weekly Sync“ in Teams erkannt. …`), one that arrives after the recording started
  is written into `meta.title` by `RecordingSession.setTitle(_:)`. The folder is never
  renamed for a late title — the WAV is open inside it and `screens.jsonl` points into
  it — so a folder without a title slug can still carry a `title`. The twenty-second
  auto-dismiss, Return/Esc, and asking once per meeting with the sixty-second re-arm are
  unchanged.
- **The merger snaps orphan tokens to the nearest speaker.** A token whose midpoint no
  diarization segment covers is now given the nearest segment's speaker when that
  segment's edge is within **0.5 s** (`unknownSnapTolerance`, ties to the earlier
  segment); only past that does it become `UNKNOWN`. The first real recording was full
  of the failure this fixes: pyannote ends a segment on the last voiced frame while
  Parakeet's token still carries the trailing consonant, and the word became a one-word
  `UNKNOWN` utterance in the middle of somebody's sentence. Re-merging that recording
  with the new rule turns 16 utterances into 13 and removes all three `UNKNOWN` labels,
  at distances of 0.03 s, 0.18 s and 0.46 s. A documented deviation from specification
  §5's "kein Treffer → `UNKNOWN`", noted in `README.md` and `docs/FORMAT.md`.
- **The aggregate device's clock follows the numbers, not the principle.** The
  microphone was always the clock master, so a Poly BT700 in its 16 kHz hands-free
  profile dragged the whole aggregate — and with it the tap's 48 kHz system audio —
  down to 16 kHz, which is exactly what the first real Teams recording did. `online`
  capture now asks the input device for its nominal rate: at 48 kHz or above the
  microphone leads as before, and below it the **tap** becomes the aggregate's main
  sub-device and the microphone gets `kAudioSubDeviceDriftCompensationKey`. The choice
  is one pure function (`AggregateClock`) with its own tests, the
  `aggregate device … at N Hz` log line now says which member keeps time and what the
  microphone runs at, and a resulting rate below 48 kHz is logged as an error rather
  than a shrug. Should the HAL refuse a tap as its time source, creation is retried with
  the microphone so a recording still happens.
- `--rule` is replaced by `--title-delay <seconds>`, which makes the fake title search
  take that long — the way to see the panel appear first and gain the name afterwards.
  The detection simulation now reports how long after the trigger the panel appeared and
  whether the headline names the meeting.

### Added

- **In-app updates (M7).** Steno checks GitHub for a newer version once a day and on
  demand, through Sparkle. "Nach Updates suchen …" in the menu and "Jetzt suchen" in
  Settings → Updates both ask now; the tab also shows the installed version and build,
  when the last check was, and where the feed is read from. Every update is verified
  against an EdDSA public key in the app bundle before it is installed, so a release
  nobody holding the private key produced cannot be installed by anybody.
- **`UpdaterController`.** The updater is only started when the bundle carries a
  plausible public key — 44 base64 characters decoding to 32 bytes, and not the
  placeholder. Sparkle answers a misconfigured bundle with an alert telling the user to
  contact the developer, a few seconds after launch and unprompted, which is right for a
  shipped app and wrong for a build made before the first release. Such a build now logs
  one line and leaves both update actions disabled with "Update-Feed noch nicht
  konfiguriert" instead.
- **The release pipeline.** `.github/workflows/release.yml` reacts to a `v*` tag: the
  version comes from the tag, the build number from `git rev-list --count HEAD`, the
  release notes from the changelog section for that version — a missing section stops
  the run before anything is published. It builds Release, packages the app with
  `ditto`, signs the appcast with the key from a repository secret, and creates the
  GitHub release with the zip and `appcast.xml` attached. A tag with a pre-release part
  is published as a prerelease, which keeps release candidates out of
  `releases/latest` and therefore out of the feed the shipped app reads. Reruns through
  `workflow_dispatch` replace a release's assets rather than failing.
- **Developer ID and notarization, when they exist.** Signing is ad-hoc unless the
  repository has `DEVELOPER_ID_P12_BASE64`, and notarization only runs with `APPLE_ID`,
  `APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD` alongside it. Nothing in the code changes
  when a certificate arrives — only the secrets.
- **`scripts/release.sh` and `scripts/bump-version.sh`.** The first builds and packages
  a release locally with the same flags the workflow uses, and publishes nothing. The
  second cuts a version: the collected `## [Unreleased]` notes become a dated section, a
  fresh empty one is opened above it, the comparison links are rewritten,
  `MARKETING_VERSION` is bumped, both files are committed, and the annotated tag is
  created. It never pushes — the tag reaching the remote is what publishes a release, so
  that stays a separate, deliberate command. `make release VERSION=…` and
  `make bump VERSION=…` are the front doors.
- **`scripts/changelog-extract.sh --prerelease-fallback`.** A release candidate is cut
  from whatever is in `## [Unreleased]`, so it may use that section when it has none of
  its own. A final release may not: shipping 1.2.3 with notes headed "Unreleased" is the
  mistake the missing-section check exists to catch.

- **Launch-time recovery (M6).** Specification §6 says `state` is written continuously
  "damit ein Absturz erkennbar ist und der Ordner beim nächsten Start weiterverarbeitet
  werden kann". `RecoveryScanner` is the second half of that sentence. Before detection
  starts, it walks one level of the recording folder: a folder still saying `recording`
  has its WAV header recomputed from the file's length and rewritten in place, a
  half-written last line of `screens.jsonl` cut off, `ended` and `duration` derived from
  the newest file in it, `screenshots` counted, `stopReason: crash` written, and is then
  moved to `transcribing` and queued. One that captured nothing becomes `failed` with a
  reason. One saying `transcribing` is queued again. `done` and `failed` are left alone.
  Every step is logged. The menu says it once: "1 unterbrochenes Meeting wird
  nachverarbeitet".
- **`StenoCore.RecoveryPolicy`.** The decision itself — which of those five things a
  folder gets — is a pure function of the folder's state, its age, its lock, whether it
  has audio, and how many attempts it has had. It is a table with a test rather than a
  sequence of file-system calls, which is the only way the precedence between the rules
  is checkable at all.
- **`.steno-lock`.** A recording session now writes a hidden lock naming its process and
  the moment that process started, and removes it when capture ends. A folder locked by a
  live process is never touched by a recovery scan; one locked by a process that is gone
  is exactly what a crash leaves. The start time is there because PIDs are reused: after
  a reboot the number alone would make a stale lock look alive for ever. A folder whose
  newest file is under ten seconds old is skipped as well, as a second line of defence.
  Documented in `docs/FORMAT.md`.
- **A WAV header that keeps up while recording.** `WAVWriter` rewrites the RIFF and
  `data` sizes in the open file every ten seconds, through a second descriptor at fixed
  offsets. It is not what makes an interrupted recording recoverable — the scan above is
  — but it means the file is playable *before* the next launch. Measured: after a crash
  twelve seconds into a recording, `afinfo` reports 10.1 s instead of nothing, and the
  scan then restores the full 12.0 s.
- **`stopReason: crash`.** A new value in `meta.json`, written by the recovery pass for a
  recording nobody was there to end. It is the one stop reason whose `ended` is inferred
  — from file modification times — rather than observed, and `docs/FORMAT.md` says so:
  `duration` is a lower bound there, not a measurement.
- **Sprache / Language setting.** **Einstellungen → Transkription → Sprache**: Deutsch
  (default), Englisch, or Automatisch. It reaches
  `AsrManager.transcribe(_:decoderState:language:)` for both channels, where Parakeet
  v3's script-aware token filter uses it to pass over candidates written in the wrong
  script. `Automatisch` sends no hint; a tag the recognizer does not know is dropped
  rather than guessed at, because filtering for the wrong script would throw away the
  right words.
- **`SyntheticRecorder` and `--crash-after`** (debug builds). A recorder that writes a
  440 Hz tone — 880 Hz on channel 1 of an `online` recording — through the real
  `WAVWriter` with no hardware, and dies mid-write on command. It exists because
  verifying crash recovery needs a real crash, and killing a process that is inside Core
  Audio leaves a tap behind in `coreaudiod` that wedges every recording afterwards.
- **`--root` and `--defaults-suite`** (debug builds). A recording folder and a
  `UserDefaults` suite for one process only, neither persisted. Two copies of Steno share
  a bundle identifier, and without these a test run writes into the recording folder and
  the settings of whichever copy is doing real work. `--recover-and-quit` runs the
  recovery scan, waits for the queue, prints what every folder ended up as, and quits.
- **Transcription (M5).** A recording that stops now moves to `state: transcribing`
  and goes into a serial queue — one meeting at a time, in the background, with the
  step and the progress in the menu-bar ring. `audio.wav` → one 16 kHz mono work file
  per channel → Parakeet → pyannote → `TranscriptMerger` → `transcript.json` and
  `transcript.md` → audio archive → `state: done` → a notification. All of it on this
  Mac; the only network access in the whole app is the one-time model download.
- **`ChannelSplitter`.** `audio.wav` is read a second at a time with `AVAudioFile` and
  each channel resampled into `_work/room16k.wav` and, for `online`, `_work/mic16k.wav`
  with `AVAudioConverter` — never the whole file in memory, and never a byte of the
  container parsed by hand. FluidAudio's own `AudioConverter` cannot do this: it
  downmixes every channel to mono, and the two channels of an `online` recording are
  the whole point. `_work/` is deleted when transcription succeeds and **kept when it
  fails**, because the inputs of a failed run are the only thing that says why.
- **`FluidASR`.** Parakeet TDT 0.6 B, v3 by default, loaded once per launch. Each pass
  gets its own decoder state, so the microphone pass does not continue the room pass's
  linguistic context. `seamGapRepair` stays on.
- **`WordAssembler` in `StenoCore`.** The recognizer emits SentencePiece pieces —
  `Centerplan` arrives as `▁Center` plus `plan` — and the merger wants words. The
  assembly is pure logic, so it is tested without a 500 MB checkpoint: boundary
  markers, leading spaces, control pieces, spans, and averaged confidence.
- **`FluidDiarizer`.** pyannote community-1 plus VBx on channel 0 in both modes. The
  `onsite` speaker-count hint from `meta.speakers.expected` is fed in as
  `clustering.minSpeakers` / `maxSpeakers`, clamped to 2–8.
- **`AudioTranscoder`.** After the transcript is safely written, `audio.wav` becomes
  `audio.m4a` (AAC-LC, 128 kbps for two channels, 64 kbps for one), `audio.flac`, or
  stays as it is. The channels are never mixed down, and the WAV is deleted only after
  the archive has been read back and found to hold the same channels and the same
  length. A failed transcode is **not** a failed meeting: the WAV stays and
  `meta.audio` says so.
- **`ModelManager` does the download.** `AsrModels.downloadAndLoad` and
  `OfflineDiarizerManager.prepareModels`, both pointed at
  `~/Library/Application Support/Steno/Models/` — roughly 500 MB, once — with a coarse
  progress in the onboarding window's fourth row and in Settings → Transkription. The
  first load of a fresh Core ML model compiles it for this Mac's Neural Engine and can
  take minutes, so that step is **named** rather than reported as a download, and the
  models are warmed once afterwards so the first meeting is not what pays for it.
- **"Letztes Meeting erneut verarbeiten"**, in the menu, shown only while the newest
  meeting reads `failed`. It moves the folder back to `transcribing` and queues it.
- **The queue survives a relaunch.** It is written to `UserDefaults` as a list of
  folders with attempt counts, dropped after three attempts rather than relaunching
  into the same failure for ever, and picked up again at launch.
- **`--download-models` and `--transcribe <folder>`**, debug builds only: the first
  downloads, compiles, and warms the models and reports where they landed and how big
  they are; the second runs the whole pipeline over an existing meeting folder and
  prints the resulting state and the head of `transcript.md`.
- **`docs/format-fixtures/`** — a complete example meeting folder, written by
  `StenoCore`'s own encoders, that `FormatFixtureTests` decodes, checks, re-encodes,
  and compares byte for byte. A format change that is not deliberate now fails there
  instead of in somebody else's parser.
- **Screenshots across all displays (M4).** One `SCStream` per display at 1 fps,
  `queueDepth 3`, cursor on, no audio, BGRA in sRGB, longer edge scaled to at most
  1920 px. Only frames whose `SCStreamFrameInfo.status` is `.complete` (or `.started`,
  the first frame of a stream) are candidates; `.idle` is ScreenCaptureKit saying the
  display did not change, which is what replaces comparing images ourselves.
- **The gate is the one from `StenoCore`.** `SCStreamFrameInfo.dirtyRects` become a
  changed share through the new pure `DirtyRectMath.changedFraction(rects:frameSize:)`
  — each rect clamped to the frame, areas summed as specification §4.4 asks, capped at
  1.0 — and `ScreenshotGate` decides on that plus the elapsed time. 5 s / 2 % for a
  normal display, 2 s / 0.5 % for the one holding the pointer, all five numbers
  configurable, the anchor interval among them.
- **Anchor frames that actually appear.** A display that never changes never produces a
  stream frame, so the §4.6 anchor — one image per display at the start and every 120 s
  — is taken out of band with `SCScreenshotManager` by a timer, and the same gate stops
  the two paths from both saving the same moment.
- **`screens/` and `screens.jsonl`.** JPEG at quality 0.8 through `CGImageDestination`,
  named `HHMMSS_d<index>[_active].jpg`, with `_2` upwards when two frames of one
  display land in the same second (`ScreensFileNamer`). The index line is
  appended and flushed the moment the file is written, so a recording that was killed
  still has an index for everything it saved. `meta.displays` is written when the
  streams start and `meta.screenshots` when they stop.
- **Own windows are never captured** (plan addition). The suggestion panel, settings,
  and onboarding windows are excluded from every display's `SCContentFilter`, rebuilt
  whenever one of them opens or closes and every ten seconds regardless.
- **A locked screen pauses capture** (plan addition). Frames are discarded while
  `com.apple.screenIsLocked` is in force; the streams stay up, so unlocking resumes
  immediately, and the audio never stops.
- **Display hot-plug.** `didChangeScreenParametersNotification` starts streams for
  displays that appeared and stops the ones that went away. Indices are never
  renumbered — the file names and the index already point at them.
- **`scripts/verify-recording.sh <folder>`** checks a finished meeting folder against
  specification §11.8 and §11.11: every index line parses, every `file` exists and
  agrees with its own name, no two images of a display are closer than the configured
  interval (`--interval` / `--active-interval`), every display has an anchor near the
  start, `meta.screenshots` matches the line count, and nothing was written into the
  folder that does not belong there. Bash plus stdlib Python, nothing to install.
- **`--screenshot-log`**, debug builds only: one log line per gate decision — display,
  active, changed share, verdict.
- **Meeting detection (M3).** `MeetingDetector` watches Core Audio's process list and
  the `IsRunningInput` property of every audio process — event-driven through
  `AudioObjectAddPropertyListenerBlock`, with a two-second poll as the fallback when
  the HAL refuses a listener, and a one-second tick that advances the clock a listener
  cannot. A watched app reading the microphone for **≥ 5 s** is a meeting
  (specification §2).
- **Helper processes count as their app.** A watchlist entry now matches its own
  bundle identifier and anything below it in the dotted namespace, because Chrome,
  Edge, and Teams capture and play meetings in helpers
  (`com.google.Chrome.helper`). All of an entry's processes are tapped together —
  `TapTarget.process` carries a list of PIDs and `CATapDescription` mixes them down —
  so ch0 no longer depends on guessing which helper the meeting is in. A target whose
  processes have gone away falls back to a system-wide tap instead of failing.
- **The state machine is pure and tested** (`StenoCore.MeetingDetectorLogic`): the
  five-second debounce, the thirty-second auto-stop silence, and the sixty-second
  "ask once per meeting" hysteresis are a function of an activity set and a
  monotonic clock, driven in tests by a number rather than by waiting.
- **Meeting titles.** `WindowTitleReader` reads the triggering app's window titles
  (`CGWindowListCopyWindowInfo`, layer 0, largest window first) and
  `StenoCore.MeetingTitleCleaner` strips the app's decoration —
  `Weekly Sync | Microsoft Teams` becomes `Weekly Sync`. Titles that name the app
  rather than the meeting (`Zoom Meeting`, `Meet`, a Google Meet room code) are
  rejected, and the search is repeated every 2 s for up to 10 s because Teams renames
  its window only once the call is joined. Silent without Screen Recording.
- **Calendar titles, opt-in** (`CalendarTitleReader`). Used only when the setting is
  on *and* EventKit reports full access, for the Zoom and Google Meet case where no
  window carries a name. Access is requested in exactly one place: the Settings
  toggle.
- **Rules** (`RuleEngine`). The app and every title found, cleaned and raw, are matched
  against the user's rules: `never` records nothing and shows nothing, `always`
  records at once with `trigger: {"kind":"auto",…}`, `ask` — and no match — shows the
  suggestion.
- **The suggestion panel** (`SuggestionPanel`): a borderless, non-activating `NSPanel`
  in the top-right corner of the menu-bar screen, above the status bar, on every Space
  and over full-screen apps. Return records, Escape ignores, and twenty seconds
  without an answer is an ignore. It never activates Steno, so the meeting keeps the
  keyboard.
- **Auto-stop.** No process of the recorded app reading the microphone for the
  auto-stop delay (30 s by default) ends an `online` recording. `onsite` never
  auto-stops (specification §1).
- **Sleep and lock handling** (`SleepLockObserver`). `NSWorkspace.willSleepNotification`
  stops a running recording before the machine suspends;
  `com.apple.screenIsLocked` / `screenIsUnlocked` set `AppState.isScreenLocked`, which
  M4's screenshots will read. Quitting with a recording running now releases the
  process tap first — a leaked tap wedges `coreaudiod` for every recording after it.
- **`meta.stopReason`**: `manual` · `auto` · `sleep` · `deviceLost`, so a folder says
  what ended it. Documented in `docs/FORMAT.md`, along with `title` and the `auto`
  trigger.
- **Notifications** (`System/Notifications.swift`). A `UNUserNotificationCenter`
  wrapper with an "Im Finder zeigen" action; used for failed recordings now and for
  finished transcripts in M5. Authorization is requested only from the onboarding
  window's finish button and the Settings toggle, never at launch, and nothing is
  posted unless the status is already `authorized` or `provisional`.
- **The menu status line names the recorded app**: "Aufnahme läuft · Teams · 12:34".
- **Debug launch arguments** `--simulate-detection <bundle id> [title]`,
  `--simulate-detection-end <s>`, `--auto-answer record|ignore`, `--auto-stop <s>`,
  `--suggestion-timeout <s>`, `--rule never|ask|always <pattern>`, and
  `--null-recorder`, which drive the whole of §2 against an invented process list.

- **`online` audio (M2).** `ProcessTapRecorder` records a meeting as two channels in
  one `audio.wav` — 48 kHz, 16-bit PCM, ch0 the tapped system audio downmixed to
  mono, ch1 the microphone. A `CATapDescription` process tap and the default input
  device are members of a single private aggregate device
  (`AudioHardwareCreateAggregateDevice`), so both channels share one clock and one
  `AudioDeviceCreateIOProcIDWithBlock` callback and stay sample-aligned for the length
  of a meeting; the microphone is the clock master and the tap follows it with drift
  compensation. Adapted from [AudioCap](https://github.com/insidegui/AudioCap)
  (BSD-2-Clause), now credited in `ThirdPartyLicenses/`.
- **A real-time safe capture path.** The I/O callback allocates nothing, takes no
  lock, logs nothing, and touches no actor: it averages the tap's channels, copies
  the microphone's first channel, and writes interleaved frames into a preallocated
  lock-free SPSC ring buffer (`RingBuffer.swift`, four seconds at 48 kHz). A timer on
  its own queue drains the ring into `WAVWriter` every 50 ms. Dropped frames are
  counted and reported in the log; the expected number is zero.
- **Channel mapping is read, not assumed** (`AggregateChannelMap`). The aggregate's
  `kAudioDevicePropertyStreamConfiguration` and the tap's `kAudioTapPropertyFormat`
  decide which sample is which, so a mono built-in microphone, a stereo interface and
  an eight-channel desk all map correctly, and the mapping is logged on every start.
- **Tap target selection** (`Detection/RunningMeetingApps.swift`). A manual `online`
  start asks Core Audio which processes are reading the microphone
  (`kAudioHardwarePropertyProcessObjectList` + `kAudioProcessPropertyIsRunningInput`);
  exactly one watchlist app means the tap points at that app, names the folder after it
  (`…_Teams`) and records it in `meta.trigger` — `kind` stays `manual`. Otherwise the
  tap is system-wide with Steno's own process excluded, and the folder is `…_Online`.
- **Deadlines on starting and stopping a recorder.** Nothing in Core Audio has a
  timeout, and a wedged `coreaudiod` blocks every call that opens an input forever.
  Both halves now give up after fifteen seconds and leave a folder marked `failed`
  with a reason that says what fixes it, instead of a menu stuck refusing every start.
  A start that finishes late is stopped again and its audio file removed; a stop that
  finishes late keeps the partial recording.
- Debug-only `--tap-target <bundle id>`, which forces the `online` tap at one app.
- **`onsite` audio (M1).** `MicRecorder` records the room microphone through
  `AVAudioEngine` into `audio.wav` — 48 kHz, 16-bit PCM, one channel. The input
  device from the settings is selected on the input node's audio unit before the
  engine starts (`kAudioHardwarePropertyTranslateUIDToDevice` →
  `kAudioOutputUnitProperty_CurrentDevice`), and falls back to the system default,
  visibly in `meta.input.device`, when the configured one is not attached. No
  processing whatsoever: no voice processing, no automatic gain control, no
  normalization.
- **`WAVWriter`.** The streaming writer both modes record through, one or two
  channels. Buffers are copied on the audio thread and converted and written on the
  writer's own serial queue, so a tap callback never waits for the disk and a
  recording is never held in memory. An `AVAudioConverter` bridges whatever the
  device delivers — any sample rate, Float32 or Int16, more than one channel — to
  the file's format, and is kept across buffers so resampling stays continuous.
- **Microphone-mode check (M1).** Before an `onsite` recording,
  `AVCaptureDevice.activeMicrophoneMode` decides: `wideSpectrum` records in
  silence, `standard` records with a hint in the menu, and `voiceIsolation` is
  **refused** with a dialog whose button opens
  `showSystemUserInterface(.microphoneModes)`. The mode is read again on every
  start and on every menu redraw, so the record item enables itself as soon as it
  is changed. `online` is not gated on it. The mode in force is written to
  `meta.input.microphoneMode`.
- **Speaker-count picker (M1).** With the setting on, an `onsite` recording asks
  how many people are in the room — automatic, or 2 to 8 — and stores the answer
  in the new optional `meta.json` key `"speakers": {"expected": 4}`
  (`StenoCore.SpeakerHint`). M5 feeds it to the diarizer as `minSpeakers` and
  `maxSpeakers`.
- **Interruption handling.** A microphone that disappears, an engine that will not
  restart within two seconds, and a failed write all end the recording the same
  way: the file is closed so what was captured stays playable, `meta.json` is
  finished with `ended`, `duration`, and the audio file name, and the folder is
  marked `failed` with the reason. A sample-rate change on the same device is not a
  loss — the engine is rebuilt and the recording continues into the same file.
- Debug-only `--simulate-null-recording` (the old hardware-free path, now that
  `--simulate-recording` uses the real recorder) and `--print-microphone-mode`.
- Repository scaffolding: XcodeGen project definition, Makefile, CI workflow,
  issue and pull-request templates, and `scripts/changelog-extract.sh` for
  turning a section of this file into release notes.
- `StenoCore`, the framework-free logic package: semantic versions, recording
  folder naming, meeting metadata and its state machine, the screenshot
  decision gate, the screenshot index entry, WAV header parsing and repair,
  transcript models with the merge rules from the specification, the transcript
  Markdown formatter, and recording rule matching.
- A minimal menu-bar shell (`MenuBarExtra`) with a Quit item.
- **Menu bar (M0).** The menu from the specification: record an online or an
  on-site meeting, stop a running recording, show the last meeting in the
  Finder, open the recording folder, settings, quit. A non-interactive status
  line at the top while recording. Icon states drawn as `NSImage`: a microphone
  outline when idle, a filled microphone with a red dot and the running `mm:ss`
  while recording — plus a room glyph for `onsite` — and an `NSBezierPath`
  progress ring while processing.
- **Global hotkeys (M0).** ⌥⌘R, ⌥⌘V, and ⌥⌘S through Carbon's
  `RegisterEventHotKey`, so they work while the menu is closed and without
  asking for Accessibility permission. Released on quit.
- **Recording flow (M0).** `AppState` with its three phases and a one-second
  ticker, and `RecordingCoordinator`, which creates the meeting folder, writes
  `meta.json` at every state change, refuses to start when a permission is
  missing or the disk is nearly full, and ignores a second start while a
  recording runs. The audio itself arrives in M1 and M2 behind the new
  `AudioRecorder` protocol; a `NullRecorder` makes the whole path real and
  testable now.
- **Permissions and onboarding (M0).** Microphone, system audio, screen
  recording, and models, each with a state, an explanation, and one button.
  System audio has no query API, so it is probed by creating and destroying a
  throwaway global process tap. The onboarding window refreshes every five
  seconds while it is open, and the app refreshes whenever it is brought
  forward.
- **Settings (M0).** Six tabs — General, Recording, Screenshots, Transcription,
  Rules, Updates — covering the eleven settings from the specification plus the
  additions the plan accepted: audio archive format, recording rules, calendar
  titles, title in the folder name, notifications, anchor interval, and
  automatic update checks. Stored as one JSON blob under a single `UserDefaults`
  key, decoded with a per-key fallback so an older settings file keeps working.
- **Storage (M0).** The recording root is created at launch and whenever it
  changes; the newest meeting folder with a `meta.json` is what "last meeting"
  means; free space is checked before a recording starts, with a refusal below
  500 MB and a warning below 2 GB.
- `ModelManager`, which reports whether the ASR and diarization models are on
  disk under `~/Library/Application Support/Steno/Models` — checked against the
  layout and file names FluidAudio actually uses. The download itself arrives
  with M5; its states are already what the interface renders.
- `StenoCore`: `WatchedApp` with the specification's watchlist defaults and
  bundle-identifier validation, and `RecordingFolderName.matches(_:)` /
  `.startedDate(from:)` / `.label(fromFolderName:)`, so a recording folder can
  be recognized again without opening it.
- `os.Logger` per subsystem `de.21m.steno`, with a category per source
  directory.
- [`docs/FORMAT.md`](docs/FORMAT.md): the on-disk contract downstream tools
  read, derived from the `StenoCore` types — folder naming, every `meta.json`
  key with a worked example per mode, the state lifecycle, `screens.jsonl`, and
  both transcript files.
- Debug-only launch arguments `--simulate-recording`, `--open-settings`, and
  `--open-onboarding`, so the flow can be exercised without hardware.

### Changed

- **Ad-hoc builds carry a library-validation exception.** `Config/Steno.entitlements`
  is now the file for a build signed with a Developer ID;
  `Config/Steno-adhoc.entitlements` adds `com.apple.security.cs.disable-library-validation`
  and is what `project.yml` points at, because that is how every build is signed today.
  The release workflow switches back to the strict file as soon as a certificate is
  available, so a shipped, notarized app will not carry an entitlement it does not need.

- **A recording with no speech in it is `done`, not `failed`.** FluidAudio's offline
  diarizer throws `noSpeechDetected` rather than returning nothing, and a room where
  nobody spoke, a call joined and left again, or a channel that captured hold music are
  all recordings whose correct transcript has no speakers in it. They now produce an
  empty transcript and finish normally.
- **The transcription queue waits for the models instead of failing.** A folder queued
  on a Mac where the models cannot be prepared — not downloaded yet, no network to fetch
  them over — no longer spends one of its three attempts on it: the attempt is given
  back, the folder stays queued, and the queue picks itself up when the models arrive.
  Without it, a recovery at launch on a Mac whose model download has not happened would
  burn all three attempts before anybody could do anything about it.
- **Sparkle's version is read off the framework** rather than written down next to it, so
  the string in the settings window and in bug reports cannot drift from the build.
  FluidAudio has no bundle in the app and exposes no version constant, so it stays a
  literal kept in step with `project.yml`'s exact pin — noted where it is declared.
- **`scripts/verify-recording.sh`** checks `stopReason` against the documented set,
  reports a recording finished by the recovery pass as a note, and accepts a
  `.steno-lock` only while the process named in it is alive — a lock left behind by a
  process that is gone is a folder that has not been recovered yet, and fails the check.

- **A finished recording is `transcribing`, not `done`.** `RecordingCoordinator` hands
  the folder to the queue, which is what writes the transcript and moves it to `done`.
  A folder that said `done` with no transcript in it was claiming something that was
  not there.
- **`scripts/verify-recording.sh` checks the transcript too**: `transcript.json`
  parses, agrees with `meta.json` about the mode, names its models, has a
  `transcript.md` beside it, and carries `ME` only in `online` mode; `meta.audio` names
  a file that exists; a `done` meeting has a transcript at all. An empty
  `meta.displays` is now a note rather than a failure when no screenshots were written
  — a recording made without Screen Recording is a legitimate recording.
- **`meta.models.diarizer` is `pyannote-community-1`**, the model, rather than
  `speaker-diarization`, the Hugging Face repository it ships in. That is the name
  specification §5 writes and the one a reader can look up.
- Screenshots are captured in **both** modes, `onsite` included (specification §1): the
  screen rarely changes in a room, so it costs almost nothing.
- Nothing about screenshots can fail a recording. A missing Screen Recording
  permission, a display that refuses to start, a stream that stops mid-meeting (it gets
  one restart after 2 s), or a disk that fills up all end as a log line and a meeting
  that still has its audio.
- The app-hosted test bundle no longer starts a capture. `RecordingCoordinator` is
  driven end to end by its tests, and photographing the screen of whoever runs
  `make test` is not something a test may do.
- The folder label for an `online` recording with no identifiable app is now
  `Online` rather than `Meeting` (`StenoCore.RecordingFolderName.unknownAppLabel`):
  such a recording is a system-wide tap, and the name says what was recorded.
- `meta.trigger` may carry `bundleId` and `name` with `kind: "manual"`. A reader must
  not take the presence of an app as proof that detection fired — documented in
  `docs/FORMAT.md`.
- `RecordingCoordinator` picks its recorder per recording through a
  `RecorderFactory` — `MicRecorder` for `onsite`, `ProcessTapRecorder` for `online`
  — instead of holding one for the life of the app.
- A stop requested while a recording is still starting is remembered and honoured
  once the recording exists, rather than silently dropped. Opening a microphone
  takes a moment, and ⌥⌘R immediately followed by ⌥⌘S is a thing people do.
- The menu shows a notice below the recording status line rather than instead of
  it, so the microphone-mode hint stays readable for the whole recording.

### Fixed

- **The Release build could not start at all.** The hardened runtime turns on library
  validation, which only lets a process load code signed by its own team or by Apple.
  Two ad-hoc signatures have no team, and are therefore not the same team: dyld refused
  to map the app's own `Sparkle.framework` out of its own bundle — "mapping process and
  mapped file (non-platform) have different Team IDs" — and the app died before `main`.
  Debug builds were unaffected, which is why it survived six milestones: they are not
  hardened. Found by launching a Release build for the first time, while preparing the
  first release.

- `kAudioAggregateDeviceTapAutoStartKey` is **off**, unlike in AudioCap. With it on,
  the aggregate device's callback only runs while the tap is running, so a tap on an
  app that happens to be silent produced no callbacks at all — measured here as zero
  in ten seconds, against 240 128 frames in five with it off. That would have taken
  the microphone channel down with it every time the far end went quiet, and closed
  the gap up so that nothing in the file lined up with the clock any more.
