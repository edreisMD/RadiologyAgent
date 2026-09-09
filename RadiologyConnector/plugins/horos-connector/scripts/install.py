#!/usr/bin/env python3
"""Install this connector's private runtime and optional macOS listener."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys

parser=argparse.ArgumentParser()
parser.add_argument('--report-directory', type=Path)
parser.add_argument('--listener', action='store_true')
args=parser.parse_args()
os.umask(0o077)
plugin=Path(__file__).resolve().parents[1]
root=Path.home()/'Library/Application Support/RadAgent/connector'
root.mkdir(parents=True,exist_ok=True,mode=0o700)
configuration=root/'config.json'
config=json.loads(configuration.read_text()) if configuration.exists() else {}
if args.report_directory:
    destination=args.report_directory.expanduser().resolve()
    if not destination.is_dir(): raise SystemExit('Create the destination report folder first.')
    config['report_directory']=str(destination)
config.update(scope='all_new',quiet_seconds=30,language='English')
from tempfile import NamedTemporaryFile
with NamedTemporaryFile(mode='w', dir=root, delete=False) as out:
    json.dump(config,out,ensure_ascii=False,indent=2); temporary=out.name
os.replace(temporary,configuration)
runtime=root/'runtime'
if not (runtime/'bin/python').exists(): subprocess.run([sys.executable,'-m','venv',str(runtime)],check=True)
python=runtime/'bin/python'
subprocess.run([str(python),'-m','pip','install','--disable-pip-version-check','-r',str(plugin/'requirements.txt')],check=True)
if args.listener:
    label='org.radiologyagent.horos-listener'
    destination=Path.home()/'Library/LaunchAgents'/f'{label}.plist'
    destination.parent.mkdir(parents=True,exist_ok=True)
    job={'Label':label,'ProgramArguments':[str(python),'-m','horos_connector.listener'],'EnvironmentVariables':{'PYTHONPATH':str(plugin),'PYTHONUNBUFFERED':'1','PATH':'/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'},'RunAtLoad':True,'KeepAlive':True,'ThrottleInterval':30,'StandardOutPath':str(root/'listener.stdout.log'),'StandardErrorPath':str(root/'listener.stderr.log')}
    if destination.exists():
        old=plistlib.loads(destination.read_bytes())
        if old.get('Label')!=label or 'horos_connector.listener' not in old.get('ProgramArguments',[]): raise SystemExit('Existing launch agent does not belong to this connector.')
        subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(destination)],check=False,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    destination.write_bytes(plistlib.dumps(job)); destination.chmod(0o600)
    subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(destination)],check=True)
print('Installed Horos connector runtime'+(' and background listener.' if args.listener else '.'))
