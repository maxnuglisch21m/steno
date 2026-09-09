# Contributing to Steno

## Setup

Xcode 26.6 (Swift 6) and Homebrew are assumed.

```sh
brew install xcodegen xcbeautify
git clone https://github.com/maxnuglisch21m/steno.git
cd steno
make gen      # generates Steno.xcodeproj from project.yml — do not commit it
make test
```

`Steno.xcodeproj` is generated and gitignored. Whenever you add, move, or remove
a file, or change a build setting, edit `project.yml` and re-run `make gen`
rather than touching project settings in Xcode — changes made in the Xcode UI
are lost on the next generate.

### Make targets

| Target | What it does |
|---|---|
| `make gen` | regenerate `Steno.xcodeproj` |
| `make test` | `swift test` for `StenoCore`, then `xcodebuild test` for the app |
| `make build` | Release build into `build/` |
| `make run` | Debug build, then `open` the app |
| `make clean` | remove `build/` and `Steno.xcodeproj` |

## Architecture

Anything that can be expressed with Foundation alone belongs in
`Packages/StenoCore` — a local SwiftPM package with no AppKit, AVFoundation,
ScreenCaptureKit, or Core Audio imports. That is where the interesting decisions
live (transcript merging, the screenshot gate, folder naming, the metadata state
machine, WAV header repair, rule matching), and it is the only part with
thorough unit tests, because it is the only part that can be tested without a
microphone and three monitors.

`Sources/Steno` is the shell around it: permissions, device handling, real-time
audio, streams, windows. Keep decisions out of it; keep I/O out of `StenoCore`.

## Code style

- **Swift 6 with `SWIFT_STRICT_CONCURRENCY: complete`.** A pull request must not
  add compiler warnings. Do not reach for `@unchecked Sendable` — if it is
  genuinely unavoidable (a real-time audio buffer, for instance), it needs a
  comment above it explaining what actually guarantees the safety.
- Real-time audio callbacks allocate nothing, take no locks, and do no I/O.
  Hand data to a writer thread through the ring buffer.
- **Code, comments, commit messages, and documentation are English.**
- **UI strings are German**, with English translations. Every user-visible
  string goes into `Sources/Steno/Resources/Localizable.xcstrings` — German is
  the source language, so add the German text as the key's source value and fill
  in the `en` translation in the same change. Never hardcode a display string.
- Tests use [Swift Testing](https://developer.apple.com/documentation/testing)
  (`import Testing`, `@Test`, `#expect`), not XCTest. Prefer table-driven tests
  with `arguments:` where the cases are naturally a table.

## Commits and pull requests

[Conventional Commits](https://www.conventionalcommits.org/):

```
feat(core): transcript merger
fix(audio): repair WAV header after a crash during recording
chore(ci): cache resolved SwiftPM packages
docs: describe the onsite microphone-mode check
test(core): screenshot gate anchor frames
```

Common scopes: `core`, `app`, `audio`, `detection`, `screenshots`,
`transcription`, `storage`, `settings`, `update`, `ci`.

Keep commits logically separate — hygiene, project definition, and a feature are
three commits, not one. Update `CHANGELOG.md` under `## [Unreleased]` for
anything a user would notice.

## Releasing

The release pipeline lands in M7; this is the shape it takes.

1. Update `CHANGELOG.md`: rename `## [Unreleased]` to `## [x.y.z] - YYYY-MM-DD`
   and open a fresh `## [Unreleased]` above it. A release fails without its
   section — check with `scripts/changelog-extract.sh x.y.z`.
2. Bump `MARKETING_VERSION` in `project.yml`. The build number is derived from
   `git rev-list --count HEAD` in CI, so it needs no manual bump.
3. Tag and push: `git tag v x.y.z` (no space) and `git push --tags`. The
   `release` workflow builds, signs, packages, generates the appcast, and
   creates the GitHub release with the zip, `appcast.xml`, and the changelog
   section as the notes.

### Sparkle keys

Updates are EdDSA-signed, and the signing key is the one piece of this project
that must never reach the repository.

- The **private key** lives in the login keychain of whoever set it up
  (generated once with Sparkle's `generate_keys`) and, base64-encoded, in the
  repository secret `SPARKLE_PRIVATE_KEY`. It is never committed, never printed
  in a workflow log, and never passed on a command line where it would show up
  in `ps`. The release workflow writes it to a temporary file for
  `generate_appcast --ed-key-file` and deletes it afterwards.
- The **public key** is committed, as `SUPublicEDKey` in
  `Sources/Steno/Resources/Info.plist`. It currently holds the placeholder
  `REPLACE_WITH_SPARKLE_PUBLIC_KEY`; the first release replaces it with the real
  key. Once shipped, the key cannot be rotated without breaking updates for
  everyone still on an older build — treat it as permanent.
- Back up the private key. Losing it means every existing installation stops
  being able to update, and the only fix is asking users to reinstall by hand.

Code signing is ad-hoc (`CODE_SIGN_IDENTITY: "-"`) until a Developer ID exists.
The release workflow signs with a Developer ID and notarizes automatically once
the secrets `DEVELOPER_ID_P12_BASE64`, `APPLE_ID`, `APPLE_TEAM_ID`, and
`APPLE_APP_PASSWORD` are present, and falls back to ad-hoc when they are not.

## Scope

Steno records and transcribes. Summaries, context enrichment, Obsidian export,
OCR, cloud processing, and pause/resume are out of scope by decision, not by
omission — see `docs/SPEC.md`. Features that read the recorded files belong in a
separate tool.
