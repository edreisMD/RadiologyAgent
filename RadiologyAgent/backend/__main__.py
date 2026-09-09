import argparse
import uvicorn
from .app import create_app
parser = argparse.ArgumentParser()
parser.add_argument('--port', type=int, default=8043)
args = parser.parse_args()
uvicorn.run(create_app(), host='127.0.0.1', port=args.port, access_log=False)
