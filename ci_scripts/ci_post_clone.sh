#!/bin/sh
# Xcode Cloud post-clone step. CFSpeed.xcodeproj is generated from project.yml
# by XcodeGen. It's committed so Xcode Cloud's workflow editor can see the
# schemes, but regenerate it here anyway so a build never uses a stale project
# if someone edited project.yml without running xcodegen.
#
# Xcode Cloud runs this from ci_scripts/, which must sit next to
# CFSpeed.xcodeproj (the repository root). The GitHub workflow runs it too,
# so both build with the same pinned, verified XcodeGen.
set -eu

# Keep in step with the version used locally. When bumping, take the new
# checksum from the release's asset digest:
#   gh api repos/yonaskolb/XcodeGen/releases/tags/<version> \
#     --jq '.assets[] | select(.name == "xcodegen.zip") | .digest'
XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806

cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"

tools="${TMPDIR:-/tmp}/xcodegen-$XCODEGEN_VERSION"
if [ ! -x "$tools/xcodegen/bin/xcodegen" ]; then
  mkdir -p "$tools"
  curl -fsSL --retry 3 \
    -o "$tools/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
  # This machine builds the signed release: never run a binary that isn't
  # byte-for-byte the release we pinned.
  if ! echo "$XCODEGEN_SHA256  $tools/xcodegen.zip" | shasum -a 256 -c -s; then
    echo "error: xcodegen.zip doesn't match the pinned SHA-256" >&2
    rm -f "$tools/xcodegen.zip"
    exit 1
  fi
  unzip -q -o "$tools/xcodegen.zip" -d "$tools"
fi

"$tools/xcodegen/bin/xcodegen" generate --spec project.yml
echo "Generated CFSpeed.xcodeproj with XcodeGen $XCODEGEN_VERSION"
