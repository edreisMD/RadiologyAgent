#!/usr/bin/env python3
"""Install the requested Radiology Agent research components from this checkout."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CONNECTOR = ROOT / 'RadiologyConnector/scripts/setup.py'
NOTICE = 'Not for medical use, research only.'


def install_app(source, destination):
    """Preserve the old bundle and replace only this application's bundle."""
    source, destination = Path(source), Path(destination)
    if not (source/'Contents/MacOS/RadAgent').is_file():
        raise RuntimeError('The app build did not produce the expected executable.')
    if destination.is_symlink():
        raise RuntimeError('The application destination is a symlink; it was preserved.')
    destination.parent.mkdir(parents=True, exist_ok=True)
    staged = destination.with_name('.Radiology Agent.installing.app')
    if staged.exists():
        raise RuntimeError(f'An earlier staged install remains at {staged}. Inspect it before retrying.')
    shutil.copytree(source, staged)
    backup = None
    try:
        if destination.exists():
            stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
            backup = destination.with_name(f'Radiology Agent.backup-{stamp}.app')
            destination.rename(backup)
        staged.rename(destination)
    except Exception:
        if backup and backup.exists() and not destination.exists():
            backup.rename(destination)
        if staged.exists():
            shutil.rmtree(staged)
        raise
    return backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--component', choices=['connector', 'app', 'both'], default='both')
    parser.add_argument('--report-directory', type=Path)
    parser.add_argument('--listener', action='store_true', help='Enable the incoming-study listener; no schedule is created')
    parser.add_argument('--app-directory', type=Path, default=Path.home()/'Applications')
    parser.add_argument('--horos-app', type=Path, default=Path('/Applications/Horos.app'))
    parser.add_argument('--check', action='store_true', help='Check prerequisites without installing')
    parser.add_argument('--dry-run', action='store_true', help='Show installation operations without changing configuration')
    args = parser.parse_args()
    print(NOTICE, flush=True)
    app = args.component in ('app', 'both')
    if app and not shutil.which('swift'):
        raise SystemExit('The Swift toolchain is required to build the Mac app. Install Xcode Command Line Tools.')
    command = [sys.executable, str(CONNECTOR), '--horos-app', str(args.horos_app.expanduser())]
    if args.component == 'app':
        command += ['--skip-codex']
    if args.report_directory:
        command += ['--report-directory', str(args.report_directory.expanduser())]
    if args.listener:
        command += ['--listener']
    if args.check:
        command += ['--check']
    elif args.dry_run:
        command += ['--dry-run']
    subprocess.run(command, check=True)
    if args.check:
        return
    destination = args.app_directory.expanduser().resolve()/'Radiology Agent.app'
    if args.dry_run:
        print(json.dumps({'component': args.component,
            'app_build': 'bash RadiologyAgent/scripts/build.sh' if app else None,
            'app_destination': str(destination) if app else None,
            'backup_existing_app': app, 'restart_horos': False,
            'launch_app': False, 'create_schedule': False}, indent=2))
        return
    if app:
        subprocess.run(['bash', str(ROOT/'RadiologyAgent/scripts/build.sh')], check=True)
        backup = install_app(ROOT/'RadiologyAgent/dist/Radiology Agent.app', destination)
        if backup:
            print(f'Previous app preserved: {backup}')
        print(f'Installed: {destination}')
    print('Setup complete. Reopen Horos when safe. Start a new Codex task if you installed the connector.')
    print('Follow docs/INSTALLATION.md for verification. No existing report or patient study was changed.')


if __name__ == '__main__':
    main()
