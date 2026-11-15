#!/bin/sh
# Xcode Cloud post-clone step. The Xcode project is generated from
# project.yml by XcodeGen and isn't committed, so generate it here, before
# Xcode Cloud resolves packages and builds.
#
# Xcode Cloud runs this from ci_scripts/, which must sit next to where
# CFSpeed.xcodeproj will be (the repository root).
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
