# Format fixtures

One complete meeting folder, as [`../FORMAT.md`](../FORMAT.md) describes it, with the
binary parts left out.

```
2026-09-09_1430_Teams_Weekly-Sync/
  meta.json          an online meeting that ran to done
  screens.jsonl      three entries, two displays
  transcript.json    three utterances, one of them ME
  transcript.md      the same transcript, rendered
```

The files were written by the encoders in `Packages/StenoCore`, so they are what Steno
actually produces — not hand-typed examples that drift away from the code.
`FormatFixtureTests` decodes each of them, checks the values a downstream reader would
rely on, and **re-encodes them and compares the bytes**. A key renamed, a number that
stops being rounded, a date that drifts to the `Z`-suffixed form: any of those changes
the bytes and fails there, so a format change has to be deliberate.

**There is no audio and there are no images**, because a repository is no place for
either. That has two consequences:

- The `file` paths in `screens.jsonl` point at images that are not here, and
  `meta.audio` names an `audio.m4a` that is not here.
- `scripts/verify-recording.sh` reports those as missing unless it is given
  `--fixture`, which is exactly this case: the binary parts are allowed to be absent
  and everything else is still checked. `scripts/verify-recording.sh --fixture
  docs/format-fixtures/2026-09-09_1430_Teams_Weekly-Sync` passes.

To use it as a fixture in another language, read the four files and satisfy the same
shapes.

After a deliberate format change the byte comparison in `FormatFixtureTests` fails, and
the fix is to write the files out again rather than to edit them by hand: build the
same values with `MeetingMeta`, `ScreensIndexEntry`, `Transcript`, and
`TranscriptMarkdownFormatter`, and write their `jsonData()` / `jsonLine` /
`markdown(for:)` here. Editing the JSON by hand is how a fixture stops describing the
code.
