# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released version needs its own `## [x.y.z] - YYYY-MM-DD` section: the
release workflow extracts it with `scripts/changelog-extract.sh` to build the
release notes, and fails if it is missing.

## [Unreleased]

### Added

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

- `RecordingCoordinator` picks its recorder per recording through a
  `RecorderFactory` — `MicRecorder` for `onsite`, `NullRecorder` for `online`
  until M2 — instead of holding one for the life of the app.
- A stop requested while a recording is still starting is remembered and honoured
  once the recording exists, rather than silently dropped. Opening a microphone
  takes a moment, and ⌥⌘R immediately followed by ⌥⌘S is a thing people do.
- The menu shows a notice below the recording status line rather than instead of
  it, so the microphone-mode hint stays readable for the whole recording.
