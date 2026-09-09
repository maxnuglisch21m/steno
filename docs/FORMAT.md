# On-disk format

This is the contract between Steno and whatever reads its output. Steno produces raw
data and nothing else; every interpretation — summaries, context, exports — happens in
a separate tool that reads the files described here.

The field lists below are derived from the types in
[`Packages/StenoCore`](../Packages/StenoCore), which are the single definition of the
format:

| File | Type |
|---|---|
| `meta.json` | `MeetingMeta`, `MeetingState`, `MeetingMode`, `MeetingChannel`, `MeetingTrigger`, `AudioInputInfo`, `SpeakerHint`, `DisplayInfo`, `ModelIdentifiers` |
| folder name | `RecordingFolderName` |
| `screens.jsonl` | `ScreensIndexEntry` |
| `transcript.json` | `Transcript`, `Utterance`, `Token`, `DiarSegment`, `ModelIdentifiers` |
| `transcript.md` | `TranscriptMarkdownFormatter` |

**A sibling application on another platform has to satisfy exactly this format** —
same folder naming, same keys, same state lifecycle — so that the downstream tooling
does not need to know which machine a meeting was recorded on. Where this document
and the Swift types disagree, the types are right and this document is a bug.

---

## Folder layout

One folder per meeting, inside the recording root (`~/Meetings` by default). Steno
writes nothing outside that root, with one documented exception: the ASR and
diarization models are cached under
`~/Library/Application Support/Steno/Models`.

```
<root>/2026-09-09_1430_Teams/            # online mode
<root>/2026-09-09_1430_Vorort/           # onsite mode
  audio.m4a                              # or audio.flac / audio.wav — see meta.audio
  screens/
    143012_d0.jpg
    143012_d1_active.jpg
  screens.jsonl
  transcript.json
  transcript.md
  meta.json
```

Only `meta.json` is guaranteed to exist from the first second of a recording.
Everything else appears as it is produced: `screens.jsonl` and the images grow during
the recording, the two transcript files are written when transcription finishes, and
the audio file is renamed by the archive transcode at the very end.

A folder may also hold `_work/`, which is scratch space for the 16 kHz mono channel
files transcription runs on. It is deleted when transcription finishes. Treat any
`_work/` you find as debris from an interrupted run and ignore it.

### Folder naming

```
YYYY-MM-DD_HHMM_<label>[_<title-slug>][_<n>]
```

- `YYYY-MM-DD` and `HHMM` are the local wall clock at the start of the recording, in
  the time zone the recording was made in. The exact instant, with its UTC offset, is
  in `meta.started`.
- `<label>` is the triggering app's name for `online` (`Teams`, `Zoom`, `Chrome`),
  the literal `Vorort` for `onsite`, and `Online` for an `online` recording whose
  app is unknown — a manual start with no single meeting app identifiable, which is
  recorded with a system-wide tap and is therefore about the Mac rather than about
  one app. It is sanitized the same way a title slug is.
- `<title-slug>` is present only when a meeting title was known and the
  "include title in folder name" setting is on. German umlauts are transliterated
  (`ä` → `ae`, `ß` → `ss`), other diacritics are stripped (`é` → `e`), everything
  that is not an ASCII letter or digit becomes `-`, runs of `-` collapse, and the
  result is cut to 40 characters at a word boundary where one is close enough.
- `_<n>` is a collision suffix, `_2` through `_999`, appended only when the name is
  already taken.

The name is always a safe single path component: ASCII only, no `/`, no `:`, no `.`,
never starting with `.`.

A reader that wants to enumerate meetings should match this pattern **and** require a
`meta.json` inside — anything else in the recording root belongs to the user.

---

## `meta.json`

Rewritten on every state change. Pretty-printed with sorted keys, so consecutive
versions diff cleanly. Timestamps are ISO 8601 with a numeric offset
(`2026-09-09T14:30:12+02:00`), never the `Z`-suffixed UTC form: the local wall clock
is what makes the file readable next to the folder name.

### Required keys

