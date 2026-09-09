#!/usr/bin/env bash
#
# verify-recording.sh — check one meeting folder against the specification.
#
# Automates the parts of specification §11 that a machine can answer:
#
#   §11.8   every image in `screens.jsonl` has an entry, every `file` exists, and no
#           two images of the same display are closer together than the configured
#           interval (the shorter one for a frame marked `_active`).
#   §11.11  nothing was written into the folder except the documented set.
#
# It also checks what §6 says `meta.json` must agree with — `screenshots` equals the
# number of index lines, `displays` accounts for every frame — and what §5 says about
# the transcript: `transcript.json` parses, agrees with `meta.json` about the mode,
# names the models it was made with, has a `transcript.md` beside it, and carries a
# `ME` speaker only in `online` mode. `meta.audio` has to name a file that is there.
#
# Usage:
#   scripts/verify-recording.sh ~/Meetings/2026-09-09_1430_Vorort
#   scripts/verify-recording.sh --interval 5 --active-interval 2 <folder>
#
# Exits 0 when everything holds, 1 on a violation, 2 on a usage error.

set -euo pipefail

INTERVAL=5
ACTIVE_INTERVAL=2
ANCHOR_INTERVAL=120
FOLDER=""

usage() {
	cat <<'EOF'
usage: verify-recording.sh [options] <meeting folder>

  --interval <s>          minimum seconds between two images of a display
                          without the pointer (default 5, specification §4.5)
  --active-interval <s>   the same for the display holding the pointer
                          (default 2)
  --anchor-interval <s>   how often an anchor frame is expected per display
                          (default 120, specification §4.6)
  -h, --help              this text
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--interval)
		INTERVAL="${2:-}"
		shift 2
		;;
	--active-interval)
		ACTIVE_INTERVAL="${2:-}"
		shift 2
		;;
	--anchor-interval)
		ANCHOR_INTERVAL="${2:-}"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	-*)
		echo "unknown option: $1" >&2
		usage >&2
		exit 2
		;;
	*)
		if [[ -n "$FOLDER" ]]; then
			echo "only one folder can be checked at a time" >&2
			exit 2
		fi
		FOLDER="$1"
		shift
		;;
	esac
done

if [[ -z "$FOLDER" ]]; then
	usage >&2
	exit 2
fi

if [[ ! -d "$FOLDER" ]]; then
	echo "not a folder: $FOLDER" >&2
	exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
	echo "python3 is required" >&2
	exit 2
fi

# Everything below is stdlib Python: no jq, no pip, nothing to install. The shell is
# only here for the arguments and the exit code.
exec python3 - "$FOLDER" "$INTERVAL" "$ACTIVE_INTERVAL" "$ANCHOR_INTERVAL" <<'PYTHON'
import json
import os
import sys

folder, interval, active_interval, anchor_interval = (
    sys.argv[1],
    float(sys.argv[2]),
    float(sys.argv[3]),
    float(sys.argv[4]),
)

# `t` and `changed` carry two decimals in the index (docs/FORMAT.md), so a gap that is
# exactly the interval can read as 0.01 short. Anything larger than that is a real
# violation.
TOLERANCE = 0.02

problems = []
notes = []


def fail(message):
    problems.append(message)


def note(message):
    notes.append(message)


# ---------------------------------------------------------------- meta.json

meta_path = os.path.join(folder, "meta.json")
meta = None
if not os.path.isfile(meta_path):
    fail("meta.json is missing — this is not a meeting folder")
else:
    try:
        with open(meta_path, encoding="utf-8") as handle:
            meta = json.load(handle)
    except (ValueError, OSError) as error:
        fail("meta.json does not parse: %s" % error)

# ---------------------------------------------------------------- screens.jsonl

index_path = os.path.join(folder, "screens.jsonl")
entries = []
if not os.path.isfile(index_path):
    note("screens.jsonl is absent — no screenshots were written")
else:
    with open(index_path, encoding="utf-8") as handle:
        for number, line in enumerate(handle, start=1):
            text = line.strip()
            if not text:
                continue
            try:
                entry = json.loads(text)
            except ValueError as error:
                fail("screens.jsonl line %d does not parse: %s" % (number, error))
                continue
            for key, kind in (
                ("t", (int, float)),
                ("file", str),
                ("display", int),
                ("active", bool),
                ("changed", (int, float)),
            ):
                if key not in entry:
                    fail("screens.jsonl line %d has no %r" % (number, key))
                elif not isinstance(entry[key], kind):
                    fail("screens.jsonl line %d: %r has the wrong type" % (number, key))
            changed = entry.get("changed")
            if isinstance(changed, (int, float)) and not (0.0 <= changed <= 1.0):
                fail(
                    "screens.jsonl line %d: \"changed\": %s is not a share of the display"
                    % (number, changed)
                )
            entry["_line"] = number
            entries.append(entry)

