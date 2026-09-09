#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Package the supplied artwork without redrawing it. Its visible mark occupies
# a centered 412 px square in the 1920 x 1080 transparent source canvas.
source_file="${1:-Resources/RadiologyAgentLogo.source.png}"
iconset='.build/brand/RadAgent.iconset'
connector_source_dir="${RADIOLOGY_CONNECTOR_SOURCE:-../RadiologyConnector/plugins/horos-connector}"
mkdir -p "$iconset" "$connector_source_dir/horos_connector/web/assets"
sips -c 512 512 --cropOffset 284 704 "$source_file" --out Resources/RadiologyAgentLogo.png >/dev/null
cp Resources/RadiologyAgentLogo.png "$connector_source_dir/horos_connector/web/assets"/radiology-agent.png
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Resources/RadiologyAgentLogo.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" Resources/RadiologyAgentLogo.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
# ICNS is a container of these original PNG renditions. Building its chunks also
# works in restricted build environments where iconutil cannot encode icons.
python3 - <<'ICNS'
from pathlib import Path
import struct
folder=Path('.build/brand/RadAgent.iconset')
entries=[('icp4','icon_16x16.png'),('icp5','icon_32x32.png'),('icp6','icon_32x32@2x.png'),('ic07','icon_128x128.png'),('ic08','icon_256x256.png'),('ic09','icon_512x512.png'),('ic10','icon_512x512@2x.png'),('ic11','icon_16x16@2x.png'),('ic12','icon_32x32@2x.png'),('ic13','icon_128x128@2x.png'),('ic14','icon_256x256@2x.png')]
chunks=[]
for kind,name in entries:
 data=(folder/name).read_bytes();chunks.append(kind.encode()+struct.pack('>I',len(data)+8)+data)
body=b''.join(chunks)
Path('Resources/RadAgent.icns').write_bytes(b'icns'+struct.pack('>I',len(body)+8)+body)
ICNS
