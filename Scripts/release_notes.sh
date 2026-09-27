#!/usr/bin/env bash
# Prints the GitHub release notes for a version: download and first-launch steps, the version's
# CHANGELOG.md entry, and how to verify the download.
#
#   Scripts/release_notes.sh [version] [checksum-file]
#
# The version defaults to RADAR_VERSION. With a checksum file (the .dmg.sha256 that
# Scripts/release.sh writes) the notes include the SHA-256.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/project.sh"

VERSION="${1:-$RADAR_VERSION}"
CHECKSUM_FILE="${2:-}"
REPOSITORY="${RADAR_REPOSITORY:-mikkel32/ghost-process-sniper}"
TAG="v$VERSION"
DMG="$RADAR_PRODUCT-$VERSION.dmg"
URL="https://github.com/$REPOSITORY"

# The CHANGELOG entry without its "## [x.y.z] — date" heading. Relative links point into the tag.
ENTRY="$(awk -v heading="## [$VERSION]" '
  index($0, heading) == 1 { inside = 1; next }
  inside && /^## \[/ { exit }
  inside { print }
' "$RADAR_ROOT/CHANGELOG.md" | sed -e '/./,$!d' \
  | BASE="$URL/blob/$TAG" perl -pe 's{\]\((?!https?://|#|mailto:)([^)\s]+)\)}{]($ENV{BASE}/$1)}g')"
[[ -n "$ENTRY" ]] || { printf 'error: CHANGELOG.md has no entry for %s.\n' "$VERSION" >&2; exit 1; }

PREVIOUS="$(awk -v heading="## [$VERSION]" '
  index($0, heading) == 1 { found = 1; next }
  found && match($0, /^## \[[0-9]+\.[0-9]+\.[0-9]+\]/) { print substr($0, 5, RLENGTH - 5); exit }
' "$RADAR_ROOT/CHANGELOG.md")"

cat <<EOF
## Download

**[$DMG]($URL/releases/download/$TAG/$DMG)** · universal (Apple silicon and Intel) · macOS 26 Tahoe or later

1. Open the disk image and drag **$RADAR_APP_NAME** into **Applications**.
2. Open it from Applications. It lives in the menu bar; choose **Open Dashboard** for the full console.
3. The app is signed but not notarized, so the first launch shows *"Apple could not verify…"*. Click **Done**, then open **System Settings › Privacy & Security** and click **Open Anyway**. macOS remembers the choice.

Updating from an earlier version: quit Ghost from its menu, replace the app in Applications, and open it again. Settings and history are kept.

## What's new

$ENTRY

## Verify the download

EOF
if [[ -n "$CHECKSUM_FILE" ]]; then
  printf 'SHA-256: `%s`\n\n' "$(cut -d' ' -f1 "$CHECKSUM_FILE")"
fi
cat <<EOF
\`\`\`sh
shasum -a 256 -c $DMG.sha256
\`\`\`

This disk image was built from the tagged source by the [Release workflow]($URL/blob/$TAG/.github/workflows/release.yml), which publishes a signed build-provenance attestation. With the [GitHub CLI](https://cli.github.com) you can confirm the file came from that build:

\`\`\`sh
gh attestation verify $DMG --repo $REPOSITORY
\`\`\`

Prefer to build it yourself? \`git clone $URL && cd ghost-process-sniper && Scripts/dev.sh run\` ([details]($URL#build-from-source)).
EOF
if [[ -n "$PREVIOUS" ]]; then
  printf '\n**Full changelog:** [v%s…%s](%s/compare/v%s...%s)\n' "$PREVIOUS" "$TAG" "$URL" "$PREVIOUS" "$TAG"
fi
