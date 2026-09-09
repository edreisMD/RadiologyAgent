"""Read-only integration check against the installed Horos engine. Prints no patient data."""
import base64
import argparse
import hashlib
import json
import pathlib
import urllib.error
import urllib.request

connection = json.loads((pathlib.Path.home() / 'Library/Application Support/RadAgent/engine-connection.json').read_text())
parser = argparse.ArgumentParser()
parser.add_argument('--study', default='', help='Select a named test study without printing patient metadata.')
args = parser.parse_args()
base = 'http://127.0.0.1:' + str(connection['port'])

def call(route, body=None, authorized=True, origin=False):
    headers = {'Content-Type': 'application/json'}
    if authorized:
        headers['Authorization'] = 'Bearer ' + connection['token']
    if origin:
        headers['Origin'] = 'https://example.invalid'
    request = urllib.request.Request(base + route, data=json.dumps(body or {}).encode(), headers=headers)
    with urllib.request.urlopen(request, timeout=90) as response:
        return json.load(response)

health = call('/health')
assert health['databaseReady'] and health['engine'] == 'Horos'
print('PASS: Horos native engine health')
for authorized, origin, expected in [(False, False, 401), (True, True, 403)]:
    try:
        call('/health', authorized=authorized, origin=origin)
        raise AssertionError('Expected rejection')
    except urllib.error.HTTPError as error:
        assert error.code == expected
print('PASS: unauthorized and browser-origin requests rejected')
studies = call('/studies', {'search': args.study})['studies']
print('Native study count:', len(studies))
assert studies, 'Import a test DICOM study into Horos to verify rendering.'
if args.study:
    assert len(studies) == 1, 'The test study search must identify exactly one study.'
detail = call('/study', {'id': studies[0]['id']})
frames = [frame for series in detail['series'] for frame in series['frames']]
assert len(frames) == detail['frameCount']
print('PASS: complete series/frame enumeration; series:', len(detail['series']), 'frames:', len(frames))
first = call('/render', {'studyID': studies[0]['id'], 'imageID': frames[0]['id']})
png = base64.b64decode(first['png'])
assert png.startswith(b'\x89PNG\r\n\x1a\n') and first['width'] > 0 and first['height'] > 0
print('PASS: native DCMPix rendering; dimensions:', first['width'], 'x', first['height'])
second = call('/render', {'studyID': studies[0]['id'], 'imageID': frames[0]['id'], 'width': max(1, first['windowWidth'] * .6), 'center': first['windowCenter'] + 30})
assert hashlib.sha256(png).digest() != hashlib.sha256(base64.b64decode(second['png'])).digest()
print('PASS: native window/level changes DICOM rendering')
reset = call('/render', {'studyID': studies[0]['id'], 'imageID': frames[0]['id']})
assert hashlib.sha256(png).digest() == hashlib.sha256(base64.b64decode(reset['png'])).digest()
print('PASS: default window restores the original native rendering')
try:
    call('/render', {'studyID': 'x-coredata://wrong-study', 'imageID': frames[0]['id']})
    raise AssertionError('Expected study mismatch rejection')
except urllib.error.HTTPError as error:
    assert error.code == 422
print('PASS: cross-study image request rejected')
nodes = call('/pacs/nodes')['nodes']
print('Configured PACS node count:', len(nodes))
print('No PACS retrieval, image export, report write, or patient data transmission performed.')