| Key | Type | Meaning |
|---|---|---|
| `mode` | `"online"` \| `"onsite"` | Decides channels, speaker attribution, and how the recording may start and stop. |
| `started` | ISO 8601 | When capture began. |
| `ended` | ISO 8601 \| absent | When capture stopped. Absent while `state` is `recording`. |
| `duration` | number \| absent | Capture length in seconds. Absent while `state` is `recording`. |
| `trigger` | object | `{"kind":"manual"}` or `{"kind":"auto",…}`, either of which may carry `bundleId` and `name`. See below. |
| `channels` | array | `["room"]` for `onsite`, `["system","mic"]` for `online`, in channel order. |
| `input` | object | `{"device": string, "microphoneMode": string \| absent}`. See below. |
| `displays` | array | `[{"index":0,"id":1,"px":[3840,2160]}, …]`, in the order the screenshot file names use. |
| `screenshots` | integer | Number of images written, i.e. lines in `screens.jsonl`. |
| `app` | string | Steno's marketing version. |
| `state` | string | See the lifecycle below. |

### Added keys

Every one of these is optional. A reader written against the required set above keeps
working when they are absent.

| Key | Type | Meaning |
|---|---|---|
| `title` | string | Meeting title from the triggering app's window or a calendar event. |
| `audio` | string | File name of the audio archive: `audio.m4a`, `audio.flac`, or `audio.wav`. Absent when no audio file was written. |
| `appBuild` | string | Steno's build number. |
| `os` | string | The macOS version the recording was made on, e.g. `26.6.0`. |
| `models` | object | `{"asr": string, "diarizer": string}`. Written when transcription finishes. |
| `error` | string | Why the recording ended in `failed`. Written together with that state. |
| `speakers` | object | `{"expected": integer}` — how many people the user said were in the room. `onsite` only, and only when asked. See below. |
| `stopReason` | string | What ended the capture: `manual`, `auto`, `sleep`, or `deviceLost`. See below. |

### `trigger`

```json
"trigger": {"kind": "manual", "bundleId": "com.microsoft.teams2", "name": "Teams"}
```

| Key | Type | Meaning |
|---|---|---|
| `kind` | `"manual"` \| `"auto"` | `manual` = started from the menu or a hotkey. `auto` = started by detection, from the suggestion popup or an `always` rule. |
| `bundleId` | string \| absent | The app whose audio was tapped. `online` only. |
| `name` | string \| absent | That app's display name, the same string the folder is named after. |

**`kind: "manual"` may carry an app too**, and a reader must not treat `bundleId` as
proof that detection fired. When an `online` recording is started by hand, Steno asks
Core Audio which processes are reading the microphone: if exactly one of them is on the
watchlist, that app is what the tap points at, and it is recorded here and in the folder
name. `kind` still says `manual`, because that is what it was — the two facts are
independent, and conflating them would make "did the user start this?" unanswerable.

Both keys are absent when no single app could be identified. The recording is then made
with a system-wide tap and the folder is named `…_Online`.

**`kind: "auto"` always carries both.** A recording detection started knows which
watchlist entry triggered it, by construction — the entry *is* the identity of the
meeting. `bundleId` is the watchlist entry's identifier, not the identifier of the
individual process that was reading the microphone: Chrome and Edge and Teams run their
audio in helper processes (`com.google.Chrome.helper`), all of which are tapped
together, and all of which are recorded here as the entry they belong to.

### `stopReason`

```json
"stopReason": "auto"
```

| Value | Meaning |
|---|---|
| `manual` | The user pressed stop, in the menu or with ⌥⌘S. |
| `auto` | Detection saw no watched process reading the microphone for `autoStopDelay` seconds (specification §2, 30 s by default). `online` only — an `onsite` recording never stops itself. |
| `sleep` | The Mac went to sleep. The recording was closed before the machine suspended. |
| `deviceLost` | The input device disappeared, or capture was ended by the system. |

Absent while `state` is `recording`, and absent for a recording whose ending nothing
could account for — a failed write, for instance, where `error` says what happened and
nothing was lost from the device.

**It says nothing about success.** A recording can end for any of these reasons and
still be `done`; `deviceLost` and a `failed` state usually travel together, but the two
fields answer different questions and neither implies the other.

### `title`

```json
"title": "Weekly Sync"
```

The meeting's name, when one could be found. Two sources, in this order:

1. **The triggering app's window title**, read through `CGWindowListCopyWindowInfo` and
   stripped of the app's own decoration: `Weekly Sync | Microsoft Teams` becomes
   `Weekly Sync`, `(3) Design Review - Google Meet - Google Chrome` becomes
   `Design Review`. Needs Screen Recording; without it, no title is read at all.
