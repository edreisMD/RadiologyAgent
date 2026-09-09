#!/bin/bash
set -euo pipefail
plugin_dir="$(cd "$(dirname "$0")/.." && pwd)"
output="$plugin_dir/dist/RadAgentEngine.horosplugin"
mkdir -p "$output/Contents/MacOS"
clang -bundle -fobjc-arc -framework Cocoa -framework CoreData -framework Security -undefined dynamic_lookup -mmacosx-version-min=14.0 "$plugin_dir/native/RadAgentEngine.m" -o "$output/Contents/MacOS/RadAgentEngine"
cp "$plugin_dir/native/Info.plist" "$output/Contents/Info.plist"
codesign --force --sign - "$output"
