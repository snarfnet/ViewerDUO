#!/usr/bin/env python3
import jwt, time, requests, os, hashlib
from PIL import Image

KEY_ID = 'WDXGY9WX55'
ISSUER = '2be0734f-943a-4d61-9dc9-5d9045c46fec'
p8 = open(os.path.expanduser('~/.appstoreconnect/private_keys/AuthKey_WDXGY9WX55.p8')).read()
# ja (primary) localization of the version being prepared; prepare_version.py exports it.
LOC_ID = os.environ.get('LOC_ID', '54ed03bd-b419-4acc-94cb-0c7b8a1706ee')

SETS = [('APP_IPHONE_67', 'shots/iphone', (1290, 2796)), ('APP_IPAD_PRO_3GEN_129', 'shots/ipad', (2048, 2732))]

def normalize(path, size):
    im = Image.open(path).convert('RGB')
    if im.size != size:
        im.resize(size, Image.LANCZOS).save(path)

def tok():
    return jwt.encode({'iss': ISSUER, 'iat': int(time.time()), 'exp': int(time.time()) + 1200, 'aud': 'appstoreconnect-v1'}, p8, algorithm='ES256', headers={'kid': KEY_ID})

def api(m, p, payload=None):
    h = {'Authorization': f'Bearer {tok()}', 'Content-Type': 'application/json'}
    return requests.request(m, f'https://api.appstoreconnect.apple.com/v1{p}', headers=h, **({'json': payload} if payload else {}))

def get_set(disp):
    r = api('GET', f'/appStoreVersionLocalizations/{LOC_ID}/appScreenshotSets')
    for s in r.json().get('data', []):
        if s['attributes']['screenshotDisplayType'] == disp:
            # clear existing screenshots for a clean re-run
            e = api('GET', f"/appScreenshotSets/{s['id']}/appScreenshots")
            for sh in e.json().get('data', []):
                api('DELETE', f"/appScreenshots/{sh['id']}")
            return s['id']
    r = api('POST', '/appScreenshotSets', {'data': {'type': 'appScreenshotSets',
        'attributes': {'screenshotDisplayType': disp},
        'relationships': {'appStoreVersionLocalization': {'data': {'type': 'appStoreVersionLocalizations', 'id': LOC_ID}}}}})
    return r.json()['data']['id']

def upload_one(set_id, path):
    data = open(path, 'rb').read()
    fname = os.path.basename(path)
    r = api('POST', '/appScreenshots', {'data': {'type': 'appScreenshots',
        'attributes': {'fileSize': len(data), 'fileName': fname},
        'relationships': {'appScreenshotSet': {'data': {'type': 'appScreenshotSets', 'id': set_id}}}}})
    d = r.json()['data']
    sid = d['id']
    for op in d['attributes']['uploadOperations']:
        headers = {h['name']: h['value'] for h in op.get('requestHeaders', [])}
        chunk = data[op['offset']:op['offset'] + op['length']]
        requests.request(op['method'], op['url'], headers=headers, data=chunk)
    md5 = hashlib.md5(data).hexdigest()
    r = api('PATCH', f'/appScreenshots/{sid}', {'data': {'type': 'appScreenshots', 'id': sid,
        'attributes': {'uploaded': True, 'sourceFileChecksum': md5}}})
    print('  uploaded', fname, r.status_code, '' if r.status_code < 300 else r.text[:200])

for disp, folder, size in SETS:
    if not os.path.isdir(folder):
        print('skip (no folder)', folder)
        continue
    set_id = get_set(disp)
    print(disp, 'set', set_id)
    for f in sorted(os.listdir(folder)):
        if f.lower().endswith('.png'):
            normalize(os.path.join(folder, f), size)
            upload_one(set_id, os.path.join(folder, f))
print('Screenshots done')
