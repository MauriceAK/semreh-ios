#!/usr/bin/env python3
"""Local cookie persistence/restart/refresh evidence; private cookies never logged."""
import argparse
import asyncio
import json
from pathlib import Path
import time
import httpx
from direct_hermes_probe import RUNTIME, PIN, validate
from direct_hermes_capture import HEADERS, BASE, write_fixture

COOKIE_FILE = RUNTIME / 'restart-cookies.json'
OUTPUT = Path(__file__).resolve().parents[1] / 'docs/migration/fixtures/slice1-local-restart.json'


async def main(action):
    validate()
    credentials = json.loads((RUNTIME / 'credentials.json').read_text())
    async with httpx.AsyncClient(base_url=BASE, headers=HEADERS, trust_env=False) as client:
        if action == 'prepare':
            assert not COOKIE_FILE.exists(), 'Do not overwrite an existing restart proof'
            response = await client.post('/auth/password-login', json={'provider': 'basic', **credentials, 'next': ''})
            assert response.status_code == 200
            with COOKIE_FILE.open('x') as stream:
                COOKIE_FILE.chmod(0o600)
                json.dump([{'name': c.name, 'value': c.value, 'domain': c.domain, 'path': c.path} for c in client.cookies.jar], stream)
            print('Stored private cookie jar for backend restart check; no cookie values printed.')
            return
        for cookie in json.loads(COOKIE_FILE.read_text()):
            client.cookies.set(**cookie)
        response = await client.get('/api/sessions')
        assert response.status_code == 200, 'Cookies did not survive backend restart/client recreation'
        # Backend must have been restarted with the documented basic-provider
        # session_ttl_seconds=60 setting (provider minimum) for real expiry.
        config = json.loads((RUNTIME / 'home/config.yaml').read_text())
        assert config['dashboard']['basic_auth']['session_ttl_seconds'] == 60
        response = await client.post('/auth/password-login', json={'provider': 'basic', **credentials, 'next': ''})
        assert response.status_code == 200
        assert any('Max-Age=60;' in c for c in response.headers.get_list('set-cookie'))
        before = {c.name: c.value for c in client.cookies.jar}
        print('Waiting for actual 60-second provider token expiry.', flush=True)
        await asyncio.sleep(30)
        await asyncio.sleep(32)
        response = await client.get('/api/sessions')
        assert response.status_code == 200, 'Refresh failed'
        after = {c.name: c.value for c in client.cookies.jar}
        assert after['hermes_session_at'] != before['hermes_session_at'], 'Access cookie did not rotate'
        assert after['hermes_session_rt'] != before['hermes_session_rt'], 'Refresh cookie did not rotate'
        evidence = {'configured_source_pin': PIN, 'deployment': 'local HTTP only; not iOS or real HTTPS',
                    'client_recreation_cookie_restore': True,
                    'backend_restart_proof': 'Requires separate operator process evidence; not asserted by this script',
                    'short_access_ttl_seconds': 60, 'expired_access_refresh_status': response.status_code,
                    'access_cookie_rotated': True, 'refresh_cookie_rotated': True,
                    'captured_at_unix': int(time.time())}
        write_fixture(OUTPUT, evidence)
        await client.post('/auth/logout')
        # This exact private jar is disposable test material, never a personal jar.
        if COOKIE_FILE.is_symlink():
            raise RuntimeError('Refusing unexpected cookie-jar symlink')
        COOKIE_FILE.unlink()
        print('Local client recreation and expired-cookie rotation passed; temporary cookie jar removed.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'verify'])
    asyncio.run(main(parser.parse_args().action))