2. **The calendar event running now**, if — and only if — the "read the running
   calendar event's title" setting is on *and* macOS has granted calendar access. Off by
   default. It exists because Zoom's window says nothing but `Zoom Meeting` and a Google
   Meet tab shows the room code.

A title that names the app rather than the meeting (`Microsoft Teams`, `Zoom Meeting`,
`Meet`, a room code like `abc-defg-hij`) is treated as no title at all: the key is then
absent, the folder is named after the app alone, and rules match on the app.

The same string, sanitized, becomes the folder's title slug when the "include the title
in the folder name" setting is on.

### `input`

```json
"input": {"device": "Tisch-Grenzflächenmikrofon", "microphoneMode": "wideSpectrum"}
```

| Key | Type | Meaning |
|---|---|---|
| `device` | string | Display name of the microphone that actually recorded — not the one that was configured, if that one turned out not to be attached. |
| `microphoneMode` | string \| absent | The system-wide macOS microphone mode in force when the recording started. Absent when the recorder does not know it. |

`microphoneMode` is one of exactly three values, matching
`AVCaptureDevice.MicrophoneMode`:

| Value | Meaning |
|---|---|
| `wideSpectrum` | Minimal processing, the whole room. What an `onsite` recording wants. |
| `standard` | Light processing. Usable, and the recording says so in the menu while it runs. |
| `voiceIsolation` | macOS damps every voice but the closest one. Steno **refuses** to start an `onsite` recording in this mode, so it should never appear on an `onsite` recording made by Steno — a file that carries it was made some other way, and its non-primary speakers are attenuated or gone. |

`online` recordings are not gated on the mode: there the microphone channel is the
user's own voice, and isolating it does no harm.

### `speakers`

```json
"speakers": {"expected": 4}
```

Present only when the user was asked — an `onsite` setting that is off by default —
and answered with a number rather than "automatic". It is a **hint**, never a
measurement: it is fed to the diarizer as an upper and a lower bound on the speaker
count, and it says nothing about how many speakers the transcript actually has. A
reader must not treat it as a fact about the meeting, and should ignore a value
outside 2–8.

### `channels`

| Value | Meaning |
|---|---|
| `room` | The room microphone of an `onsite` recording — channel 0. |
| `system` | The tapped system audio of an `online` recording, downmixed to mono — channel 0. |
| `mic` | The microphone of an `online` recording — channel 1. |

`channels` is what makes an audio file interpretable: an `online` `audio.wav` is two
channels in exactly that order, and channel 1 is unambiguously the person holding the
Mac. That is the physical anchor the speaker `ME` comes from, and it is the only
reason `ME` exists at all.

### State lifecycle

```
recording ──► transcribing ──► done
    │              │
    └──► failed ◄──┘
              │
              └──► transcribing        (a retry)
```

| State | Meaning |
|---|---|
| `recording` | Audio and screenshots are being captured. |
| `transcribing` | Capture finished; ASR, diarization, and merging are running. |
| `done` | Transcript and audio archive are written. Terminal. |
| `failed` | Something went wrong; `error` says what. May be retried, which moves it back to `transcribing`. |

No other transition is legal, and `MeetingState.transition(to:)` throws on one that is
not — including a transition to the state already held, because rewriting `meta.json`
with the same state is a logic error rather than a harmless no-op.

The state is written continuously so that a crash is detectable. On the next launch:

- a folder still reading `recording` was interrupted mid-recording. Its WAV header has
  to be repaired from the file length (`WAVHeader.repair`), `ended` derived from the
  audio file's modification time, and the folder queued for transcription.
- a folder reading `transcribing` has to be queued again.
- a folder reading `done` or `failed` is left alone.

### Example — `online`

```json
{
  "app": "0.1.0",
  "appBuild": "1",
  "audio": "audio.m4a",
  "channels": ["system", "mic"],
  "displays": [
    {"id": 1, "index": 0, "px": [3840, 2160]},
    {"id": 2, "index": 1, "px": [2560, 1440]}
  ],
  "duration": 2552,
  "ended": "2026-09-09T15:12:44+02:00",
  "input": {"device": "MacBook Pro Mikrofon"},
  "mode": "online",
  "models": {"asr": "parakeet-tdt-0.6b-v3", "diarizer": "speaker-diarization"},
  "os": "26.6.0",
  "screenshots": 214,
  "started": "2026-09-09T14:30:12+02:00",
  "state": "done",
  "stopReason": "auto",
  "title": "Weekly Sync",
  "trigger": {"bundleId": "com.microsoft.teams2", "kind": "auto", "name": "Teams"}
}
```