# Every file named exists, and its name says what the entry says.
for entry in entries:
    name = entry.get("file")
    if not isinstance(name, str):
        continue
    if not name.startswith("screens/"):
        fail("line %d: %r is not under screens/" % (entry["_line"], name))
    path = os.path.join(folder, name)
    if not os.path.isfile(path):
        fail("line %d: %s is named in the index but not on disk" % (entry["_line"], name))
        continue
    if os.path.getsize(path) == 0:
        fail("line %d: %s is empty" % (entry["_line"], name))
    base = os.path.basename(name)
    marked_active = "_active" in base
    if isinstance(entry.get("active"), bool) and marked_active != entry["active"]:
        fail(
            "line %d: %s and \"active\": %s disagree"
            % (entry["_line"], base, json.dumps(entry["active"]))
        )
    if isinstance(entry.get("display"), int) and "_d%d" % entry["display"] not in base:
        fail("line %d: %s does not name display %d" % (entry["_line"], base, entry["display"]))

# Nothing on disk that the index does not know about.
screens_dir = os.path.join(folder, "screens")
on_disk = set()
if os.path.isdir(screens_dir):
    for name in os.listdir(screens_dir):
        if name.startswith("."):
            continue
        on_disk.add("screens/" + name)
indexed = {entry["file"] for entry in entries if isinstance(entry.get("file"), str)}
for orphan in sorted(on_disk - indexed):
    fail("%s is on disk but has no line in screens.jsonl" % orphan)

# §11.8: no two images of one display closer than that display's interval. The
# threshold is the one that applied to the later of the two frames, because that is
# the one the gate was asked about.
by_display = {}
for entry in entries:
    if not isinstance(entry.get("display"), int) or not isinstance(entry.get("t"), (int, float)):
        continue
    by_display.setdefault(entry["display"], []).append(entry)

for display in sorted(by_display):
    frames = sorted(by_display[display], key=lambda item: item["t"])
    previous = None
    for frame in frames:
        if previous is not None:
            gap = frame["t"] - previous["t"]
            minimum = active_interval if frame.get("active") else interval
            if gap + TOLERANCE < minimum:
                fail(
                    "display %d: %.2f s between t=%.2f and t=%.2f, below the %.0f s minimum"
                    % (display, gap, previous["t"], frame["t"], minimum)
                )
        previous = frame

# ---------------------------------------------------------------- meta agreement

if meta is not None:
    screenshots = meta.get("screenshots")
    if not isinstance(screenshots, int):
        fail("meta.screenshots is missing or not a number")
    elif screenshots != len(entries):
        fail(
            "meta.screenshots is %d but screens.jsonl has %d line(s)"
            % (screenshots, len(entries))
        )

    displays = meta.get("displays")
    if not isinstance(displays, list) or not displays:
        # A recording made without the Screen Recording permission has no displays and
        # no index, and that is a permission the user is allowed not to grant — the
        # audio and the transcript are unaffected. It is only a violation when frames
        # were written and `meta.displays` does not account for them.
        if entries:
            fail("meta.displays is empty although screens.jsonl has lines")
        else:
            note("no display was captured — Screen Recording is presumably not granted")
    else:
        indices = set()
        for display in displays:
            index = display.get("index")
            px = display.get("px")
            if not isinstance(index, int):
                fail("meta.displays has an entry without an index")
                continue
            if index in indices:
                fail("meta.displays uses index %d twice" % index)
            indices.add(index)
            if not (isinstance(px, list) and len(px) == 2 and all(isinstance(v, int) and v > 0 for v in px)):
                fail("meta.displays[%d].px is not a pixel size" % index)
        for display in sorted(by_display):
            if display not in indices:
                fail("screens.jsonl uses display %d, which meta.displays does not list" % display)
        # §4.6: one anchor frame per display at the start.
        for display in sorted(indices):
            frames = by_display.get(display, [])
            if not frames:
                # §4.6 promises one image per display at the start, so a listed display
                # with nothing at all means the anchor never fired — unless the display
                # was plugged in during the last seconds of the meeting.
                fail("display %d is in meta.displays but has no screenshot at all" % display)
            elif min(frame["t"] for frame in frames) > anchor_interval:
                fail(
                    "display %d has no anchor frame near the start (first at t=%.2f)"
                    % (display, min(frame["t"] for frame in frames))
                )

# ---------------------------------------------------------------- §11.11

KNOWN_FILES = {
    "audio.wav",
    "audio.m4a",
    "audio.flac",
    "screens.jsonl",
    "transcript.json",
    "transcript.md",
    "meta.json",
}
KNOWN_DIRECTORIES = {"screens", "_work"}
# `_work/` is scratch space for transcription and is deleted when it succeeds; one
# left behind is the debris of a run that failed, and worth saying so about.

