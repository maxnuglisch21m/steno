# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Each released version needs its own `## [x.y.z] - YYYY-MM-DD` section: the
release workflow extracts it with `scripts/changelog-extract.sh` to build the
release notes, and fails if it is missing.

## [Unreleased]

### Added

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
