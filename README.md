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
Aufnahme läuft · Teams · 12:34        (only while recording, not a command)
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

The first line names the recorded app while an `online` recording runs, and the mode
(`Vor Ort`) otherwise.

The icon says what Steno is doing: a microphone outline when idle, a filled
microphone with a red dot and the running `mm:ss` while recording — plus a small
room glyph for `onsite` — and a progress ring while transcribing.

The three shortcuts are registered globally through Carbon's
`RegisterEventHotKey`, so they work while the menu is closed and without asking
for Accessibility permission. When a permission is missing, the record items are
disabled and say which one, both in the title and in the tooltip.

## Recording

`audio.wav` is always 48 kHz 16-bit PCM, written straight to disk as it arrives —
one channel for `onsite`, two for `online`. Nothing is buffered in memory, so an
hour-long recording survives a crash: a WAV's own length fields are the only thing
that breaks, and they are recomputable from the file. **No processing is applied.**
No automatic gain control, no noise gate, no normalization, no voice processing.
Every kind of sharpening makes speaker separation worse rather than better.

### `online`: what is actually captured

Two channels in one file, from **one** Core Audio aggregate device that holds the
microphone and a process tap at the same time. That is the whole design: one device
means one clock and one callback, so channel 0 and channel 1 stay sample-aligned for
the length of a meeting. Two separate captures would drift apart over an hour.

| Channel | Content |
|---|---|
| ch0 | the tapped system audio, every tap channel averaged to mono |
| ch1 | the microphone's first channel — you |

The tap points at the meeting app when Steno can name one: on a manual start it asks
Core Audio which processes are reading the microphone, and if exactly one of them is on
the watchlist, that app is what gets tapped. The folder is then named after it
(`…_Teams`) and `meta.trigger` records it, even though `kind` stays `manual`. If nothing
is identifiable, or two watchlist apps are live at once, the tap is system-wide with
Steno itself excluded, and the folder is called `…_Online`. A system-wide tap records
everything the Mac is playing, music included.

**There are no per-speaker tracks.** A process tap sees the meeting app's finished mix
and nothing else; Teams hands out individual participant streams only through its
cloud compliance-recording API, which is not something a local recorder can reach.
Separating the other participants is therefore diarization's job, on ch0, after the
recording. Channel 1 is the compensation: it is physically separate, it is always you,
and it never needs a model to say so.

Nothing is muted while recording — the meeting is heard normally throughout — and the
aggregate device is private, so it never shows up in Sound settings or in any other
app's device list.

### `onsite`: three things that are not code

Three things decide whether a room recording is worth transcribing, and none of them
is code.

**Input device.** The default is whatever macOS considers the input; any device
from `AVCaptureDevice.devices(for: .audio)` can be chosen instead under
**Einstellungen → Aufnahme**. A USB boundary microphone in the middle of the table
is the single most effective quality lever there is, and it costs nothing in code —
past about two metres, with table noise, or with two people talking at once,
separation collapses regardless of the model. The device that actually recorded is
named in `meta.input.device`; if the configured one is not attached, Steno records on
the system default and says so there rather than refusing.

**Microphone mode.** macOS applies one of three modes system-wide, from Control
Centre, and Steno reads it before every `onsite` recording:

| Mode | What Steno does |
|---|---|
| **Breites Spektrum** | records, in silence — this is the one a room wants |
| **Standard** | records, and puts a hint in the menu for as long as the recording runs |
| **Sprachisolierung** | **refuses**, with a dialog and a button that opens the microphone-mode interface |

Voice Isolation damps every voice but the closest one, which is the exact opposite of
a room recording: the other participants — the reason for recording — arrive
attenuated or gone. Refusing beats producing a file that looks fine and is useless.
The mode is read again on the next start, so changing it in Control Centre and
pressing record is all it takes. `online` recordings are not gated on it: there the
microphone channel is your own voice, and isolating it does no harm. The mode that
was in force is recorded in `meta.input.microphoneMode`.