### Example — `onsite`

```json
{
  "app": "0.1.0",
  "appBuild": "1",
  "audio": "audio.m4a",
  "channels": ["room"],
  "displays": [{"id": 1, "index": 0, "px": [3840, 2160]}],
  "duration": 1800,
  "ended": "2026-09-09T15:00:12+02:00",
  "input": {"device": "Tisch-Grenzflächenmikrofon", "microphoneMode": "wideSpectrum"},
  "mode": "onsite",
  "models": {"asr": "parakeet-tdt-0.6b-v3", "diarizer": "speaker-diarization"},
  "os": "26.6.0",
  "screenshots": 31,
  "speakers": {"expected": 4},
  "started": "2026-09-09T14:30:12+02:00",
  "state": "done",
  "stopReason": "manual",
  "trigger": {"kind": "manual"}
}
```

---

## `audio.*`

Recording is always lossless WAV, streamed to disk:

| Mode | Format |
|---|---|
| `online` | 48 kHz, 16-bit PCM, 2 channels: ch0 system audio downmixed to mono, ch1 microphone |
| `onsite` | 48 kHz, 16-bit PCM, 1 channel: the room microphone |

WAV rather than a compressed container because a container cannot be recovered after
a crash and a WAV can: the RIFF and `data` sizes are repairable from the file length
alone. Transcription runs on this file. Only afterwards is it transcoded per the
archive setting — AAC-LC `audio.m4a` by default, FLAC, or the WAV kept as it is — and
`meta.audio` names the result. Transcript quality therefore never depends on the
archive format.

No processing is applied on the way in: no AGC, no noise gate, no normalization. The
raw signal goes to the models, because every kind of sharpening makes diarization
worse rather than better. The one arithmetic operation an `online` recording performs
is the downmix of the tap's channels to mono for ch0 — an unweighted mean, because ch0
is one voice channel and a meeting app's stereo mix carries no information in its
stereo image.

The two channels of an `online` file are **sample-aligned for the whole recording**.
They come from one Core Audio aggregate device holding both the microphone and the
process tap, so they share a clock and arrive in the same callback; the microphone is
the clock master and the tap follows it with drift compensation. Two separate captures
would drift apart over an hour, which is why the specification calls that the fallback
rather than the design. Nothing in `meta.json` is needed to line the channels up: frame
*n* of ch0 and frame *n* of ch1 happened at the same moment.

---

## `screens/` and `screens.jsonl`

Screenshots are event-driven, not periodic: every display is captured at 1 fps, and a
frame becomes a file only when enough of the display changed and enough time has
passed, with the display holding the pointer on shorter intervals and a lower
threshold. Each display additionally gets an anchor frame at the start and then every
120 seconds regardless of change, so a static monitor is not simply absent.

File names: `HHmmss_d<index>[_active].jpg`, e.g. `143012_d1_active.jpg`.

- `HHmmss` is the local wall clock at capture.
- `<index>` matches `meta.displays[].index`.
- `_active` marks the display that held the pointer.
- JPEG, quality 0.8 by default, longer edge ≤ 1920 px by default.

`screens.jsonl` has one JSON object per line, appended the moment the image is
written — not assembled at the end, so an interrupted recording still has an index for
every file it managed to write.

```json
{"t":18.42,"file":"screens/143012_d1_active.jpg","display":1,"active":true,"changed":0.31}
```

| Key | Type | Meaning |
|---|---|---|
| `t` | number | Seconds since the start of the recording, two decimals. |
| `file` | string | Path relative to the meeting folder, including the `screens/` prefix. |
| `display` | integer | Matches `meta.displays[].index`. |
| `active` | boolean | Whether this display held the pointer. |
| `changed` | number | Share of the display area that changed, 0…1, two decimals. |

Key order is fixed and the two numbers carry two decimals, so the lines are stable and
readable rather than a binary round trip of a `Double`.

