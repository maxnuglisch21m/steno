#!/usr/bin/env bash
#
# Cuts a version: turns the collected `## [Unreleased]` notes into a dated section,
# opens a fresh empty one above it, refreshes the comparison links at the foot of the
# changelog, bumps MARKETING_VERSION in project.yml, commits both files, and creates
# the annotated tag the release workflow reacts to.
#
# It never pushes. Pushing is the irreversible half — a tag that reaches the remote
# publishes a release — and it stays a deliberate second command, printed at the end.
#
# Usage:  scripts/bump-version.sh 0.1.0
#         scripts/bump-version.sh 0.2.0 --no-tag                 # files only
#         scripts/bump-version.sh 0.2.0 --changelog /tmp/copy.md --no-tag   # dry run

set -euo pipefail

usage() {
	cat >&2 <<'USAGE'
usage: bump-version.sh <x.y.z> [--changelog PATH] [--project PATH] [--date YYYY-MM-DD]
                               [--no-tag]

Renames "## [Unreleased]" to "## [x.y.z] - <date>", opens a fresh Unreleased section,
rewrites the comparison links, sets MARKETING_VERSION in project.yml, commits, and
creates the annotated tag vx.y.z. Never pushes.

  --changelog PATH   changelog to edit (default: CHANGELOG.md next to this script)
  --project PATH     project definition to edit (default: project.yml)
  --date YYYY-MM-DD  date for the new section (default: today)
  --no-tag           edit the files and stop: no commit, no tag
USAGE
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
changelog="$repo_root/CHANGELOG.md"
project="$repo_root/project.yml"
date="$(date +%F)"
make_tag=1
version=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--changelog)
		changelog="$2"
		shift 2
		;;
	--project)
		project="$2"
		shift 2
		;;
	--date)
		date="$2"
		shift 2
		;;
	--no-tag)
		make_tag=0
		shift
		;;
	-*)
		echo "bump-version.sh: unknown option $1" >&2
		usage
		exit 2
		;;
	*)
		if [[ -n "$version" ]]; then
			echo "bump-version.sh: more than one version given" >&2
			exit 2
		fi
		version="${1#v}"
		shift
		;;
	esac
done

if [[ -z "$version" ]]; then
	usage
	exit 2
fi

# Semantic versioning, optionally with a pre-release part: 1.2.3 or 1.2.3-rc.1. Build
# metadata (+something) is not accepted, because it cannot go in a tag name unescaped.
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
	echo "bump-version.sh: '$version' is not a version like 1.2.3 or 1.2.3-rc.1" >&2
	exit 2
fi

tag="v$version"
repo_url="https://github.com/maxnuglisch21m/steno"

for file in "$changelog" "$project"; do
	if [[ ! -f "$file" ]]; then
		echo "bump-version.sh: no file at $file" >&2
		exit 1
	fi
done

if grep -q "^## \[$version\]" "$changelog"; then
	echo "bump-version.sh: $changelog already has a section for $version" >&2
	exit 1
fi

if ! grep -q '^## \[Unreleased\]' "$changelog"; then
	echo "bump-version.sh: $changelog has no '## [Unreleased]' section to cut" >&2
	exit 1
fi

# A version whose notes are empty is a version nobody can read. Catching it here beats
# catching it in the workflow, after the tag has been pushed.
if ! "$repo_root/scripts/changelog-extract.sh" Unreleased "$changelog" > /dev/null 2>&1; then
	echo "bump-version.sh: '## [Unreleased]' is empty — nothing to release" >&2
	exit 1
fi

# The version this one follows, for the comparison link. The first released section in
# the file, which is the newest, because the changelog is newest-first.
previous="$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "$changelog" | head -1)"

if [[ -n "$previous" ]]; then
	echo "==> $version ($date), after $previous"
else
	echo "==> $version ($date), the first release"
fi

# The rewrite, in one awk pass:
#   · the Unreleased heading becomes an empty Unreleased plus the dated heading
#   · existing link definitions at the foot are dropped, to be re-emitted below
tmp="$(mktemp)"
trap 'rm -f "$tmp" "$tmp.body" "$tmp.out"' EXIT

awk -v version="$version" -v date="$date" '
	/^## \[Unreleased\]/ {
		print "## [Unreleased]"
		print ""
		print "## [" version "] - " date
		next
	}
	# Link definitions are collected rather than printed; the block is rebuilt whole,
	# so that the Unreleased comparison always points at the newest tag.
	/^\[[^]]+\]: https?:\/\// { next }
	{ print }
' "$changelog" > "$tmp"

# Trailing blank lines, so the link block is separated by exactly one.
awk 'BEGIN { blanks = 0 }
	/^[[:space:]]*$/ { blanks++; next }
	{ while (blanks-- > 0) print ""; blanks = 0; print }
' "$tmp" > "$tmp.body"

{
	cat "$tmp.body"
	echo
	echo "[Unreleased]: $repo_url/compare/$tag...HEAD"
	if [[ -n "$previous" ]]; then
		echo "[$version]: $repo_url/compare/v$previous...$tag"
	else
		echo "[$version]: $repo_url/releases/tag/$tag"
	fi
	# Every older version keeps a link too, each comparing against the one before it.
	sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "$changelog" | awk -v url="$repo_url" '
		{ versions[NR] = $0 }
		END {
			for (i = 1; i <= NR; i++) {
				if (i < NR)
					printf "[%s]: %s/compare/v%s...v%s\n", versions[i], url, versions[i + 1], versions[i]
				else
					printf "[%s]: %s/releases/tag/v%s\n", versions[i], url, versions[i]
			}
		}
	'
} > "$tmp.out"

mv "$tmp.out" "$changelog"
rm -f "$tmp.body"

# MARKETING_VERSION, so that a build made without the workflow's overrides still says
# the right thing in Finder.
if ! grep -q '^    MARKETING_VERSION: ' "$project"; then
	echo "bump-version.sh: no MARKETING_VERSION line in $project" >&2
	exit 1
fi
# The pre-release part contains dots and dashes but nothing sed treats specially in a
# replacement, and the version has already been validated against the pattern above.
sed -i '' "s/^    MARKETING_VERSION: .*/    MARKETING_VERSION: $version/" "$project"

echo "==> updated $(basename "$changelog") and $(basename "$project")"

if [[ $make_tag -eq 0 ]]; then
	echo "==> --no-tag: stopping before the commit"
	exit 0
fi

cd "$repo_root"
git add "$changelog" "$project"
git commit -m "chore(release): $version"
git tag -a "$tag" -m "Steno $version"

echo
echo "==> committed and tagged $tag. Nothing has been pushed."
echo "Push when you are ready — the tag is what publishes the release:"
echo "  git push origin main && git push origin $tag"