**Speaker count.** Off by default. Turn on **Sprecherzahl vor einer
Vor-Ort-Aufnahme abfragen** and a small dialog asks how many people are in the room
before recording starts — "Automatisch", or 2 through 8. The answer goes into
`meta.speakers.expected` and becomes the diarizer's lower and upper bound when the
transcript is made. It is a hint, not a measurement.

If the microphone is unplugged mid-recording, the audio hardware changes underneath a
recording, or the volume fills up, the recording ends by itself: the file is closed so
that what was captured stays playable, the folder is marked `failed` with the reason in
`meta.error`, and the menu says what happened. An `online` recording survives a change
it can be rebuilt around — the default input moving, a device changing its sample rate —
by building a new tap and aggregate device within two seconds and continuing into the
same file.

Starting and stopping are both on a fifteen-second deadline. Nothing in Core Audio has a
timeout of its own, and `coreaudiod` does occasionally get into a state where every call
that opens an input blocks forever; without the deadline the menu would sit there
refusing every start with "a recording is already running" until Steno was relaunched.
Instead the folder is marked `failed`, the menu goes back to idle, and the reason says
what actually fixes it: restart the Mac, or `sudo killall coreaudiod`.

## Screenshots

Every display is captured for the length of the recording, in both modes — `onsite`
included, where the screen rarely changes and therefore costs almost nothing.

**Event-driven, not on a timer.** Each display gets its own `SCStream` at one frame a
second. ScreenCaptureKit reports a frame status of `.idle` for a display that did not
change, which is what replaces comparing images: Steno never decodes a frame it is not
going to keep. The frames that are left carry the compositor's dirty rectangles, whose
summed area over the frame area is the changed share.

A frame becomes a file only when **both** the interval and the change threshold are
met:

| | Normal display | Display holding the pointer |
|---|---|---|
| Minimum since the last image | 5 s | 2 s |
| Changed area | ≥ 2 % | ≥ 0.5 % |

The display holding the pointer is worked out from `NSEvent.mouseLocation` against the
screen list, freshly for every candidate frame — that is where the meeting is actually
happening, so it gets the shorter interval and the lower threshold. All five numbers
are in **Einstellungen → Screenshots**.

**Anchor frames.** Every display also gets one image at the start and one every 120 s
regardless of what changed, so a static second monitor is not simply absent from an
hour-long meeting. Those cannot come from the stream — a display that never changes
never produces a frame — so an overdue display is captured out of band with
`SCScreenshotManager`, and the same gate decides whether to keep it.

Images are JPEG, quality 0.8, longer edge at most 1920 px, named
`HHmmss_d<index>[_active].jpg` in `screens/`. Two frames of one display inside the same
wall-clock second get `_2`, `_3` appended, because the index already names both.
`screens.jsonl` gets its line the moment the file is written and is flushed straight
away, so a recording that was killed still has an index for everything it managed to
save. The full format is in [docs/FORMAT.md](docs/FORMAT.md).

### Privacy

- **Steno's own windows are never in a screenshot.** The suggestion panel, the settings
  window, and the onboarding window are excluded from every display's content filter,
  which is rebuilt whenever one of them opens or closes. A recorder that photographs
  its own popup is both useless and a small leak, and the panel is on screen exactly
  when something interesting is happening.
- **A locked screen is not captured.** While the Mac is locked, frames are discarded —
  the audio keeps recording, which is correct for a meeting that carries on, but two
  hundred images of the lock wallpaper are two hundred images of nothing. The streams
  are left running, so unlocking resumes immediately.
- Nothing is analysed. No OCR, no thumbnails, no upload — the images are scaled and
  encoded, and that is all.
- Without the Screen Recording permission, a recording simply has no screenshots and
  says so in the log. It is never a reason to lose the audio, and neither is a display
  that refuses to start, a stream that stops mid-meeting (it gets one restart), or a
  disk that fills up.

