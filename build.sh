#!/bin/bash
# Builds build/QuickChat.app. Compiler scratch and temp files stay inside this repository.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/tmp
export TMPDIR="$PWD/.build/tmp"
export CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache"
swift build -c release --scratch-path .build
APP=build/QuickChat.app
mkdir -p "$APP/Contents/MacOS"
cp .build/release/QuickChat "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "built $APP"
