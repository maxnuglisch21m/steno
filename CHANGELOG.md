# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released version needs its own `## [x.y.z] - YYYY-MM-DD` section: the
release workflow extracts it with `scripts/changelog-extract.sh` to build the
release notes, and fails if it is missing.

## [Unreleased]

### Added

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

- `kAudioAggregateDeviceTapAutoStartKey` is **off**, unlike in AudioCap. With it on,
  the aggregate device's callback only runs while the tap is running, so a tap on an
  app that happens to be silent produced no callbacks at all — measured here as zero
  in ten seconds, against 240 128 frames in five with it off. That would have taken
  the microphone channel down with it every time the far end went quiet, and closed
  the gap up so that nothing in the file lined up with the clock any more.
