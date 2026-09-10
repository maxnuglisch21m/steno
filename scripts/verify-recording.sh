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
# A screenshot's name carries the offset from `meta.started` as `HHMMSS`, the same clock
# `transcript.md` prints as `[HH:MM:SS]`, and the entry's `at` carries the wall clock.
# Both are checked against the entry's `t`. A folder recorded before that change has no
# `at` and wall-clock names; it is reported as such and its names are left alone.
#
# It also checks what §6 says `meta.json` must agree with — `screenshots` equals the
# number of index lines, `displays` accounts for every frame, `stopReason` is one of the
# documented values — and what §5 says about the transcript: `transcript.json` parses,
# agrees with `meta.json` about the mode, names the models it was made with, has a
# `transcript.md` beside it, and carries a `ME` speaker only in `online` mode.
# `meta.audio` has to name a file that is there.
#
# A `.steno-lock` is allowed only while the process named in it is still running — a
# live recording. One left behind by a process that is gone is a folder the recovery
# pass has not reached yet, and is reported as a problem.
#
# Usage:
#   scripts/verify-recording.sh ~/Meetings/2026-09-09_1430_Vorort
#   scripts/verify-recording.sh --interval 5 --active-interval 2 <folder>
#   scripts/verify-recording.sh --fixture docs/format-fixtures/2026-09-09_1430_...
#
# Exits 0 when everything holds, 1 on a violation, 2 on a usage error.

set -euo pipefail

INTERVAL=5
ACTIVE_INTERVAL=2
ANCHOR_INTERVAL=120
FIXTURE=0
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
  --fixture               the folder is a documentation fixture with the binary
                          parts left out: the JPEGs and the audio file are
                          allowed to be missing, everything else still holds
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
	--fixture)
		FIXTURE=1
		shift
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
exec python3 - "$FOLDER" "$INTERVAL" "$ACTIVE_INTERVAL" "$ANCHOR_INTERVAL" "$FIXTURE" <<'PYTHON'
import datetime
import json
import os
import sys

folder, interval, active_interval, anchor_interval = (
    sys.argv[1],
    float(sys.argv[2]),
    float(sys.argv[3]),
    float(sys.argv[4]),
)
# A documentation fixture has no JPEGs and no audio; everything else about it is real.
fixture = sys.argv[5] == "1"

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

def timestamp(text):
    """An ISO-8601 instant with an offset, or None."""
    if not isinstance(text, str):
        return None
    try:
        return datetime.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None


def elapsed_clock(seconds):
    """`HHMMSS` for an offset from the start, floored, hours counting upwards.

    The same clock `transcript.md` prints as `[HH:MM:SS]`; a screenshot's name is
    exactly this string, which is what lets the two be lined up by eye.
    """
    total = int(max(seconds, 0.0))
    return "%02d%02d%02d" % (total // 3600, (total % 3600) // 60, total % 60)


started = timestamp(meta.get("started")) if isinstance(meta, dict) else None

# Before the names counted from `meta.started` they were a wall clock, and the entries
# carried no `at`. Such a folder is old, not broken: its names are left unchecked.
old_naming = bool(entries) and all("at" not in entry for entry in entries)
if old_naming:
    note(
        "this folder was recorded before the file names counted from meta.started — "
        "the names are a wall clock and there is no \"at\""
    )

# Every file named exists, and its name says what the entry says.
for entry in entries:
    name = entry.get("file")
    if not isinstance(name, str):
        continue
    if not name.startswith("screens/"):
        fail("line %d: %r is not under screens/" % (entry["_line"], name))
    path = os.path.join(folder, name)
    if not os.path.isfile(path):
        if not fixture:
            fail("line %d: %s is named in the index but not on disk" % (entry["_line"], name))
            continue
    elif os.path.getsize(path) == 0:
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

    # The name's clock is `t`, floored to the second — the one thing that makes it
    # readable next to a transcript line.
    if not old_naming and isinstance(entry.get("t"), (int, float)):
        expected = elapsed_clock(entry["t"])
        if base.split("_", 1)[0] != expected:
            fail(
                "line %d: %s does not carry t=%.2f as a clock (expected %s)"
                % (entry["_line"], base, entry["t"], expected)
            )

    # `at` is the wall clock of the same instant `t` measures from `meta.started`.
    if "at" in entry:
        at = timestamp(entry.get("at"))
        if at is None:
            fail("line %d: \"at\" is not an ISO-8601 timestamp" % entry["_line"])
        elif at.utcoffset() is None:
            fail("line %d: \"at\" carries no time-zone offset" % entry["_line"])
        elif started is not None and isinstance(entry.get("t"), (int, float)):
            drift = (at - started).total_seconds() - entry["t"]
            # Both timestamps are written to whole seconds, and `meta.started` is
            # rarely on one: each is floored independently, so `at` can sit up to a
            # second either side of `started` plus `t`. More than that is a real
            # disagreement about when the frame was taken.
            if not (-1.01 <= drift <= 1.01):
                fail(
                    "line %d: \"at\" is %.2f s from meta.started plus t=%.2f"
                    % (entry["_line"], drift, entry["t"])
                )
    elif not old_naming:
        fail("screens.jsonl line %d has no 'at'" % entry["_line"])

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

    # §6 / docs/FORMAT.md: `stopReason` is a closed set. `crash` is the one the
    # recovery pass writes for a recording nobody was there to end.
    STOP_REASONS = {"manual", "auto", "sleep", "deviceLost", "crash"}
    stop_reason = meta.get("stopReason")
    if stop_reason is not None:
        if stop_reason not in STOP_REASONS:
            fail("meta.stopReason is %r, which is not a documented value" % stop_reason)
        elif stop_reason == "crash":
            # `ended` is inferred from file modification times there, so the audio may
            # be a little short of the meeting. Worth saying out loud, not a violation.
            note("this recording was interrupted and finished by the recovery pass")
    elif meta.get("state") in ("done", "failed") and meta.get("ended") is not None:
        note("the recording ended without a stopReason — a failed write, presumably")

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

# `.steno-lock` names the process that is recording into the folder. It is Steno's
# bookkeeping rather than part of the recording, and it is removed when capture ends —
# so one that is still here belongs to a live recording, and one whose process is gone
# is debris the next launch's recovery pass will clear.
LOCK_FILE = ".steno-lock"


def lock_holder(path):
    """The pid in a lock file if that process is still running, else None."""
    try:
        with open(path, encoding="utf-8") as handle:
            pid = json.load(handle).get("pid")
    except (ValueError, OSError, AttributeError):
        return None
    if not isinstance(pid, int):
        return None
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return None
    except PermissionError:
        # Alive, and not ours to signal.
        return pid
    except OSError:
        return None
    return pid


for name in sorted(os.listdir(folder)):
    if name in IGNORED:
        note("%s is Finder's, not Steno's" % name)
        continue
    if name == LOCK_FILE:
        holder = lock_holder(os.path.join(folder, name))
        if holder is None:
            fail(
                "%s is left over from a process that is gone — the recording was "
                "interrupted and has not been recovered yet" % LOCK_FILE
            )
        else:
            note("%s says pid %d is recording into this folder right now" % (LOCK_FILE, holder))
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

if fixture:
    note("--fixture: the images and the audio file were not expected to be here")

print("folder      %s" % folder)
if meta is not None:
    print(
        "meeting     %s · %s · %s s · stopped by %s"
        % (
            meta.get("mode", "?"),
            meta.get("state", "?"),
            ("%.0f" % meta["duration"]) if isinstance(meta.get("duration"), (int, float)) else "?",
            meta.get("stopReason") or "—",
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
            if not fixture:
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
