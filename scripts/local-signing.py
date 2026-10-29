#!/usr/bin/env python3
"""Persistent local signing, with no change to system certificate trust.

The private identity is isolated from login.keychain and never packaged. A
missing identity after the first signed build is an error, not a new identity.
Initial user-domain trust is constrained to codeSign policy + /usr/bin/codesign.
Only /usr/bin/codesign may use the private signing key.
"""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
SIGNING = ROOT / '.typebridge-signing'
KEYCHAIN = SIGNING / 'identity.keychain-db'
PASSWORD = SIGNING / 'keychain-password'
CERTIFICATE = SIGNING / 'certificate.pem'
PIN = SIGNING / 'certificate.sha1'
NAME = 'TypeBridge Local Development'


def run(args, *, hidden=()):
    result = subprocess.run([str(a) for a in args], capture_output=True, text=True)
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        for value in hidden:
            detail = detail.replace(value, '[redacted]')
        raise RuntimeError(f'{Path(str(args[0])).name} failed: {detail[:1200]}')
    return result.stdout.strip()


def requirement(path):
    r = subprocess.run(['/usr/bin/codesign', '-dr', '-', str(path)], capture_output=True, text=True)
    for line in (r.stdout + r.stderr).splitlines():
        if 'designated =>' in line:
            return line[line.index('designated =>') + len('designated =>'):].strip()
    return ''


def fingerprint():
    der = subprocess.run(['openssl', 'x509', '-in', str(CERTIFICATE), '-outform', 'DER'], capture_output=True, check=True).stdout
    return hashlib.sha1(der).hexdigest().upper()


def ensure():
    files = [KEYCHAIN, PASSWORD, CERTIFICATE, PIN]
    if all(p.is_file() for p in files):
        pin = PIN.read_text().strip()
        if fingerprint() != pin:
            raise RuntimeError('Local signing certificate does not match its saved fingerprint.')
        return pin
    if any(p.exists() for p in files):
        raise RuntimeError('Local signing identity is incomplete. Restore it; do not regenerate it during an update.')
    application = ROOT / 'dist/Poieva Translate.app'
    if not application.exists():
        application = ROOT / 'dist/TypeBridge.app'
    previous = requirement(application)
    if previous and 'certificate' in previous:
        raise RuntimeError('The app already has a certificate identity. Restore its signing files before building.')
    SIGNING.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(SIGNING, 0o700)
    password = secrets.token_hex(32)
    PASSWORD.write_text(password)
    os.chmod(PASSWORD, 0o600)
    try:
        with tempfile.TemporaryDirectory(prefix='setup-', dir=SIGNING) as temporary:
            temporary = Path(temporary)
            config = temporary / 'certificate.cnf'
            config.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=codesign\n'
                '[dn]\nCN=TypeBridge Local Development\nO=TypeBridge\n'
                '[codesign]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n'
                'extendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n')
            key = temporary / 'private.pem'
            p12 = temporary / 'identity.p12'
            run(['openssl', 'req', '-x509', '-newkey', 'rsa:3072', '-nodes', '-days', '3650',
                 '-config', config, '-keyout', key, '-out', CERTIFICATE])
            os.chmod(key, 0o600)
            run(['openssl', 'pkcs12', '-export', '-legacy', '-inkey', key, '-in', CERTIFICATE,
                 '-name', NAME, '-out', p12, '-passout', f'file:{PASSWORD}'])
            # security create-keychain adds a search-list entry. Remove just our
            # dedicated entry afterwards, preserving all other user entries.
            try:
                run(['/usr/bin/security', 'create-keychain', '-p', password, KEYCHAIN], hidden=[password])
            finally:
                current = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
                remaining = [p for p in current if Path(p).resolve() != KEYCHAIN.resolve()]
                if current != remaining:
                    run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *remaining])
            run(['/usr/bin/security', 'import', p12, '-k', KEYCHAIN, '-x', '-P', password, '-T', '/usr/bin/codesign'], hidden=[password])
            run(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:', '-s', '-k', password, KEYCHAIN], hidden=[password])
            run(['/usr/bin/security', 'add-trusted-cert', '-r', 'trustRoot', '-p', 'codeSign', '-a', '/usr/bin/codesign',
                 '-k', KEYCHAIN, CERTIFICATE])
            os.chmod(KEYCHAIN, 0o600)
            pin = fingerprint()
            PIN.write_text(pin + '\n')
            return pin
    except Exception:
        # Keep incomplete material for diagnosis. Never silently rotate it.
        raise


def sign(path, identifier, previous=None):
    pin = ensure()
    password = PASSWORD.read_text().strip()
    run(['/usr/bin/security', 'unlock-keychain', '-p', password, KEYCHAIN], hidden=[password])
    expected = f'identifier "{identifier}" and certificate leaf = H"{pin}"'
    old = requirement(previous) if previous and Path(previous).exists() else ''
    if old and 'certificate' in old:
        # Check the existing build belongs to this same certificate before
        # publishing. A missing/swapped identity must not reset permissions.
        run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + expected, previous])
    # codesign searches this list for the certificate chain even when an
    # explicit --keychain is supplied for the private identity.
    current = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
    added = str(KEYCHAIN) not in current
    if added:
        run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *current, KEYCHAIN])
    try:
        run(['/usr/bin/codesign', '--force', '--sign', pin, '--keychain', KEYCHAIN,
             '--timestamp=none', '--identifier', identifier, '-r', '=designated => ' + expected, path])
    finally:
        if added:
            latest = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
            run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s',
                 *[p for p in latest if Path(p).resolve() != KEYCHAIN.resolve()]])
    run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + expected, path])
    if old and 'certificate' in old:
        run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + old, path])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['ensure', 'sign', 'requirement'])
    parser.add_argument('path', nargs='?')
    parser.add_argument('--identifier', default='studio.typebridge.mac')
    parser.add_argument('--previous')
    args = parser.parse_args()
    os.umask(0o077)
    SIGNING.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (SIGNING / 'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if args.action == 'sign':
            if not args.path:
                parser.error('sign requires a path')
            sign(args.path, args.identifier, args.previous)
        elif args.action == 'ensure':
            print('Local signing certificate: ' + ensure())
        else:
            print(requirement(args.path))


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, subprocess.SubprocessError) as error:
        # Never print subprocess arguments: they may contain a setup password.
        print(str(error) if isinstance(error, RuntimeError) else 'Signing setup failed.', file=sys.stderr)
        sys.exit(1)
