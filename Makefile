# Steno — build and test entry points.
#
# Steno.xcodeproj is generated from project.yml and is not checked in, so almost
# every target depends on `gen`. The same xcodebuild flags are used here and in
# .github/workflows/ci.yml; keep them in step.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

PROJECT := Steno.xcodeproj
SCHEME := Steno
CORE := Packages/StenoCore
BUILD_DIR := build
DESTINATION := platform=macOS,arch=arm64

# No Developer ID exists yet, so everything is signed ad-hoc.
SIGNING := CODE_SIGN_IDENTITY=-

# ARCHS has to be given on the command line, not just in project.yml: a project-level
# setting does not reach the SwiftPM package targets, which then build for x86_64 as
# well and fail — FluidAudio uses Float16, which does not exist on Intel macOS. Steno
# is Apple Silicon only anyway, so this is the architecture, not a workaround.
ARCH_SETTING := ARCHS=arm64

XCODEBUILD_FLAGS := \
	-project $(PROJECT) \
	-scheme $(SCHEME) \
	-destination '$(DESTINATION)' \
	-derivedDataPath $(BUILD_DIR) \
	-clonedSourcePackagesDirPath $(BUILD_DIR)/SourcePackages \
	$(SIGNING) \
	$(ARCH_SETTING)

# xcbeautify makes the output readable, but must not swallow a failure — hence the
# pipefail above. Fall back to raw output when it is not installed.
PRETTY := $(shell command -v xcbeautify 2>/dev/null || echo cat)

.PHONY: all gen test test-core test-app build run release bump clean help

all: test

help:
	@echo "gen        regenerate $(PROJECT) from project.yml"
	@echo "test       StenoCore unit tests, then the app test bundle"
	@echo "test-core  StenoCore unit tests only (no Xcode needed)"
	@echo "build      Release build into $(BUILD_DIR)/"
	@echo "run        Debug build, then open the app"
	@echo "release    VERSION=x.y.z  build and package dist/Steno-x.y.z.zip (publishes nothing)"
	@echo "bump       VERSION=x.y.z  changelog, project.yml, commit, annotated tag (never pushes)"
	@echo "clean      remove $(BUILD_DIR)/ and $(PROJECT)"

## Regenerate the Xcode project. Run this after touching project.yml or adding files.
gen:
	xcodegen generate

## Everything: the pure logic first, because it fails fastest.
test: test-core test-app

## The framework-free logic. Needs no Xcode project and no host app.
test-core:
	swift test --package-path $(CORE)

## The app bundle: proves it builds, links its packages, and hosts its tests.
test-app: gen
	set -o pipefail && xcodebuild test $(XCODEBUILD_FLAGS) | $(PRETTY)

build: gen
	set -o pipefail && xcodebuild build $(XCODEBUILD_FLAGS) -configuration Release | $(PRETTY)

## Debug build, then hand it to Launch Services. The app has no Dock icon — look for
## the microphone in the menu bar.
run: gen
	set -o pipefail && xcodebuild build $(XCODEBUILD_FLAGS) -configuration Debug | $(PRETTY)
	open $(BUILD_DIR)/Build/Products/Debug/Steno.app

## The release build, packaged the way the workflow packages it: same flags, same
## version overrides, same ditto archive. Signs ad-hoc unless DEVELOPER_ID_IDENTITY is
## set, and writes an appcast only with SPARKLE_KEY_FILE set. Nothing is published.
release:
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=1.2.3" >&2; exit 2; }
	scripts/release.sh $(VERSION)

## Cut a version: the Unreleased notes become a dated section, project.yml is bumped,
## both are committed, and an annotated tag is created. Pushing stays a separate,
## deliberate command — the tag reaching origin is what publishes a release.
bump:
	@test -n "$(VERSION)" || { echo "usage: make bump VERSION=1.2.3" >&2; exit 2; }
	scripts/bump-version.sh $(VERSION)

clean:
	rm -rf $(BUILD_DIR) $(PROJECT) $(CORE)/.build
