#!/bin/sh
# Xcode Cloud pre-build step. GitHub CI is manual-only, so this is what keeps
# a release from shipping with failing engine tests: before each archive,
# run the CFSpeedKit tests and stop the build if any fail.
#
# It runs for every archive action (iOS, tvOS, macOS). Each may run on its
# own machine, and an action whose tests didn't run couldn't be blocked by
# them, so none is skipped. The live integration test skips itself unless
# CF_SPEEDTEST_LIVE=1, so this sends no speed-test traffic.
set -eu

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
  exit 0
fi

cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}/Packages/CFSpeedKit"
swift test
