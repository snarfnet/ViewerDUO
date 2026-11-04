#!/usr/bin/env python3
"""Revoke the development certificates that CI runs created through the API.

Every archive with -allowProvisioningUpdates on a fresh runner makes a new "Created via API"
development certificate, and the account stops at its limit. Certificates made on a Mac
(named after the person or machine) and all distribution certificates are left alone.
"""
import jwt, time, requests, os, sys

KEY_ID = 'WDXGY9WX55'
ISSUER = '2be0734f-943a-4d61-9dc9-5d9045c46fec'
p8 = open(os.path.expanduser('~/.appstoreconnect/private_keys/AuthKey_WDXGY9WX55.p8')).read()
DEV_TYPES = {'DEVELOPMENT', 'IOS_DEVELOPMENT'}


def token():
    now = int(time.time())
    return jwt.encode({'iss': ISSUER, 'iat': now, 'exp': now + 1200, 'aud': 'appstoreconnect-v1'},
                      p8, algorithm='ES256', headers={'kid': KEY_ID})


def api(method, path):
    return requests.request(method, f'https://api.appstoreconnect.apple.com/v1{path}',
                            headers={'Authorization': f'Bearer {token()}'})


r = api('GET', '/certificates?limit=200')
if r.status_code >= 300:
    print(f'Could not list certificates: {r.status_code} {r.text[:300]}')
    sys.exit(0)  # let the archive step report the real signing error

certs = r.json().get('data', [])
print(f'{len(certs)} certificates on the account')
for c in certs:
    a = c['attributes']
    name = a.get('name') or a.get('displayName') or ''
    kind = a.get('certificateType', '')
    if kind in DEV_TYPES and 'Created via API' in name:
        d = api('DELETE', f"/certificates/{c['id']}")
        print(f"revoke {kind} '{name}' expires={a.get('expirationDate')} -> {d.status_code}")
    else:
        print(f"keep   {kind} '{name}'")
