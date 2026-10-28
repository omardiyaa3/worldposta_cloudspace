# tool/asc.py — tiny App Store Connect API client (ES256 JWT with the team's
# API key in ~/.appstoreconnect/private_keys). Needs: pip install pyjwt cryptography requests
#   from asc import call; status, json = call('GET', '/v1/apps')
import os, time
import jwt, requests

KID = os.environ.get('ASC_KEY_ID', 'QNXU3YX684')
ISS = os.environ.get('ASC_ISSUER_ID', '15936440-2172-498a-b49a-d56a49b6aadc')


def _token():
    key = open(os.path.expanduser(f'~/.appstoreconnect/private_keys/AuthKey_{KID}.p8')).read()
    now = int(time.time())
    return jwt.encode({'iss': ISS, 'iat': now, 'exp': now + 1100, 'aud': 'appstoreconnect-v1'},
                      key, algorithm='ES256', headers={'kid': KID})


def call(method, path, body=None):
    url = path if path.startswith('http') else 'https://api.appstoreconnect.apple.com' + path
    r = requests.request(method, url, json=body,
                         headers={'Authorization': 'Bearer ' + _token(), 'Content-Type': 'application/json'})
    try:
        return r.status_code, r.json()
    except ValueError:
        return r.status_code, r.text
