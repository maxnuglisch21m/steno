# Steno

A macOS menu-bar meeting recorder. It records the audio and the screens of a
meeting, transcribes them locally with speaker separation, and writes the result
to disk as plain files. Nothing else.

Steno produces **raw data**, not documents. There are no summaries, no context
enrichment, no OCR, no export integrations, and no cloud: the only network
access it ever makes is the one-time model download. Whatever you want to *do*
with a meeting is the job of a separate tool that reads the files below.

- **Platform:** macOS 15+, Apple Silicon
- **UI language:** German (English translations included)
- **Status:** early development — see [milestones](#milestones)

## What it produces

One folder per meeting, under `~/Meetings/` by default:

```
~/Meetings/2026-09-09_1430_Teams/       # online mode: _<App>
~/Meetings/2026-09-09_1430_Vorort/      # onsite mode: _Vorort
  audio.m4a          # or audio.wav / audio.flac, depending on the archive setting
  screens/
    143012_d0.jpg
    143012_d1_active.jpg
  screens.jsonl      # one line per screenshot, keyed by seconds since start
  transcript.json    # utterances, raw diarization segments, models, confidence
  transcript.md      # [00:00:12] S1: Also der Centerplan ist durch.
  meta.json          # mode, timestamps, trigger, displays, state
```

`screens.jsonl` is the bridge between the images and the transcript: each entry
carries `t`, the offset in seconds from the start of the recording, so a
downstream tool can line a screenshot up with what was being said.

Steno writes nothing outside the recording root, with one documented exception:
the ASR and diarization models are cached under
`~/Library/Application Support/Steno/Models/` (or FluidAudio's own
`~/.cache/fluidaudio/`, where its API does not accept a directory).

The exact on-disk contract — folder naming, every `meta.json` key, the state
lifecycle, `screens.jsonl`, and both transcript files — is in
[docs/FORMAT.md](docs/FORMAT.md). That is the document a downstream tool, or a
sibling app on another platform, has to satisfy.

## Two modes

|  | `online` | `onsite` |
|---|---|---|
| Case | Teams, Zoom, Meet | a meeting in a room |
| Start | suggestion popup, or manual | manual only |
| Audio | 2 channels: system + microphone | 1 channel: room microphone |
| Speaker `ME` | free, from channel 1 | not available — every speaker comes from diarization |
| Stop | auto-stop or manual | manual only |

`online` recordings get `ME` for free because the microphone is a physically
separate channel. `onsite` recordings have no such anchor; every speaker is a
diarization guess named `S1 … Sn`. Speaker labels are suggestions — the raw
diarizer segments stay in `transcript.json` so a reader can judge for itself.

Detection for `online` mode is Core Audio only: Steno watches which process is
reading the microphone. No calendar polling, no window scraping as a *detection*
signal.

## Installation

*Coming with the first release (M7).* Steno will be distributed as a zip
attached to a [GitHub release](https://github.com/maxnuglisch21m/steno/releases),
with in-app updates via Sparkle.

Until a Developer ID certificate is in place, builds are signed ad-hoc and are
not notarized. macOS will refuse to open such an app on the first try; use
**System Settings → Privacy & Security → Open Anyway**, or right-click the app
and choose **Open**.

## The menu

Steno has no window it insists on. The whole interface is the status item:

```
Aufnahme läuft · Vor Ort · 12:34      (only while recording, not a command)
Online-Meeting aufnehmen        ⌥⌘R
Vor-Ort-Meeting aufnehmen       ⌥⌘V
Aufnahme stoppen                ⌥⌘S   (only while recording)
—
Letztes Meeting im Finder zeigen
Ordner öffnen
—
Nach Updates suchen …                 (from the first release onwards)
Einstellungen …                  ⌘,
Beenden                          ⌘Q
```

The icon says what Steno is doing: a microphone outline when idle, a filled
microphone with a red dot and the running `mm:ss` while recording — plus a small
room glyph for `onsite` — and a progress ring while transcribing.

The three shortcuts are registered globally through Carbon's
`RegisterEventHotKey`, so they work while the menu is closed and without asking
for Accessibility permission. When a permission is missing, the record items are
disabled and say which one, both in the title and in the tooltip.

## Settings

Six tabs. The eleven settings from the specification come first within their
tab; the rest are the additions the plan accepted.

| Tab | Settings |
|---|---|
| **Allgemein** | recording folder (with a picker and a reveal button) · start at login · notification when a transcript is finished · show the onboarding again · version |
| **Aufnahme** | `onsite` input device (every `AVCaptureDevice`, refreshed on hot-plug) · auto-stop delay · ask for the speaker count · audio archive format (AAC / FLAC / WAV) · include the meeting title in the folder name |
| **Screenshots** | minimum interval and change threshold, each for a normal display and for the display holding the pointer · maximum image edge · JPEG quality · anchor-frame interval |
| **Transkription** | ASR version (Parakeet v3 / v2) · model status, download, and folder |
| **Regeln** | watchlist of bundle IDs, validated on entry · rules table (app · title pattern · regex · never/ask/always · on/off) · read calendar titles, off by default |
| **Updates** | check for updates automatically · check now |

Everything is stored as one JSON blob under a single `UserDefaults` key, and
decoding falls back per key, so a settings file written by an older build keeps
working.

## Permissions

Steno asks for these on first launch, in an onboarding window with four rows and
one button each — either "allow access" or a jump to the matching System
Settings pane:

| Permission | Why | Required for |
|---|---|---|
| Microphone | records your voice | both modes |
| System audio recording | taps the meeting app's audio output | `online` |
| Screen recording | screenshots, and window titles for rules | screenshots, rules |
| Models | ASR and diarization, downloaded once | the transcript, not the recording |
| Calendar (optional, off by default) | reads the title of the currently running event, to name folders and match rules for apps whose windows carry no title (Zoom, Meet) | rules and folder titles only |

The window re-checks every five seconds while it is open, and Steno re-checks
whenever it is brought forward, because these switches are flipped in another
process.

There is no API that reports whether system audio capture is allowed. Steno
answers the question by trying: it creates a throwaway global process tap and
destroys it immediately. Success means the permission is in place; the first
attempt is also what makes macOS show the prompt.

Missing models do **not** block a recording. Capture happens now, transcription
happens afterwards and can wait for a download.

Steno is **not** sandboxed — Core Audio process taps and ScreenCaptureKit make
that impossible. The hardened runtime is enabled.

For `onsite` recordings, check the microphone mode: macOS **Voice Isolation**
actively suppresses every voice but the closest one, which is exactly wrong for
a room. Steno refuses to record in that mode and offers to open the mode picker.
The single most effective quality lever is a boundary microphone on the table,
selectable in Settings.

## Building

Requires Xcode 26.6 (Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
`Steno.xcodeproj` is generated and not checked in.

```sh
brew install xcodegen xcbeautify
make gen      # generate Steno.xcodeproj from project.yml
make test     # StenoCore unit tests + the app test bundle
make build    # Release build into build/
make run      # Debug build, then open the app
```

The pure, framework-free logic lives in `Packages/StenoCore` (a local SwiftPM
package) and is unit-tested with Swift Testing:

```sh
swift test --package-path Packages/StenoCore
```

### Debug launch arguments

Debug builds accept three arguments, so the flow can be exercised without a
meeting, a microphone, or a click:

```sh
# Record for three seconds through the null recorder, then quit. Leaves a real
# meeting folder with a real meta.json behind.
open build/Build/Products/Debug/Steno.app --args --simulate-recording 3 onsite

open build/Build/Products/Debug/Steno.app --args --open-settings
open build/Build/Products/Debug/Steno.app --args --open-onboarding
```

They are compiled out of release builds: a shipped app has no business taking
instructions from its command line.

## Repository layout

```
project.yml                 XcodeGen project definition
Makefile                    gen · test · build · run · clean
Packages/StenoCore/         pure logic: merger, gate, naming, meta, WAV header, rules
Sources/Steno/              the app: App · Audio · Detection · Screenshots ·
                            Transcription · Storage · Settings · System · Update
Config/Steno.entitlements   audio input; not sandboxed
Tests/StenoTests/           thin app-hosted tests
scripts/                    changelog-extract.sh (release helpers follow in M7)
docs/SPEC.md                the specification this implements
docs/FORMAT.md              the on-disk contract downstream tools read
ThirdPartyLicenses/         FluidAudio (Apache-2.0) · Sparkle (MIT)
```

## Releasing

The pipeline itself lands in M7. The shape of it: update `CHANGELOG.md` so the
version has its own `## [x.y.z]` section, bump `MARKETING_VERSION` in
`project.yml`, then push a `vx.y.z` tag. A workflow builds, signs, packages,
generates the Sparkle appcast, and creates the GitHub release with the zip, the
appcast, and that changelog section as the notes. A release without its section
fails before it publishes anything —
`scripts/changelog-extract.sh x.y.z` is what checks that.

The full procedure, including how the Sparkle signing key is handled, is in
[CONTRIBUTING.md](CONTRIBUTING.md#releasing).

### Adding a Developer ID later

Until an Apple Developer ID certificate exists, builds are signed ad-hoc
(`CODE_SIGN_IDENTITY: "-"`) and are not notarized, which is why the first launch
needs the Gatekeeper detour above. Nothing needs to be rewritten to change that:
add the repository secrets `DEVELOPER_ID_P12_BASE64`, `APPLE_ID`,
`APPLE_TEAM_ID`, and `APPLE_APP_PASSWORD`, and the release workflow signs with
the certificate and notarizes automatically, falling back to ad-hoc when they are
absent. Sparkle updates keep working across the switch, because they are verified
by the EdDSA key rather than by the code signature.

## Dependencies

Two, both via SwiftPM, both pinned exactly:

- [FluidAudio](https://github.com/FluidInference/FluidAudio) 0.15.6
  (Apache-2.0) — on-device ASR (Parakeet TDT v3, multilingual) and offline
  diarization (pyannote community-1)
- [Sparkle](https://github.com/sparkle-project/Sparkle) 2.9.6 (MIT) — in-app
  updates

Everything else is a system framework: CoreAudio, AVFoundation,
ScreenCaptureKit, CoreGraphics, AppKit, EventKit, UserNotifications,
ServiceManagement. No Python, no ffmpeg, no server.

## Privacy

Everything happens on your Mac. Audio, screenshots, and transcripts never leave
it — Steno has no analytics, no crash reporting, and no account. The only
outbound connections are the one-time model download from Hugging Face and, if
enabled, the Sparkle update check against GitHub. After the models are cached,
Steno works with the network switched off.

Recording a meeting is not automatically legal or acceptable. **Tell the other
participants.** The suggestion popup says so on purpose.

## Known limits

These are properties of the approach, not bugs to be papered over:

- **Long-form seams.** Parakeet decodes in 15 s windows with 2 s overlap; words
  can be dropped or duplicated at the seams. `seamGapRepair` is on.
- **Diarization is wrong sometimes.** Roughly 18–20 % diarization error rate on
  AMI, and AMI *is* room audio — so `onsite` is the harder case, not the easier
  one.
- **`ME` exists only in `online` mode.** That is the price of a single
  microphone track.
- **Room audio lives on distance.** Past two metres, with table noise, or with
  two people talking at once, separation collapses.
- **Per-speaker tracks from Teams do not exist.** A process tap sees only the
  finished mix; individual streams are available exclusively through Teams'
  cloud compliance-recording API.

## Milestones

| | | Status |
|---|---|---|
| M0 | Menu-bar skeleton + permission onboarding | **done** |
| M1 | `onsite` audio + microphone-mode check | in progress |
| M2 | `online` audio: process tap + aggregate device, 2-channel WAV | planned |
| M3 | Meeting detection, suggestion popup, auto-stop, rules | planned |
| M4 | Screenshots across all displays | planned |
| M5 | ASR + diarization + merge | planned |
| M6 | Crash and interruption robustness | planned |
| M7 | Release pipeline and in-app updates | planned |

The acceptance tests need real meetings and are listed in `docs/SPEC.md` §11.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE). Third-party license texts are in
[ThirdPartyLicenses/](ThirdPartyLicenses/).
