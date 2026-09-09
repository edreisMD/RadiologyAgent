#!/usr/bin/env python3
"""Install the research connector without stopping Horos or creating a schedule."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT / 'plugins/horos-connector'
NOTICE = 'Not for medical use, research only.'


def codex_cli():
    found = shutil.which('codex')
    if found:
        return found
    for app in ('Codex', 'ChatGPT'):
        path = Path('/Applications') / (app + '.app') / 'Contents/Resources/codex'
        if path.is_file():
            return str(path)
    return None


def run(command, cwd=None):
    subprocess.run([str(x) for x in command], cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report-directory', type=Path)
    parser.add_argument('--listener', action='store_true')
    parser.add_argument('--skip-codex', action='store_true')
    parser.add_argument('--check', action='store_true', help='Read-only prerequisite check')
    parser.add_argument('--dry-run', action='store_true', help='Show operations without making changes')
    parser.add_argument('--horos-app', type=Path, default=Path('/Applications/Horos.app'))
    args = parser.parse_args()
    print(NOTICE)
    problems = []
    if platform.system() != 'Darwin' or tuple(map(int, (platform.mac_ver()[0] or '0').split('.')[:1])) < (14,):
        problems.append('macOS 14 or later is required.')
    if sys.version_info < (3, 12):
        problems.append('Run this installer with Python 3.12 or later.')
    if not args.horos_app.is_dir():
        problems.append('Install Horos first, or provide --horos-app /path/to/Horos.app.')
    for binary in ('npm', 'node', 'clang', 'codesign', 'ffmpeg'):
        if not shutil.which(binary):
            problems.append(f'{binary} is missing from PATH.')
    if shutil.which('node'):
        version = subprocess.check_output(['node', '--version'], text=True).strip().lstrip('v')
        major, minor = map(int, version.split('.')[:2])
        if not ((major == 20 and minor >= 19) or (major == 22 and minor >= 12) or major > 22):
            problems.append('Node.js 20.19+ or 22.12+ is required by the pinned frontend build.')
    codex = None if args.skip_codex else codex_cli()
    if not args.skip_codex and not codex:
        problems.append('Install the Codex CLI or use --skip-codex.')
    destination = args.report_directory.expanduser().resolve() if args.report_directory else None
    if destination and not destination.is_dir():
        problems.append('Create the requested report directory before installing.')
    if problems:
        raise SystemExit('\n'.join(problems))
    if args.check:
        print('Prerequisites available. No configuration changed.')
        return
    bridge = Path.home() / 'Library/Application Support/Horos/Plugins/RadAgentEngine.horosplugin'
    command = [codex, 'mcp', 'add', 'radiology-connector', '--', '/bin/bash', str(PLUGIN/'scripts/run.sh')] if codex else None
    if args.dry_run:
        print(json.dumps({'plugin': str(PLUGIN), 'build': ['npm ci', 'npm run build', 'bash scripts/build-engine.sh'],
            'native_bridge': str(bridge), 'backup_existing_bridge': True,
            'runtime': str(Path.home()/'Library/Application Support/RadAgent/connector/runtime'),
            'report_directory': str(destination) if destination else 'Preserve existing configuration',
            'listener': args.listener, 'codex_registration': command,
            'restart_horos': False, 'create_automation': False}, indent=2))
        return
    # Fail before installation if this MCP name belongs to unrelated software.
    if codex:
        existing = subprocess.run([codex, 'mcp', 'get', 'radiology-connector', '--json'], capture_output=True, text=True)
        if existing.returncode == 0:
            transport = json.loads(existing.stdout).get('transport', {})
            prior = [transport.get('command', ''), *transport.get('args', [])]
            if not any(str(x).endswith('/horos-connector/scripts/run.sh') for x in prior):
                raise SystemExit('The MCP name radiology-connector belongs to another configuration; it was preserved.')
    os.umask(0o077)
    web = PLUGIN / 'horos_connector/web'
    run(['npm', 'ci'], web)
    run(['npm', 'run', 'build'], web)
    run(['bash', PLUGIN/'scripts/build-engine.sh'])
    bridge.parent.mkdir(parents=True, exist_ok=True)
    if bridge.exists():
        stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
        backup = Path.home()/'Library/Application Support/RadAgent/connector/plugin-backups'/stamp/bridge.name
        backup.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(bridge, backup)
        print(f'Previous bridge preserved at {backup}')
    shutil.copytree(PLUGIN/'dist/RadAgentEngine.horosplugin', bridge, dirs_exist_ok=True)
    install = [sys.executable, PLUGIN/'scripts/install.py']
    if destination:
        install += ['--report-directory', destination]
    if args.listener:
        install += ['--listener']
    run(install)
    if command:
        run(command)
    print('Installation complete. Reopen Horos when safe, then start a new Codex task to load the tools.')
    print('Read RadiologyConnector/AGENTS.md for the image-review and reporting workflow.')


if __name__ == '__main__':
    main()