Displays plugged in or unplugged mid-meeting are handled: a new one is appended to
`meta.displays` and starts producing images, a removed one stops. **Indices are never
renumbered**, because the file names and `screens.jsonl` already point at them.

`scripts/verify-recording.sh <folder>` checks a finished folder against all of this —
every index line parses, every file exists, no two images of a display are closer than
the configured interval, `meta.screenshots` matches the line count, and nothing was
written into the folder that does not belong there.

## Detection, rules, and the suggestion

An `online` recording usually starts itself. The signal is Core Audio and nothing
else: since macOS 14.4 the HAL says which process is reading a microphone
(`kAudioHardwarePropertyProcessObjectList` → `kAudioProcessPropertyIsRunningInput`),
and that is what a meeting looks like from the outside. No calendar, no window
inspection, no accessibility API.

**Watchlist and helper processes.** A watchlist entry matches its own bundle
identifier *and everything below it in the dotted namespace*, because Chrome, Edge,
and Teams do not capture or play a meeting in the process the user launched — they
hand it to a helper called `com.google.Chrome.helper` or
`com.microsoft.teams2.helper.renderer`, and which helper it is changes between calls.
So `com.google.Chrome` on the watchlist means Chrome and all of its helpers, they
count as one meeting, and the process tap covers all of them at once.

**The timings**, all of them from specification §2 and all of them tested against a
clock rather than a stopwatch:

| | |
|---|---|
| Trigger | a watched app reads the microphone for **≥ 5 s** |
| Auto-stop | **no** process of that app has read it for **≥ 30 s** (configurable) |
| Ask again | only after the app has been quiet for **≥ 60 s** — one question per meeting |

Detection is event-driven: a listener on the process list, and one on
`IsRunningInput` of every audio process, added and removed as processes come and go.
A one-second tick advances the clock — a listener can say *that* something changed,
never that five seconds have passed with nothing changing. If the HAL refuses the
listeners, detection says so in the log and falls back to a two-second poll.

**What happens when the trigger fires**

1. **The meeting is given a name.** The triggering app's window titles are read
   (`CGWindowListCopyWindowInfo`, layer 0, biggest window first) and stripped of the
   app's decoration: `Weekly Sync | Microsoft Teams` → `Weekly Sync`. A title that is
   only the app's name — `Zoom Meeting`, `Meet`, a room code like `abc-defg-hij` —
   counts as no title, and the search is repeated every 2 s for up to 10 s, because
   Teams renames its window only once the call is actually joined. If nothing usable
   turns up and the calendar setting is on, the running calendar event's title is used
   instead.
2. **The rules decide.** First enabled match wins, in the order they are arranged in
   Settings → Regeln, matched against the app and every title found (cleaned *and*
   raw): `never` records nothing and shows nothing, `always` starts recording at once,
   `ask` — and no match at all — shows the suggestion.
3. **The suggestion** is a borderless panel in the top-right corner, above everything,
   on every Space:

   ```
   „Weekly Sync“ läuft in Teams. Aufnehmen?
   [ Aufnehmen ]  [ Ignorieren ]
   Teilnehmer informieren.
   ```

   It does not activate Steno or take the keyboard away from the meeting, but it does
   accept Return (record) and Escape (ignore). After **20 s** without an answer it
   fades out, and that counts as ignoring it.

**While a recording runs, new triggers are ignored** (specification §1) — but
detection keeps watching, because the same machinery is what ends the recording:
when no process of the recorded app has read the microphone for the auto-stop delay,
the recording stops itself and `meta.json` records `"stopReason": "auto"`. An
`onsite` recording never auto-stops: a room full of people is not over because
nobody's Mac is using a microphone.

