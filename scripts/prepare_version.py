#!/usr/bin/env python3
"""Finds or creates the App Store version named in project.yml and fills in "What's New".

Writes VERSION_ID and LOC_ID (ja localization) to $GITHUB_ENV for the later steps."""
import jwt, time, requests, os, re, sys

KEY_ID = 'WDXGY9WX55'
ISSUER = '2be0734f-943a-4d61-9dc9-5d9045c46fec'
p8 = open(os.path.expanduser('~/.appstoreconnect/private_keys/AuthKey_WDXGY9WX55.p8')).read()
APP_ID = '6811308523'

WHATS_NEW = {
    'ja': (
        '・新機能「2枚ずつスライド」：連番の画像を左右に並べ、スワイプで2枚同時に切り替えます\n'
        '・画像フォルダや、まとめて選んだ画像を1冊の本として取り込めるようになりました\n'
        '・漫画などの固定レイアウトEPUBを正しく表示し、表紙も出るようにしました\n'
        '・ピンチでページを拡大できるようになりました\n'
        '・大きなファイルやiCloud上のファイルの取り込みで固まる・失敗する問題を直しました\n'
        '・iPhone Duo の画面いっぱいに表示し、開いたときの折り目を本の背にするようにしました\n'
        '・縦書きでも挿絵を1ページずつ表示するようにしました'
    ),
    'en-US': (
        '- New "Slide two at a time" mode: numbered images sit side by side and one swipe changes both\n'
        '- Import a folder of images, or several images at once, as one book\n'
        '- Fixed-layout EPUB comics now display correctly, with their covers\n'
        '- Pinch a page to zoom\n'
        '- Fixed freezes and failures when importing large files or files stored in iCloud\n'
        '- Fills the whole screen on iPhone Duo, and the fold of an open Duo becomes the spine of the book\n'
        '- Illustrations now appear in vertical text, each on its own page'
    ),
}


def token():
    return jwt.encode({'iss': ISSUER, 'iat': int(time.time()), 'exp': int(time.time()) + 1200, 'aud': 'appstoreconnect-v1'},
                      p8, algorithm='ES256', headers={'kid': KEY_ID})


def api(method, path, payload=None):
    h = {'Authorization': f'Bearer {token()}', 'Content-Type': 'application/json'}
    return requests.request(method, f'https://api.appstoreconnect.apple.com/v1{path}', headers=h,
                            **({'json': payload} if payload else {}))


version = re.search(r'MARKETING_VERSION:\s*"?([0-9.]+)"?', open('project.yml').read()).group(1)
r = api('GET', f'/apps/{APP_ID}/appStoreVersions?filter[platform]=IOS&filter[versionString]={version}&limit=1')
data = r.json().get('data', [])
if data:
    vid = data[0]['id']
    print(f'Version {version} exists: {vid} state={data[0]["attributes"]["appStoreState"]}')
else:
    r = api('POST', '/appStoreVersions', {'data': {'type': 'appStoreVersions',
        'attributes': {'platform': 'IOS', 'versionString': version, 'releaseType': 'AFTER_APPROVAL'},
        'relationships': {'app': {'data': {'type': 'apps', 'id': APP_ID}}}}})
    if r.status_code >= 300:
        print('Create version failed', r.status_code, r.text[:400])
        sys.exit(1)
    vid = r.json()['data']['id']
    print(f'Created version {version}: {vid}')

loc_id = None
r = api('GET', f'/appStoreVersions/{vid}/appStoreVersionLocalizations')
for loc in r.json().get('data', []):
    locale = loc['attributes']['locale']
    if locale == 'ja':
        loc_id = loc['id']
    text = WHATS_NEW.get(locale)
    if text:
        r2 = api('PATCH', f'/appStoreVersionLocalizations/{loc["id"]}', {'data': {
            'type': 'appStoreVersionLocalizations', 'id': loc['id'], 'attributes': {'whatsNew': text}}})
        print('whatsNew', locale, r2.status_code, '' if r2.status_code < 300 else r2.text[:200])

env = os.environ.get('GITHUB_ENV')
if env:
    with open(env, 'a') as f:
        f.write(f'VERSION_ID={vid}\n')
        if loc_id:
            f.write(f'LOC_ID={loc_id}\n')
print('VERSION_ID', vid, 'LOC_ID', loc_id)
