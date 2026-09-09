#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/cache .build/clang-cache "dist/Radiology Agent.app"/Contents/MacOS "dist/Radiology Agent.app"/Contents/Resources
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache"
swift build -c release --disable-sandbox --cache-path "$PWD/.build/cache"
connector_source_dir="${RADIOLOGY_CONNECTOR_SOURCE:-../RadiologyConnector/plugins/horos-connector}"
export RADIOLOGY_CONNECTOR_SOURCE="$connector_source_dir"
npm --prefix "$connector_source_dir/horos_connector/web" run build
bash "$connector_source_dir/scripts/build-engine.sh"
ditto "$connector_source_dir/dist/RadAgentEngine.horosplugin" dist/RadAgentEngine.horosplugin
cp .build/release/RadAgent "dist/Radiology Agent.app"/Contents/MacOS/RadAgent
cp Resources/Info.plist "dist/Radiology Agent.app"/Contents/Info.plist
ditto dist/RadAgentEngine.horosplugin "dist/Radiology Agent.app"/Contents/Resources/RadAgentEngine.horosplugin
if [ -f Resources/RadiologyAgentLogo.png ]; then
  cp Resources/RadiologyAgentLogo.png "dist/Radiology Agent.app"/Contents/Resources/RadiologyAgentLogo.png
fi
if [ -f Resources/RadAgent.icns ]; then
  cp Resources/RadAgent.icns "dist/Radiology Agent.app"/Contents/Resources/RadAgent.icns
fi
python3 - <<'BUNDLE'
from pathlib import Path
import shutil
import os
source=Path(os.environ['RADIOLOGY_CONNECTOR_SOURCE'])
output=Path('dist/Radiology Agent.app/Contents/Resources/HorosConnector')
if output.exists(): shutil.rmtree(output)
output.mkdir(parents=True,exist_ok=True)
for name in ['horos_connector','scripts','skills','requirements.txt','README.md','LICENSE','THIRD_PARTY_NOTICES.md']:
    src=source/name;dst=output/name
    if src.is_dir():shutil.copytree(src,dst,dirs_exist_ok=True,ignore=shutil.ignore_patterns('node_modules','__pycache__','.venv','.pytest_cache'))
    elif src.is_file():shutil.copy2(src,dst)
BUNDLE
codesign --force --deep --sign - "dist/Radiology Agent.app"
echo "Built $PWD/dist/Radiology Agent.app"
