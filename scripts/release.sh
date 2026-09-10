#!/usr/bin/env bash
#
# Builds and packages a release locally, the same way .github/workflows/release.yml
# does on a tag. Useful for checking that a release would build before pushing the tag
# that publishes one, and for producing a zip to hand somebody directly.
#
# What it does NOT do is publish: no tag is pushed, no GitHub release is created, and
# nothing is uploaded. The output is `dist/Steno-<version>.zip` and, if a signing key
# is available, `dist/appcast.xml`.
#
# Signing follows what is on the machine:
#
#   DEVELOPER_ID_IDENTITY   Codesign identity to use, e.g. "Developer ID Application:
#                           Max Nuglisch (ABCDE12345)". Unset means ad-hoc ("-"),
#                           which is what the project ships with until a certificate
#                           exists. Notarization is never attempted here; the workflow
#                           does that.
#   SPARKLE_KEY_FILE        Path to the exported EdDSA private key. Unset means no
#                           appcast is generated — the key normally lives in the login
#                           keychain and in the repository secret, not in a file.
#
# Usage:  scripts/release.sh 1.2.3
#         DEVELOPER_ID_IDENTITY="Developer ID Application: …" scripts/release.sh 1.2.3

set -euo pipefail

usage() {
	cat >&2 <<'USAGE'
usage: release.sh <version>

Builds Release, packages dist/Steno-<version>.zip, and — with SPARKLE_KEY_FILE set —
writes dist/appcast.xml. Publishes nothing.
USAGE
}

case "${1:-}" in
"" | -h | --help)
	usage
	[[ -z "${1:-}" ]] && exit 2 || exit 0
	;;
esac

version="${1#v}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

# The same number the workflow computes, so a local zip and a published one made from
# the same commit carry the same CFBundleVersion.
build_number="$(git rev-list --count HEAD)"
app="build/Build/Products/Release/Steno.app"
dist="dist"
zip="$dist/Steno-$version.zip"
notes="$dist/Steno-$version.md"
sparkle_tools="build/SourcePackages/artifacts/sparkle/Sparkle/bin"
repo_url="https://github.com/maxnuglisch21m/steno"

echo "==> Steno $version (build $build_number)"

mkdir -p "$dist"

# First, because it is the cheapest thing that can fail and the only one that is about
# the release rather than about the code.
scripts/changelog-extract.sh --prerelease-fallback "$version" > "$notes"

identity="${DEVELOPER_ID_IDENTITY:--}"
if [[ "$identity" == "-" ]]; then
	echo "==> signing ad-hoc (set DEVELOPER_ID_IDENTITY for a Developer ID)"
	# Left empty, and expanded below with the `+` idiom: under `set -u`, bash 3.2 —
	# which is what /bin/bash is on macOS — treats "${array[@]}" on an empty array as
	# an unbound variable.
	extra_settings=()
else
	echo "==> signing as $identity"
	# The strict entitlements: with one certificate over app and framework, library
	# validation passes without the ad-hoc exception. See Config/Steno-adhoc.entitlements.
	extra_settings=(
		OTHER_CODE_SIGN_FLAGS=--timestamp
		CODE_SIGN_ENTITLEMENTS=Config/Steno.entitlements
		# get-task-allow is injected by default and is a notarization
		# rejection: a distributable build must not be debuggable.
		CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
	)
fi

# Resolved once rather than in the pipeline, so that a failing build is not rescued by
# the fallback: `xcodebuild | { xcbeautify || cat; }` would swallow the exit code.
if command -v xcbeautify > /dev/null 2>&1; then pretty=xcbeautify; else pretty=cat; fi

echo "==> generating the Xcode project"
xcodegen generate

echo "==> building"
# ARCHS on the command line, as in the Makefile and in CI: a project-level setting does
# not reach the SwiftPM package targets.
xcodebuild build \
	-project Steno.xcodeproj \
	-scheme Steno \
	-configuration Release \
	-destination 'generic/platform=macOS' \
	-derivedDataPath build \
	-clonedSourcePackagesDirPath build/SourcePackages \
	ARCHS=arm64 \
	MARKETING_VERSION="$version" \
	CURRENT_PROJECT_VERSION="$build_number" \
	CODE_SIGN_IDENTITY="$identity" \
	CODE_SIGN_STYLE=Manual \
	${extra_settings[@]+"${extra_settings[@]}"} \
	| "$pretty"

echo "==> verifying the signature"
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --verbose=2 "$app/Contents/Frameworks/Sparkle.framework" 2>&1

echo "==> packaging"
rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"

if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
	echo "==> generating the appcast"
	if [[ ! -x "$sparkle_tools/generate_appcast" ]]; then
		echo "release.sh: no generate_appcast at $sparkle_tools — resolve the packages first" >&2
		exit 1
	fi
	"$sparkle_tools/generate_appcast" "$dist/" \
		--ed-key-file "$SPARKLE_KEY_FILE" \
		--download-url-prefix "$repo_url/releases/download/v$version/" \
		--embed-release-notes \
		--link "$repo_url" \
		--full-release-notes-url "$repo_url/blob/main/CHANGELOG.md" \
		--maximum-versions 3 \
		-o "$dist/appcast.xml"
	xmllint --noout "$dist/appcast.xml"
else
	echo "==> no SPARKLE_KEY_FILE; skipping the appcast"
fi

echo
echo "==> done"
ls -lh "$dist"
echo
echo "Nothing was published. To release this version for real:"
echo "  scripts/bump-version.sh $version   # changelog, project.yml, tag"
echo "  git push origin main && git push origin v$version"
