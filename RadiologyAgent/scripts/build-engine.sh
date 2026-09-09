#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p dist/RadAgentEngine.horosplugin/Contents/MacOS
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$PWD/.build/clang-cache" -mmacosx-version-min=14.0 -bundle -undefined dynamic_lookup -framework Cocoa -framework CoreData -framework Security EnginePlugin/RadAgentEngine.m -o dist/RadAgentEngine.horosplugin/Contents/MacOS/RadAgentEngine
cp EnginePlugin/Info.plist dist/RadAgentEngine.horosplugin/Contents/Info.plist
codesign --force --sign - dist/RadAgentEngine.horosplugin
