# Spec — Meeting Recorder (macOS Menüleisten-App)

**Version** 1.1 · 2026-09-09
**Ziel** Rohdaten-Recorder. Nimmt Meetings auf (Audio + Screenshots), transkribiert lokal mit Sprechertrennung, legt alles als Dateien ab. **Nichts weiter.**
**Nicht-Ziel** Zusammenfassung, Kontext, Obsidian-Export, OCR, Cloud. Das macht ein separater, manuell getriggerter Claude-Skill auf den abgelegten Dateien.

---

## 0. Rahmen

| | |
|---|---|
| Zielsystem | macOS 15+, Apple Silicon |
| Sprache | Swift 6, SwiftUI (`MenuBarExtra`) + AppKit |
| Sandbox | **aus** (Process Taps + Screen Recording). Hardened Runtime an. |
| Netzwerk | nur einmaliger Modell-Download (Hugging Face). Danach 100 % offline. |
| Abhängigkeit | **FluidAudio** (SPM, Apache-2.0) — `https://github.com/FluidInference/FluidAudio`, ab `0.12.4` |
| Sonst | nur System-Frameworks: CoreAudio, AVFoundation, ScreenCaptureKit, CoreGraphics, AppKit, UserNotifications, ServiceManagement |

Kein Python, kein ffmpeg, kein Homebrew, kein Server. Alles in einem Prozess.

---

## 1. Zwei Modi

Alles Weitere hängt an dieser einen Verzweigung. Sie steht in `meta.json` und entscheidet über Kanäle, Sprecherzuordnung und Auslöser.

| | **`online`** | **`onsite`** |
|---|---|---|
| Fall | Teams, Zoom, Meet | Besprechung im Raum |
| Start | Popup-Vorschlag (§2) oder manuell | **nur manuell** |
| Audio | 2 Kanäle: System + Mikrofon | 1 Kanal: Raum-Mikrofon |
| Sprecher `ME` | geschenkt, aus ch1 | **nicht verfügbar** — alle Sprecher aus der Diarisierung |
| Screenshots | ja | ja, unverändert (Bildschirm ändert sich selten, kostet also fast nichts) |
| Stop | Auto-Stop oder manuell | **nur manuell** |

Läuft eine Aufnahme, werden neue Auslöser ignoriert.

---

## 2. Meeting-Erkennung (nur `online`)

Core Audio verrät ab macOS 14.4, welcher Prozess gerade das Mikrofon liest. Das ist das Signal — kein Kalender, keine Fensterinspektion.

**Mechanik**
1. `kAudioHardwarePropertyProcessObjectList` auf `kAudioObjectSystemObject` → `[AudioObjectID]`.
2. Pro Objekt lesen: `kAudioProcessPropertyBundleID`, `kAudioProcessPropertyPID`, `kAudioProcessPropertyIsRunningInput`.
3. `AudioObjectAddPropertyListenerBlock` auf die Prozessliste **und** auf `IsRunningInput` jedes beobachteten Prozesses. Event-getrieben, kein Polling.
   *Erlaubter erster Wurf: 2-Sekunden-Polling. Später auf Listener umbauen.*

**Watchlist** (in Settings editierbar, Defaults):
```
com.microsoft.teams2      Teams
com.microsoft.teams       Teams (classic)
us.zoom.xos               Zoom
com.google.Chrome         Browser-Meetings (Meet, Webex)
com.microsoft.edge        Browser-Meetings
com.apple.Safari          Browser-Meetings
app.zen-browser.zen       Browser-Meetings
```

**Trigger** — ein Prozess der Watchlist wechselt `IsRunningInput` false → true und bleibt **≥ 5 s** true → Vorschlag anzeigen.

**Vorschlag** — randloses `NSPanel`, oben rechts, über allen Fenstern:
> **Teams-Meeting läuft.** Aufnehmen?
> [ Aufnehmen ]  [ Ignorieren ]
> *Teilnehmer informieren.*

Nach **20 s** ohne Klick verschwindet es = Ignorieren. Pro Meeting nur einmal fragen (gleiche Bundle-ID, bis `IsRunningInput` mindestens 60 s false war).

