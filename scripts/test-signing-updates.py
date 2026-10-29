#!/usr/bin/env python3
"""Real Keychain regression using only synthetic keys in a disposable keychain."""
import importlib.util
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('local_signing', ROOT / 'scripts/local-signing.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
run = signing.run

SOURCE = r'''
import Foundation
import Security
let version = "VERSION"
let arguments = CommandLine.arguments
if arguments.count == 2 && arguments[1] == "version" { print(version); exit(0) }
guard arguments.count == 3 else { exit(2) }
func check() -> String {
// Restore process settings on every path, including the negative control.
var previous: DarwinBoolean = false
guard SecKeychainGetUserInteractionAllowed(&previous) == errSecSuccess,
      SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else { return "error:interaction" }
defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
var keychain: SecKeychain?
if arguments[2] != "login" {
    guard SecKeychainOpen(arguments[2], &keychain) == errSecSuccess, keychain != nil else { return "error:keychain" }
}
var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "studio.typebridge.signing-regression",
    kSecAttrAccount as String: arguments[2] == "login" ? "FIXTURE_ACCOUNT" : "synthetic-fixture",
    kSecAttrSynchronizable as String: false]
if let keychain { query[kSecUseKeychain as String] = keychain }
let fixture = Data("synthetic-regression-value".utf8)
if arguments[1] == "delete" {
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound ? "deleted" : "error:\(status)"
} else if arguments[1] == "save" {
    query[kSecValueData as String] = fixture
    query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(query as CFDictionary, nil)
    guard status == errSecSuccess else { return "error:\(status)" }
    return "saved"
} else {
    if let keychain { query[kSecMatchSearchList as String] = [keychain] }
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var raw: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &raw)
    if status == errSecSuccess && raw as? Data == fixture { return "read-ok" }
    else { return "denied:\(status)" }
}
}
print(check())
'''


def main():
    os.umask(0o077)
    cache = ROOT / '.build/module-cache'
    cache.mkdir(exist_ok=True, parents=True)
    os.environ['CLANG_MODULE_CACHE_PATH'] = str(cache)
    with tempfile.TemporaryDirectory(prefix='signing-regression-', dir=ROOT / '.build') as temporary:
        temporary = Path(temporary)
        keychain = temporary / 'fixture.keychain-db'
        password = secrets.token_hex(24)
        account = 'synthetic-' + secrets.token_hex(16)
        first = None
        try:
            run(['/usr/bin/security', 'create-keychain', '-p', password, keychain], hidden=[password])
            current = shlex.split(run(['/usr/bin/security', 'list-keychains', '-d', 'user']))
            run(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *[p for p in current if Path(p).resolve() != keychain.resolve()]])
            binaries = []
            for version in ['one', 'two', 'unrelated']:
                source = temporary / f'{version}.swift'
                source.write_text(SOURCE.replace('VERSION', version).replace('FIXTURE_ACCOUNT', account))
                bundle = temporary / f'{version}.app'
                executable = bundle / 'Contents/MacOS'
                executable.mkdir(parents=True)
                import plistlib
                (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleIdentifier': 'studio.typebridge.signing-regression',
                    'CFBundleExecutable': 'Fixture', 'CFBundlePackageType': 'APPL',
                    'CFBundleVersion': version, 'CFBundleName': 'Signing Fixture'}))
                binary = executable / 'Fixture'
                run(['/usr/bin/swiftc', source, '-o', binary, '-module-cache-path', cache])
                if version == 'unrelated':
                    run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'studio.typebridge.signing-regression', bundle])
                else:
                    run(['python3', ROOT / 'scripts/local-signing.py', 'sign', bundle,
                         '--identifier', 'studio.typebridge.signing-regression'])
                binaries.append(binary)
            first, second, unrelated = binaries
            first_requirement, second_requirement = signing.requirement(first), signing.requirement(second)
            assert first_requirement == second_requirement and 'certificate leaf' in first_requirement
            assert first.read_bytes() != second.read_bytes(), 'The update must really change the signed binary.'
            hashes = []
            for binary in [first, second]:
                detail = subprocess.run(['/usr/bin/codesign', '-dvvv', binary], capture_output=True, text=True, check=True).stderr
                hashes.append(next(line for line in detail.splitlines() if line.startswith('CDHash=')))
            assert hashes[0] != hashes[1], 'Changed code must have different CodeDirectory hashes.'
            assert run([first, 'save', keychain]) == 'saved'
            initial = run([first, 'read', keychain])
            assert initial == 'read-ok', 'Original process read failed: ' + initial
            updated = run([second, 'read', keychain])
            assert updated == 'read-ok', 'Update lost access to the saved key: ' + updated
            assert run([second, 'read', keychain]) == 'read-ok', 'A new process must keep access.'
            denied = run([unrelated, 'read', keychain])
            assert denied in ['denied:-25308', 'denied:-25293'], 'Unrelated signer must not gain access: ' + denied
            print('PASS: changed binary + stable certificate can read the original saved key in new processes without UI.')
            print('PASS: an unrelated signer with the same identifier is denied.')
            # The default login keychain enforces partition ACLs differently
            # from a disposable keychain; exercise the production lookup too.
            assert run([first, 'save', 'login']) == 'saved'
            assert run([first, 'read', 'login']) == 'read-ok'
            updated_login = run([second, 'read', 'login'])
            assert updated_login in ['denied:-25308', 'denied:-25293'], 'Expected local-signature partition regression changed: ' + updated_login
            denied_login = run([unrelated, 'read', 'login'])
            assert denied_login in ['denied:-25308', 'denied:-25293'], 'Unrelated login reader gained access: ' + denied_login
            print('PASS: reproduced the default login-keychain partition restriction; a stable certificate alone is insufficient.')
            print('Use test-credential-service.py to verify the fixed-reader solution.')
        finally:
            if first is not None and first.exists():
                result = run([first, 'delete', 'login'])
                if result != 'deleted':
                    raise RuntimeError('Synthetic login-keychain fixture cleanup failed: ' + result)
            if keychain.exists():
                run(['/usr/bin/security', 'delete-keychain', keychain])


if __name__ == '__main__':
    main()
