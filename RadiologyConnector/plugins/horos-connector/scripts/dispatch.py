#!/usr/bin/env python3
"""Local dispatcher fallback for Codex threads with an older MCP tool catalog.

Read one JSON object on stdin. Never creates a task or invokes a model itself.
"""
import json
from pathlib import Path
import sys
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from horos_connector.dispatch import Dispatcher
from horos_connector.queue import Queue


def main():
    request=json.load(sys.stdin)
    operation=request.pop('operation')
    dispatcher=Dispatcher()
    if operation=='status':
        result={'runs':dispatcher.list_runs(),'ready_jobs':[j['id'] for j in Queue().jobs(('ready',))]}
    elif operation=='reserve':result=dispatcher.reserve(request.get('job_id'))
    elif operation=='attach':result=dispatcher.attach(request['job_id'],request['reservation_token'],request['thread_id'])
    elif operation=='recover':result=dispatcher.recover(request['job_id'],request['thread_id'])
    else:raise ValueError('Supported operations: status, reserve, attach, recover.')
    print(json.dumps(result,ensure_ascii=False))

if __name__=='__main__':main()
