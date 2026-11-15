#!/bin/sh
# Xcode Cloud post-clone step. CFSpeed.xcodeproj is generated from project.yml
# by XcodeGen. It's committed so Xcode Cloud's workflow editor can see the
# schemes, but regenerate it here anyway so a build never uses a stale project
# if someone edited project.yml without running xcodegen.
#
# Xcode Cloud runs this from ci_scripts/, which must sit next to
# CFSpeed.xcodeproj (the repository root).
set -eu

XCODEGEN_VERSION=2.46.0 # keep in step with the version used locally

cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"

tools="${TMPDIR:-/tmp}/xcodegen-$XCODEGEN_VERSION"
if [ ! -x "$tools/xcodegen/bin/xcodegen" ]; then
  mkdir -p "$tools"
  curl -fsSL --retry 3 \
    -o "$tools/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
  unzip -q -o "$tools/xcodegen.zip" -d "$tools"
fi

"$tools/xcodegen/bin/xcodegen" generate --spec project.yml
echo "Generated CFSpeed.xcodeproj with XcodeGen $XCODEGEN_VERSION"
