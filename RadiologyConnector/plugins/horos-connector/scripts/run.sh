#!/bin/bash
set -euo pipefail
plugin_dir="$(cd "$(dirname "$0")/.." && pwd)"
export PYTHONPATH="$plugin_dir${PYTHONPATH:+:$PYTHONPATH}"
export PYTHONUNBUFFERED=1
runtime="$HOME/Library/Application Support/RadAgent/connector/runtime/bin/python"
if [[ -x "$plugin_dir/.venv/bin/python" ]]; then runtime="$plugin_dir/.venv/bin/python"; fi
if [[ ! -x "$runtime" ]]; then
  echo 'Install the Horos connector runtime first using scripts/install.py.' >&2
  exit 1
fi
exec "$runtime" -m horos_connector.server
