#!/usr/bin/env python3
import base64
import json
import os
import sys
import time
from pathlib import Path
from urllib.parse import quote

import jwt
import requests

BASE_URL = "https://api.appstoreconnect.apple.com/v1"
KEY_ID = os.environ["APP_STORE_CONNECT_API_KEY_ID"]
ISSUER_ID = os.environ["APP_STORE_CONNECT_API_KEY_ISSUER_ID"]
KEY_PATH = Path(os.environ["ASC_KEY_PATH"])
BUNDLE_IDENTIFIER = os.environ.get("BUNDLE_IDENTIFIER", "jp.lumi.camera.ios")
PROFILE_NAME = os.environ.get("PROFILE_NAME", "LUMI Camera App Store Profile")
CSR_PATH = Path(os.environ["CSR_PATH"])
CERT_PATH = Path(os.environ["CERT_PATH"])
PROFILE_PATH = Path(os.environ["PROFILE_PATH"])
GITHUB_ENV = Path(os.environ["GITHUB_ENV"])


def token() -> str:
    now = int(time.time())
    payload = {
        "iss": ISSUER_ID,
        "iat": now,
        "exp": now + 20 * 60,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(
        payload,
        KEY_PATH.read_text(encoding="utf-8"),
        algorithm="ES256",
        headers={"kid": KEY_ID},
    )


def api(method: str, path: str, body: dict | None = None) -> requests.Response:
    return requests.request(
        method,
        f"{BASE_URL}{path}",
        headers={
            "Authorization": f"Bearer {token()}",
            "Content-Type": "application/json",
        },
        json=body,
        timeout=45,
    )


def fail(response: requests.Response) -> None:
    print(f"Apple API error: HTTP {response.status_code}")
    try:
        payload = response.json()
    except Exception:
        print(response.text[:2000])
        sys.exit(1)
    print(json.dumps(payload, indent=2))
    sys.exit(1)


def get_bundle_id() -> str:
    encoded = quote(BUNDLE_IDENTIFIER, safe="")
    response = api("GET", f"/bundleIds?filter[identifier]={encoded}&limit=1")
    if response.status_code != 200:
        fail(response)
    data = response.json().get("data", [])
    if not data:
        print(f"Bundle ID not found: {BUNDLE_IDENTIFIER}")
        sys.exit(1)
    return data[0]["id"]


def create_certificate() -> str:
    existing = os.environ.get("EXISTING_CERTIFICATE_ID")
    if existing:
        response = api("GET", f"/certificates/{existing}")
        if response.status_code != 200: fail(response)
        cert = response.json()["data"]
        assert cert["attributes"]["certificateType"] in ("IOS_DISTRIBUTION", "DISTRIBUTION")
        return cert["id"]
    csr_content = CSR_PATH.read_text(encoding="utf-8")
    body = {
        "data": {
            "type": "certificates",
            "attributes": {
                "certificateType": "IOS_DISTRIBUTION",
                "csrContent": csr_content,
            },
        }
    }
    response = api("POST", "/certificates", body)
    if response.status_code not in (200, 201):
        fail(response)
    cert = response.json()["data"]
    cert_bytes = base64.b64decode(cert["attributes"]["certificateContent"])
    CERT_PATH.write_bytes(cert_bytes)
    return cert["id"]


def create_profile(bundle_id: str, certificate_id: str) -> str:
    body = {
        "data": {
            "type": "profiles",
            "attributes": {
                "name": PROFILE_NAME,
                "profileType": "IOS_APP_STORE",
            },
            "relationships": {
                "bundleId": {
                    "data": {"type": "bundleIds", "id": bundle_id}
                },
                "certificates": {
                    "data": [{"type": "certificates", "id": certificate_id}]
                },
            },
        }
    }
    response = api("POST", "/profiles", body)
    if response.status_code not in (200, 201):
        fail(response)
    profile = response.json()["data"]
    profile_bytes = base64.b64decode(profile["attributes"]["profileContent"])
    PROFILE_PATH.write_bytes(profile_bytes)
    return profile["attributes"]["name"]


def append_env(name: str, value: str) -> None:
    with GITHUB_ENV.open("a", encoding="utf-8") as env:
        env.write(f"{name}={value}\n")


def main() -> None:
    bundle_id = get_bundle_id()
    certificate_id = create_certificate()
    profile_name = create_profile(bundle_id, certificate_id)
    append_env("PROFILE_NAME", profile_name)
    print(f"Created certificate {certificate_id}")
    print(f"Created profile {profile_name}")


if __name__ == "__main__":
    main()
