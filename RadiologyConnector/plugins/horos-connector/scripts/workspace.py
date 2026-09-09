#!/usr/bin/env python3
"""Small native-shell entry point; no shell interpolation or model API credentials."""
from pathlib import Path
import json
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from horos_connector.workspace import Workspace
from horos_connector.workspace_service import workspace_url

uid=sys.argv[1] if len(sys.argv)>1 else ""
session=Workspace().open(uid)["session_id"] if uid else ""
print(json.dumps({"url":workspace_url(session),"session_id":session}))