`t` is the bridge: it is how a reader lines a screenshot up against a transcript line,
whose `start` is measured from the same zero.

The last line of the file may be truncated if the app was killed mid-append. A reader
should skip a line it cannot parse rather than rejecting the file.

---

## `transcript.json`

The machine-readable truth. Pretty-printed with sorted keys.

```json
{
  "confidence": {"asr_mic": null, "asr_room": 0.89},
  "diarization": [{"end": 22.1, "speaker": "S1", "start": 15.4}],
  "mode": "onsite",
  "models": {"asr": "parakeet-tdt-0.6b-v3", "diarizer": "speaker-diarization"},
  "utterances": [
    {
      "end": 15.02,
      "speaker": "S1",
      "start": 12.3,
      "text": "Also der Centerplan …",
      "tokens": [{"t": 12.3, "w": "Also"}]
    }
  ]
}
```

| Key | Type | Meaning |
|---|---|---|
| `mode` | `"online"` \| `"onsite"` | Same value as in `meta.json`. |
| `utterances` | array | One continuous stretch of speech by one speaker, sorted by `start`. |
| `utterances[].speaker` | string | `ME`, `S1`…`Sn`, or `UNKNOWN`. |
| `utterances[].start`, `.end` | number | Seconds since the start of the recording. |
| `utterances[].text` | string | The speech. |
| `utterances[].tokens` | array | `{"t": start in seconds, "w": word}`. |
| `diarization` | array | The diarizer's raw segments, `{"speaker","start","end"}`, before any merging. |
| `models` | object | `{"asr","diarizer"}`. |
| `confidence` | object | `{"asr_room","asr_mic"}`, mean per-token ASR confidence per source. Always both keys; a source that did not exist is an explicit `null`. |

### How speakers are assigned

Each recognized token gets the speaker of the diarization segment covering its
**midpoint** — not its edges, which is exactly where the recognizer and the diarizer
disagree most. A token no segment covers becomes `UNKNOWN`. Tokens are then sorted by
start time and consecutive tokens of the same speaker are bundled into one utterance;
a **gap of more than 0.8 s** starts a new one.

Diarized speakers are renumbered `S1`, `S2`, … by first appearance, so `S1` is
whoever spoke first.

The only difference between the modes:

- **`online`** — tokens from the microphone channel override diarization and become
  `ME`. Physics beats the model.
- **`onsite`** — there is no microphone channel. Every speaker is `S1 … Sn`, and the
  app does not guess which is the user.

`diarization` keeps the raw segments on purpose. Diarization error rate runs around
18–20 % on room audio, so speaker labels are suggestions; a reader that can see the
raw segments can judge them instead of trusting a smoothed-over guess.

---

## `transcript.md`

For reading, and for handing to a downstream tool that wants text. The header labels
are English and fixed: this file is part of the data contract, not interface text, so
it does not change with the interface language. Only the transcribed speech is in
whatever language the meeting was held in.

```
# Steno transcript

- Mode: onsite
- Started: 2026-09-09T14:30:12+02:00
- Duration: 00:42:32
- Speakers: S1, S2, S3
- ASR model: parakeet-tdt-0.6b-v3
- Diarization model: speaker-diarization
- Confidence (room): 0.89

[00:00:12] S1: Also der Centerplan ist durch.
[00:00:15] S2: Dann können wir den Druck freigeben.
```

- The header is a bullet list, then one blank line, then one line per utterance.
- `- Started:` is omitted when the start time is unknown.
- `- Confidence (mic):` appears only for `online`.
- Line format: `[HH:MM:SS] <speaker>: <text>`. Hours count upwards rather than
  wrapping at 24.
- A transcript with no recognized speech has the single line
  `_No speech was recognized._` in place of the utterances.

---

## Known limits worth carrying downstream

These are properties of the approach, not defects to be papered over. A tool reading
these files should assume them.

- **Long-form seams.** Parakeet decodes in 15 s windows with 2 s overlap; words can be
  dropped or duplicated at the seams even with seam-gap repair on.
- **Speaker labels are suggestions.** Roughly 18–20 % diarization error rate on room
  audio, and room audio is what `onsite` is.
- **`ME` exists only in `online` mode.** That is the price of a single microphone
  track, not a bug.
- **Per-speaker tracks from a meeting app do not exist.** A process tap sees only the
  finished mix.
