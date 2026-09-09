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
  issue and pull-request templates.
- `StenoCore`, the framework-free logic package: semantic versions, recording
  folder naming, meeting metadata and its state machine, the screenshot
  decision gate, the screenshot index entry, WAV header parsing and repair,
  transcript models with the merge rules from the specification, the transcript
  Markdown formatter, and recording rule matching.
- A minimal menu-bar shell (`MenuBarExtra`) with a Quit item.
