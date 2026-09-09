"""Create a consistent owner-only SQLite backup without printing study contents."""
import argparse
import os
import sqlite3
from pathlib import Path
parser=argparse.ArgumentParser()
parser.add_argument('destination',type=Path)
parser.add_argument('--source',type=Path,default=Path.home()/'Library/Application Support/RadAgent/backend/worklist.sqlite3')
args=parser.parse_args()
args.destination.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
fd=os.open(args.destination,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
os.close(fd)
with sqlite3.connect(f'file:{args.source}?mode=ro',uri=True) as source, sqlite3.connect(args.destination) as target:
    source.backup(target)
print('Consistent private database backup created.')