**Sleep and the lock screen.** `NSWorkspace.willSleepNotification` stops a running
recording before the machine suspends — capture is about to end whether Steno agrees
or not, and a folder that says `"stopReason": "sleep"` is worth far more than audio
that stops mid-sentence behind a header that was never finished. The lock screen
(`com.apple.screenIsLocked`) does not touch audio — a locked Mac keeps recording the
meeting — but the screenshot capturer is told, and discards frames until the screen
is unlocked rather than filling a folder with two hundred pictures of the lock
wallpaper.

**Notifications.** A recording that fails posts one, with an "Im Finder zeigen"
action; a finished transcript will, from M5. Permission for them is asked for in
exactly two places — the onboarding window's "Fertig" button and the Settings toggle
— and never at launch. Before posting anything, Steno reads the authorization status
and stays quiet unless it is granted.

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

Debug builds accept a few arguments, so the flow can be exercised without a
meeting, a click, or — where it is not the point — a microphone:

```sh
# Record for 15 seconds through the real recorder, then quit. Leaves a meeting
# folder with a real audio.wav and a real meta.json behind.
open build/Build/Products/Debug/Steno.app --args --simulate-recording 15 onsite

# An online recording: process tap plus microphone, two channels. With no meeting app
# running this taps the whole system, so anything playing lands in channel 0.
open build/Build/Products/Debug/Steno.app --args --simulate-recording 12 online

# The same, with the tap forced at one app instead of whatever detection would pick.
open build/Build/Products/Debug/Steno.app --args --simulate-recording 12 online --tap-target com.microsoft.teams2

# The same flow with no hardware at all: folder and meta.json, no audio.
open build/Build/Products/Debug/Steno.app --args --simulate-null-recording 3 online

# Detection end to end, with an invented process list: trigger, rules, popup,
# recording, auto-stop. Everything downstream of "is Teams reading the microphone"
# is the real thing. --auto-answer clicks the panel, --auto-stop shortens the
# 30 s silence, --simulate-detection-end ends the fake meeting after n seconds.
open build/Build/Products/Debug/Steno.app --args \
  --simulate-detection com.microsoft.teams2 "Weekly Sync" \
  --auto-answer record --auto-stop 5 --simulate-detection-end 8

# The same with a rule, and with no hardware at all.
open build/Build/Products/Debug/Steno.app --args \
  --simulate-detection com.microsoft.teams2 "Weekly Sync" \
  --rule never Weekly --null-recorder

# Screenshots on their own: no audio, and one log line per gate decision — display,
# active, changed share, verdict.
open build/Build/Products/Debug/Steno.app --args \
  --simulate-recording 30 onsite --null-recorder --screenshot-log

# Print the microphone mode Steno sees, and what the on-site gate makes of it.
open build/Build/Products/Debug/Steno.app --args --print-microphone-mode

open build/Build/Products/Debug/Steno.app --args --open-settings
open build/Build/Products/Debug/Steno.app --args --open-onboarding
```

The results are written to stderr and to the unified log, so a run can be checked
without looking at the screen:

```sh
log stream --predicate 'subsystem == "de.21m.steno" && category == "audio"'
log stream --predicate 'subsystem == "de.21m.steno" && category == "screens"'
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
scripts/                    verify-recording.sh (specification §11.8/§11.11) ·
                            changelog-extract.sh (release helpers follow in M7)
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
| M1 | `onsite` audio + microphone-mode check | **done** |
| M2 | `online` audio: process tap + aggregate device, 2-channel WAV | **done** |
| M3 | Meeting detection, suggestion popup, auto-stop, rules | **done** |
| M4 | Screenshots across all displays | **done** |
| M5 | ASR + diarization + merge | planned |
| M6 | Crash and interruption robustness | planned |
| M7 | Release pipeline and in-app updates | planned |

The acceptance tests need real meetings and are listed in `docs/SPEC.md` §11.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT — see [LICENSE](LICENSE). Third-party license texts are in
[ThirdPartyLicenses/](ThirdPartyLicenses/).