**Auto-Stop** — kein beobachteter Prozess mehr `IsRunningInput == true` für **≥ 30 s** → Aufnahme beenden, Verarbeitung starten.

---

## 3. Audio

### 3a. Modus `online` — eine Datei, zwei Kanäle, sample-genau synchron

```
audio.wav   48 kHz · 16-bit PCM · 2 ch
            ch0 = System-Audio (Teams-Mix, auf Mono gedownmixt)
            ch1 = Mikrofon (Mono)
```

1. Prozess-Tap auf die getriggerte App:
   `kAudioHardwarePropertyTranslatePIDToProcessObject` → `AudioHardwareCreateProcessTap()`.
2. **Ein** Aggregate-Device (`AudioHardwareCreateAggregateDevice()`) mit dem Tap **und** dem Input-Device als Sub-Devices → ein gemeinsamer Clock, ein `AudioDeviceCreateIOProcIDWithBlock()`, alle Kanäle in einem Callback.
3. Im Callback: System-Kanäle zu Mono summieren → ch0, Mikrofon → ch1, streamend in `AVAudioFile` schreiben (nicht im RAM puffern — eine Stunde muss einen Crash überleben).
4. Referenz für Tap + Aggregate: `insidegui/AudioCap` (BSD-2).

**Fallback,** falls das Aggregate-Device Ärger macht: zwei Writer `system.wav` / `mic.wav`, beide mit `AudioTimeStamp.mHostTime` des ersten Samples in `meta.json`. Läuft, kann über eine Stunde aber driften — deshalb zweite Wahl.

> **Teams-Sprecher als eigene Spuren gibt es nicht.** Ein Process Tap sieht nur Teams' fertigen Mix; Einzelstreams stellt Teams ausschließlich über die Cloud-Compliance-Recording-API bereit. Trennung passiert daher in §5 (Diarisierung) auf ch0. Kanal ch1 ist dafür geschenkt: das ist immer und fehlerfrei **du**.

### 3b. Modus `onsite` — ein Kanal, mehrere Sprecher im Raum

Kein Tap, kein Aggregate-Device. `AVAudioEngine.inputNode` → `AVAudioFile`. Deutlich weniger Code als 3a.

```
audio.wav   48 kHz · 16-bit PCM · 1 ch
            ch0 = Raum-Mikrofon
```

Drei Dinge sind hier entscheidend, und alle drei betreffen nicht den Code, sondern das Signal:

1. **Mikrofonmodus prüfen.** `AVCaptureDevice.activeMicrophoneMode` lesen. Steht er auf `.voiceIsolation`, dämpft macOS aktiv alle Stimmen außer der nächsten — genau das Gegenteil dessen, was eine Raumaufnahme braucht. Beim Start von `onsite`:
   - `.wideSpectrum` → still weitermachen (minimale Verarbeitung, nimmt den ganzen Raum).
   - `.standard` → weitermachen, Hinweis im Menü.
   - `.voiceIsolation` → **Aufnahme blockieren**, Dialog: „Sprachisolierung dämpft die anderen Teilnehmer." + Knopf, der `AVCaptureDevice.showSystemUserInterface(.microphoneModes)` öffnet. Nach Wechsel neu prüfen.
2. **Eingabegerät wählbar.** Default ist das eingebaute Array; in Settings jedes Gerät aus `AVCaptureDevice.devices(for: .audio)` auswählbar, damit ein USB-Grenzflächenmikrofon auf dem Tisch möglich ist. Das ist der wirksamste Qualitätshebel überhaupt, und er kostet nichts an Code.
3. **Keine Verarbeitung anfassen.** Kein AGC, kein Noise Gate, kein Normalisieren. Das Rohsignal geht ins Modell; alles Nachschärfen macht die Diarisierung schlechter, nicht besser.

