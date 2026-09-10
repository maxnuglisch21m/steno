#!/usr/bin/env bash
#
# Prints the CHANGELOG.md section for one version, for use as GitHub release notes
# and as the Sparkle appcast's description.
#
# A release without its own section is a release nobody can read, so a missing
# section is an error rather than an empty file — the release workflow relies on that
# exit code to fail before it publishes anything.
#
# Usage:  scripts/changelog-extract.sh 1.2.3
#         scripts/changelog-extract.sh v1.2.3          # a leading v is accepted
#         scripts/changelog-extract.sh 1.2.3 CHANGELOG.md
#         scripts/changelog-extract.sh --prerelease-fallback 1.2.3-rc.1
#
# A release candidate is cut from whatever is in `## [Unreleased]` — that is what it
# is for. Writing a section per candidate would mean writing the same notes three
# times and then deleting two of them, so `--prerelease-fallback` lets a version with
# a pre-release part (anything after a `-`) fall back to the Unreleased section when
# it has none of its own. A final release never falls back: shipping 1.2.3 with notes
# headed "Unreleased" is exactly the mistake the missing-section check exists to
# catch.

set -euo pipefail

usage() {
	cat >&2 <<'USAGE'
usage: changelog-extract.sh [--prerelease-fallback] <version> [changelog-path]

Prints the "## [<version>]" section of the changelog, without its heading.
Exits 1 if the version has no section.

  --prerelease-fallback   For a pre-release version (one containing a "-"), use the
                          "## [Unreleased]" section when the version has none of its
                          own. Ignored for final releases.
USAGE
}

fallback=0
while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--prerelease-fallback)
		fallback=1
		shift
		;;
	--)
		shift
		break
		;;
	-*)
		echo "changelog-extract.sh: unknown option $1" >&2
		usage
		exit 2
		;;
	*)
		break
		;;
	esac
done

if [[ $# -lt 1 || $# -gt 2 ]]; then
	usage
	exit 2
fi

version="${1#v}"
changelog="${2:-$(dirname "$0")/../CHANGELOG.md}"

if [[ ! -f "$changelog" ]]; then
	echo "changelog-extract.sh: no changelog at $changelog" >&2
	exit 1
fi

# Walk the file with awk: collect the lines after the heading for this version, stop
# at the next second-level heading, and drop the blank lines the section is padded
# with.
#
# The heading is matched by comparing strings rather than by building a regular
# expression out of the version — a version is full of dots, and as a pattern those
# are wildcards that would make 1.2.3 match a heading reading [1x2x3]. Escaping them
# is possible but has to survive awk's own unescaping of -v assignments, which is one
# layer of quoting too many to be sure of.
extract() {
	awk -v version="$1" '
		BEGIN { inside = 0; count = 0; needle = "## [" version "]" }
		# Matches "## [1.2.3] - 2026-09-09" and a bare "## [1.2.3]" alike, and does
		# not match "## [1.2.30]", because the closing bracket is part of the needle.
		substr($0, 1, length(needle)) == needle { inside = 1; next }
		inside && /^## / { exit }         # exit still runs END, so nothing is lost
		inside { lines[count++] = $0 }
		END {
			first = 0
			last = count - 1
			while (first <= last && lines[first] ~ /^[[:space:]]*$/) first++
			while (last >= first && lines[last] ~ /^[[:space:]]*$/) last--
			for (i = first; i <= last; i++) print lines[i]
		}
	' "$changelog"
}

section="$(extract "$version")"

# A release candidate with no section of its own reads the Unreleased one, which is
# where its notes are: the candidate exists to test what is about to be released.
if [[ -z "$section" && $fallback -eq 1 && "$version" == *-* ]]; then
	section="$(extract Unreleased)"
	if [[ -n "$section" ]]; then
		echo "changelog-extract.sh: $version has no section; using [Unreleased]" >&2
	fi
fi

if [[ -z "$section" ]]; then
	echo "changelog-extract.sh: CHANGELOG.md has no section for version $version" >&2
	echo "changelog-extract.sh: add a '## [$version] - YYYY-MM-DD' heading before releasing" >&2
	exit 1
fi

printf '%s\n' "$section"