IGNORED = {".DS_Store"}

for name in sorted(os.listdir(folder)):
    if name in IGNORED:
        note("%s is Finder's, not Steno's" % name)
        continue
    path = os.path.join(folder, name)
    if os.path.isdir(path):
        if name not in KNOWN_DIRECTORIES:
            fail("unexpected directory in the meeting folder: %s/" % name)
        elif name == "_work":
            note("_work/ is left over from a transcription that did not finish")
    elif name not in KNOWN_FILES:
        fail("unexpected file in the meeting folder: %s" % name)

# ---------------------------------------------------------------- summary

total_bytes = 0
for entry in entries:
    name = entry.get("file")
    if isinstance(name, str):
        path = os.path.join(folder, name)
        if os.path.isfile(path):
            total_bytes += os.path.getsize(path)

print("folder      %s" % folder)
if meta is not None:
    print(
        "meeting     %s · %s · %s s"
        % (
            meta.get("mode", "?"),
            meta.get("state", "?"),
            ("%.0f" % meta["duration"]) if isinstance(meta.get("duration"), (int, float)) else "?",
        )
    )
    for display in meta.get("displays") or []:
        px = display.get("px") or []
        print(
            "display %-3s id=%-10s %s"
            % (
                display.get("index"),
                display.get("id"),
                "%d×%d px" % (px[0], px[1]) if len(px) == 2 else "?",
            )
        )
print("screenshots %d line(s), %d active, %.1f MB" % (
    len(entries),
    sum(1 for entry in entries if entry.get("active")),
    total_bytes / 1_048_576.0,
))
for display in sorted(by_display):
    frames = sorted(by_display[display], key=lambda item: item["t"])
    changes = [frame["changed"] for frame in frames if isinstance(frame.get("changed"), (int, float))]
    gaps = [
        frames[i]["t"] - frames[i - 1]["t"]
        for i in range(1, len(frames))
    ]
    print(
        "  display %d  %d frame(s), t %.2f…%.2f, gap min %s, changed min/med/max %s"
        % (
            display,
            len(frames),
            frames[0]["t"],
            frames[-1]["t"],
            ("%.2f s" % min(gaps)) if gaps else "n/a",
            (
                "%.2f/%.2f/%.2f"
                % (
                    min(changes),
                    sorted(changes)[len(changes) // 2],
                    max(changes),
                )
            )
            if changes
            else "n/a",
        )
    )

transcript_path = os.path.join(folder, "transcript.json")
if os.path.isfile(transcript_path):
    try:
        with open(transcript_path, encoding="utf-8") as handle:
            transcript = json.load(handle)
    except (ValueError, OSError) as error:
        fail("transcript.json does not parse: %s" % error)
    else:
        utterances = transcript.get("utterances")
        if not isinstance(utterances, list):
            fail("transcript.json has no utterances array")
            utterances = []
        speakers = []
        for utterance in utterances:
            speaker = utterance.get("speaker")
            if speaker not in speakers:
                speakers.append(speaker)
        models = transcript.get("models") or {}
        if meta is not None and transcript.get("mode") != meta.get("mode"):
            fail("transcript.json and meta.json disagree about the mode")
        if meta is not None and meta.get("mode") == "onsite" and "ME" in speakers:
            # §5: ME only exists where channel 1 physically is the user.
            fail("an onsite transcript claims a ME speaker")
        if not models.get("asr") or not models.get("diarizer"):
            fail("transcript.json does not name the models it was made with")
        print(
            "transcript  %d utterance(s), speakers %s, models %s/%s"
            % (
                len(utterances),
                ",".join(str(s) for s in speakers) or "none",
                models.get("asr", "?"),
                models.get("diarizer", "?"),
            )
        )
        if not os.path.isfile(os.path.join(folder, "transcript.md")):
            fail("transcript.json is there but transcript.md is not")
elif meta is not None and meta.get("state") == "done":
    fail("the meeting is done but has no transcript.json")

if meta is not None:
    audio = meta.get("audio")
    if audio is not None:
        if not isinstance(audio, str):
            fail("meta.audio is not a file name")
        elif not os.path.isfile(os.path.join(folder, audio)):
            fail("meta.audio names %s, which is not in the folder" % audio)
        else:
            print("audio       %s, %.1f MB" % (audio, os.path.getsize(os.path.join(folder, audio)) / 1_048_576.0))

for message in notes:
    print("note   %s" % message)
for message in problems:
    print("FAIL   %s" % message)

if problems:
    print("\n%d problem(s)" % len(problems))
    sys.exit(1)

print("\nok")
PYTHON
