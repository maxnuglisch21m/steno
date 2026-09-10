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
| `make release VERSION=x.y.z` | build and package `dist/Steno-x.y.z.zip` locally; publishes nothing |
| `make bump VERSION=x.y.z` | cut a version: changelog, `project.yml`, commit, annotated tag; never pushes |
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

1. **Prepare the version.**

   ```sh
   make bump VERSION=0.2.0
   ```

   `scripts/bump-version.sh` renames `## [Unreleased]` to `## [0.2.0] - <today>`,
   opens a fresh empty `## [Unreleased]` above it, rewrites the comparison links
   at the foot of the changelog, sets `MARKETING_VERSION` in `project.yml`,
   commits both files as `chore(release): 0.2.0`, and creates the annotated tag
   `v0.2.0`. It refuses a version that already has a section and one whose
   Unreleased section is empty. It does not push.

   The build number is not bumped by hand: it is `git rev-list --count HEAD`,
   computed in the workflow.

2. **Check it builds, if you want to** — `make release VERSION=0.2.0` runs the
   same Release build and `ditto` packaging locally and publishes nothing.

3. **Push.** The tag is what publishes:

   ```sh
   git push origin main && git push origin v0.2.0
   ```

4. **Watch the run.** `gh run watch --exit-status`. It builds, signs, packages,
   generates the appcast, and creates the GitHub release. If it fails, fix the
   cause and re-run the workflow against the same tag from the Actions tab
   (`workflow_dispatch`, input `tag`) — a re-run replaces the release's assets
   rather than failing on the second attempt, so the tag does not have to be
   deleted and re-pushed.

A release candidate is tagged the same way (`v0.2.0-rc.1`) and needs no
changelog section of its own: it is published as a GitHub prerelease, its notes
come from `## [Unreleased]`, and because `releases/latest` resolves to the
newest *stable* release, no installed copy of Steno ever sees it in the feed.

### Sparkle keys

Updates are EdDSA-signed, and the signing key is the one piece of this project
that must never reach the repository.

- The **private key** lives in the login keychain of whoever set it up
  (generated once with Sparkle's `generate_keys`) and, base64-encoded, in the
  repository secret `SPARKLE_PRIVATE_KEY`. It is never committed, never printed
  in a workflow log, and never passed on a command line where it would show up
  in `ps`. The release workflow writes it to a file under `$RUNNER_TEMP` for
  `generate_appcast --ed-key-file` and deletes it afterwards.
- The **public key** is committed, as `SUPublicEDKey` in
  `Sources/Steno/Resources/Info.plist`. Once shipped it cannot be rotated
  without breaking updates for everyone still on an older build — treat it as
  permanent.
- **Back up the private key.** Export it with
  `generate_keys -x ~/steno-sparkle.key` from Sparkle's tools (resolved under
  `build/SourcePackages/artifacts/sparkle/Sparkle/bin/` after a build), and keep
  the file somewhere that is not this repository. Losing it means every existing
  installation stops being able to update and the only fix is asking users to
  download and install the new version by hand.
- A build whose `SUPublicEDKey` is still the placeholder starts no updater at
  all: `UpdaterController` checks that the key is 44 base64 characters decoding
  to 32 bytes, logs one line if it is not, and leaves the update actions
  disabled. Sparkle's own answer to a misconfigured bundle is an alert telling
  the user to contact the developer, which is not what a pre-release build
  should do.

### Code signing

Code signing is ad-hoc (`CODE_SIGN_IDENTITY: "-"`) until a Developer ID exists.
The release workflow signs with a Developer ID and notarizes automatically once
the secrets `DEVELOPER_ID_P12_BASE64`, `DEVELOPER_ID_P12_PASSWORD`,
`APPLE_TEAM_ID`, `APPLE_ID`, and `APPLE_APP_PASSWORD` are present, and falls
back to ad-hoc when they are not. No code changes either way.

One thing does change, and the workflow handles it: an ad-hoc build is built
with `Config/Steno-adhoc.entitlements`, which adds
`com.apple.security.cs.disable-library-validation`. Under the hardened runtime a
process may load only code signed by its own team or by Apple, and two ad-hoc
signatures share no team — without the exception the app cannot load its own
embedded `Sparkle.framework` and dies before `main`. With a Developer ID over
both, the exception is unnecessary and the workflow uses the strict
`Config/Steno.entitlements` instead. Keep the two files otherwise identical.

## Scope

Steno records and transcribes. Summaries, context enrichment, Obsidian export,
OCR, cloud processing, and pause/resume are out of scope by decision, not by
omission — see `docs/SPEC.md`. Features that read the recorded files belong in a
separate tool.