**Sprecherzahl** — die Diarisierung erkennt sie selbst. Falls `OfflineDiarizerConfig` eine Ober-/Untergrenze anbietet, aus einem optionalen Picker beim Start füttern (2–8, Default „automatisch"); wenn nicht, ohne Hinweis laufen lassen.

---

## 4. Screenshots (beide Modi)

**Alle Displays, ereignisgesteuert statt stumpf getaktet.** ScreenCaptureKit liefert bei unveränderten Displays den Status `.idle` — das ersetzt jedes eigene Bildvergleichen.

1. `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)` → `displays`.
2. Pro Display ein `SCStream` mit `SCContentFilter(display:excludingWindows: [])`.
3. `SCStreamConfiguration`: `minimumFrameInterval = CMTime(value: 1, timescale: 1)` · `queueDepth = 3` · `showsCursor = true` · `capturesAudio = false` · `width/height` so skaliert, dass die längere Kante **≤ 1920 px** (Config).
4. In `stream(_:didOutputSampleBuffer:of:)`: `SCStreamFrameInfo.status` lesen.
   - `.complete` → Kandidat. Alles andere (`.idle`, `.blank`, …) → verwerfen.
   - `SCStreamFrameInfo.dirtyRects` summieren → `changedPct` der Displayfläche.
5. Speichern nur wenn **beides** gilt:

| | Normales Display | Display mit der Maus |
|---|---|---|
| Mindestabstand zum letzten Bild | 5 s | 2 s |
| Geänderte Fläche | ≥ 2 % | ≥ 0,5 % |

*Aktives Display ermitteln:* `NSEvent.mouseLocation` → passender `NSScreen` → `deviceDescription["NSScreenNumber"]` → `CGDirectDisplayID`. Bei jedem gespeicherten Frame neu prüfen.

6. **Anker-Frames:** je Display einmal beim Start und dann alle **120 s** unabhängig von jeder Änderung. Sonst hat ein statischer Monitor über eine Stunde kein einziges Bild.
7. Schreiben via `CGImageDestination`, **JPEG q 0.8** (Config).

**Dateinamen** `HHmmss_d<index>[_active].jpg` — z. B. `143012_d1_active.jpg`

**Index** `screens.jsonl`, eine Zeile pro Bild, direkt beim Speichern angehängt:
```json
{"t":18.42,"file":"screens/143012_d1_active.jpg","display":1,"active":true,"changed":0.31}
```
`t` = Sekunden seit Aufnahmestart. Das ist die Brücke, über die der Claude-Skill Bild und Transkriptzeile zusammenbringt.

---

## 5. Transkription (nach dem Stoppen)

Serielle Queue, ein Meeting zur Zeit, im Hintergrund. Menüleiste zeigt Fortschritt.

```swift
import FluidAudio

// 1) Kanäle holen, je 16 kHz Mono Float32 — immer über AudioConverter,
//    niemals WAV-Bytes selbst parsen.
let room = try AudioConverter().resample(audioURL, channel: 0)   // online: System · onsite: Raum
let mic  = mode == .online ? try AudioConverter().resample(audioURL, channel: 1) : nil

// 2) ASR. v3 = multilingual, Deutsch dabei.
let models = try await AsrModels.downloadAndLoad(version: .v3)
let asr = AsrManager(config: .default)          // seamGapRepair bleibt an
try await asr.configure(models: models)
let roomResult = try await asr.transcribe(room, source: .system)
let micResult  = try await mic.map { try await asr.transcribe($0, source: .microphone) }

// 3) Diarisierung auf ch0 (pyannote community-1 + VBx), in beiden Modi
let diar = OfflineDiarizerManager(config: OfflineDiarizerConfig())
try await diar.prepareModels()
let speakers = try await diar.process(audio: room)
```

**Zusammenführen**

Jedes Token bekommt den Sprecher des Diarizer-Segments, das seine **Mitte** überdeckt; kein Treffer → `UNKNOWN`. Danach alles nach Startzeit sortieren, aufeinanderfolgende Tokens gleichen Sprechers zu einer Äußerung bündeln, **Lücke > 0,8 s** beginnt eine neue.

Der einzige Modusunterschied:

- **`online`** — die Tokens aus `micResult` überschreiben die Diarisierung und werden `ME`. Physik schlägt Modell.
- **`onsite`** — kein `micResult`. Alle Sprecher heißen `S1 … Sn`. Wer davon du bist, entscheidet später der Claude-Skill aus dem Inhalt; die App rät nicht.

**Schreiben**

`transcript.json` — die Wahrheit, für Maschinen:
```json
{
  "mode": "onsite",
  "utterances": [
    {"speaker":"S1","start":12.30,"end":15.02,"text":"Also der Centerplan …",
     "tokens":[{"t":12.30,"w":"Also"}]}
  ],
  "diarization": [{"speaker":"S1","start":15.4,"end":22.1}],
  "models": {"asr":"parakeet-tdt-0.6b-v3","diarizer":"pyannote-community-1"},
  "confidence": {"asr_room":0.89,"asr_mic":null}
}
```

`transcript.md` — zum Lesen und für den Skill:
```
[00:00:12] S1: Also der Centerplan ist durch.
[00:00:15] S2: Dann können wir den Druck freigeben.
```

---

## 6. Ablage

Wurzelordner in Settings frei wählbar, Default `~/Meetings/`.

```
<root>/2026-09-09_1430_Teams/          # online:  _<App>
<root>/2026-09-09_1430_Vorort/         # onsite:  _Vorort
  audio.wav
  screens/
    143012_d0.jpg
    143012_d1_active.jpg
  screens.jsonl
  transcript.json
  transcript.md
  meta.json
```

`meta.json`
```json
{
  "mode":"onsite",
  "started":"2026-09-09T14:30:12+02:00",
  "ended":"2026-09-09T15:12:44+02:00",
  "duration":2552.0,
  "trigger":{"kind":"manual"},
  "channels":["room"],
  "input":{"device":"MacBook Pro Mikrofon","microphoneMode":"wideSpectrum"},
  "displays":[{"index":0,"id":1,"px":[3840,2160]},{"index":1,"id":2,"px":[2560,1440]}],
  "screenshots":214,
  "app":"1.1",
  "state":"done"
}
```

Bei `mode: "online"` stattdessen `"channels":["system","mic"]` und `"trigger":{"kind":"auto","bundleId":"com.microsoft.teams2","name":"Teams"}`.

`state`: `recording` → `transcribing` → `done` | `failed`. Wird laufend fortgeschrieben, damit ein Absturz erkennbar ist und der Ordner beim nächsten Start weiterverarbeitet werden kann.

---

## 7. Menüleiste

**Icon** Ruhe: Mikrofon-Outline. Aufnahme: gefüllt + roter Punkt + `mm:ss` (bei `onsite` zusätzlich ein kleines Raum-Glyph). Verarbeitung: Fortschrittsring.

**Menü**
```
Online-Meeting aufnehmen        ⌥⌘R
Vor-Ort-Meeting aufnehmen       ⌥⌘V
Aufnahme stoppen                (nur während einer Aufnahme)
—
Letztes Meeting im Finder zeigen
Ordner öffnen
—
Einstellungen …
Beenden
```

**Einstellungen** (ein Fenster, elf Regler, mehr nicht)
Ablageordner · Watchlist (Bundle-IDs) · Eingabegerät für `onsite` · Screenshot-Mindestabstand · Änderungsschwelle · max. Bildkante · JPEG-Qualität · ASR-Version (v3 / v2) · Start bei Login (`SMAppService.mainApp.register()`) · Auto-Stop-Verzögerung · Sprecherzahl-Picker bei `onsite` anzeigen (an/aus)

---

## 8. Berechtigungen

`Info.plist`: `NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`
Screen Recording: wird beim ersten `SCShareableContent`-Aufruf von macOS abgefragt.
Beim ersten Start ein Onboarding-Fenster mit drei Häkchen und einem Knopf pro Berechtigung, der die passende Systemeinstellung öffnet. Fehlt eine, ist der Aufnahme-Knopf deaktiviert und sagt, welche.

---

## 9. Bekannte Grenzen — im Kopf behalten, nicht wegkaschieren

- **Long-Form-Nähte.** Parakeet dekodiert in 15-s-Fenstern mit 2 s Überlappung. An den Nähten gehen bekanntlich Wörter verloren oder verdoppeln sich. `seamGapRepair` bleibt an (Default). Beim Abnahmetest gezielt auf Naht-Artefakte schauen, nicht nur auf die durchschnittliche Wortfehlerrate.
- **Diarisierung liegt daneben.** DER ≈ 18–20 % auf AMI, und AMI *sind* Raumaufnahmen — `onsite` ist also der schwierigere Fall, nicht der leichtere. Sprecherlabels sind Vorschläge. Genau darum landen die rohen Diarizer-Segmente mit in `transcript.json`: der Claude-Skill soll darüber urteilen können, statt einer geglätteten Lüge zu vertrauen.
- **`ME` gibt es nur bei `online`**, weil ch1 dort physikalisch getrennt ist. Bei `onsite` fehlt dieser Anker vollständig — das ist der Preis der einen Mikrofonspur, nicht ein Bug.
- **Raumaufnahme lebt von der Distanz.** Über zwei Meter, bei Tischgeräuschen oder wenn zwei gleichzeitig reden, bricht die Trennung ein. Der Hebel ist das Mikrofon auf dem Tisch (§3b.2), nicht das Modell.
- **Agenturdeutsch.** „Rollout", „Centerplan", „Ratecard" trifft das Modell nicht immer. Nicht am Modell drehen — FluidAudio hat `ASR/CustomVocabulary`, alles andere ist Sache der Nachbearbeitung im Skill.

---

## 10. Meilensteine

| | | Fertig, wenn |
|---|---|---|
| M0 | Menüleisten-Gerüst + Berechtigungs-Onboarding | Alle drei Häkchen grün, Ordner wird angelegt |
| M1 | `onsite`-Audio (`AVAudioEngine` → WAV) + Mikrofonmodus-Prüfung | 10-min-`audio.wav` 1 ch; bei `.voiceIsolation` blockiert die App mit Dialog |
| M2 | `online`-Audio: Tap + Aggregate + 2-ch-WAV | ch0 = Teams, ch1 = Mic, kein Drift |
| M3 | Meeting-Erkennung + Popup + Auto-Stop | Teams starten → Popup nach ≤ 5 s; Teams beenden → Stop nach 30 s |
| M4 | Screenshots über alle Displays | Statisches Display: nur Anker-Frames. Aktives: Bilder bei echten Änderungen. `screens.jsonl` vollständig |
| M5 | ASR + Diarisierung + Merge, beide Modi | `transcript.md` mit Zeitstempeln und Sprechern; `ME` nur bei `online` |
| M6 | Robustheit | Absturz während Aufnahme → beim Neustart wird der Ordner erkannt und fertig verarbeitet |

`onsite` steht bewusst vor `online`: weniger Code, keine Berechtigungsakrobatik, und die gesamte Transkriptionskette lässt sich damit schon durchtesten.

---

## 11. Abnahme

**A · Online** — 45-Minuten-Teams-Meeting, drei Gegenüber-Sprecher, drei Monitore aktiv.
1. Popup kam innerhalb 5 s, Aufnahme per Klick gestartet.
2. `audio.wav` ist 45 min lang; ch0 und ch1 laufen am Ende noch synchron (Klatschtest am Anfang und am Ende).
3. Alle `ME`-Zeilen sind tatsächlich du. Bei den übrigen Sprechern stimmt die Zuordnung stichprobenweise in ≥ 4 von 5 Fällen.

**B · Vor Ort** — 30 Minuten am Besprechungstisch, vier Personen, MacBook in der Mitte.
4. Aufnahme manuell gestartet und gestoppt, kein Auto-Stop dazwischen.
5. Die Diarisierung findet **vier** Sprecher, nicht zwei und nicht acht.
6. Sprecherwechsel sitzen stichprobenweise in ≥ 3 von 5 Fällen auf der richtigen Zeile.
7. Test einmal mit `.voiceIsolation` wiederholen: die App verweigert die Aufnahme, statt eine unbrauchbare Datei zu produzieren.

**C · Beide**
8. `screens.jsonl` hat für jedes Bild einen Eintrag; jedes `file` existiert; keine zwei Bilder desselben Displays näher als das konfigurierte Intervall.
9. `transcript.md` deckt die gesamte Laufzeit ab, keine Lücke > 30 s ohne Grund.
10. Netzwerk aus (nach dem Modell-Download): alles läuft unverändert durch.
11. Nichts geschrieben außer unter `<root>/`.
