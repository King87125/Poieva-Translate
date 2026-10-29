#!/usr/bin/env python3
"""Signed XPC integration, default login keychain, synthetic data only.

No credentials are printed. All created keychain items have random accounts and
are deleted by the signed fixture client. The installed app is not launched.
"""
import importlib.util
import os
from pathlib import Path
import plistlib
import secrets
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
import TypeBridgeCredentialSupport
let version = "VERSION"
guard CommandLine.arguments.count == 3 else { exit(2) }
if CommandLine.arguments[1] == "version" { print(version); exit(0) }
let connection = NSXPCConnection(serviceName: CredentialServiceIdentity.service)
connection.remoteObjectInterface = NSXPCInterface(with: CredentialServiceProtocol.self)
do { connection.setCodeSigningRequirement(try CredentialServiceIdentity.requirement(for: CredentialServiceIdentity.service)) }
catch { print("denied"); exit(0) }
let ready = DispatchSemaphore(value: 0)
let lock = NSLock()
var result: String?
func finish(_ text: String) { lock.lock(); defer { lock.unlock() }; if result == nil { result = text; ready.signal() } }
connection.invalidationHandler = { finish("denied") }
connection.interruptionHandler = { finish("denied") }
connection.resume()
let fixture = Data("synthetic-credential-service-value".utf8)
if let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
    let value = error as NSError
    finish("denied:\(value.domain):\(value.code)")
}) as? CredentialServiceProtocol {
    if CommandLine.arguments[1] == "save" {
        proxy.write(CommandLine.arguments[2], value: fixture) { finish($0 == errSecSuccess ? "saved" : "error:\($0)") }
    } else if CommandLine.arguments[1] == "delete" {
        proxy.write(CommandLine.arguments[2], value: nil) { finish($0 == errSecSuccess ? "deleted" : "error:\($0)") }
    } else {
        proxy.read(CommandLine.arguments[2], interactive: false) { value, status in
            finish(status == errSecSuccess && value == fixture ? "read-ok" : "denied")
        }
    }
}
if ready.wait(timeout: .now() + .seconds(12)) != .success { finish("timeout") }
connection.invalidate()
print(result ?? "timeout")
'''


def cdhash(path):
    detail = subprocess.run(['/usr/bin/codesign', '-dvvv', path], capture_output=True, text=True, check=True).stderr
    return next(line for line in detail.splitlines() if line.startswith('CDHash='))


def main():
    os.umask(0o077)
    account = str(__import__('uuid').uuid4()).upper()
    app = ROOT / 'dist/Poieva Translate.app'
    if not app.exists():
        app = ROOT / 'dist/TypeBridge.app'
    helper = app / 'Contents/XPCServices/TypeBridgeCredentials.xpc'
    assert helper.is_dir(), 'Build the app with its XPC service first.'
    cache = ROOT / '.build/module-cache'
    os.environ['CLANG_MODULE_CACHE_PATH'] = str(cache)
    objects = list((ROOT / '.build/release/TypeBridgeCredentialSupport.build').glob('*.swift.o'))
    assert objects
    with tempfile.TemporaryDirectory(prefix='credential-xpc-', dir=ROOT / '.build') as temporary:
        temporary = Path(temporary)
        binaries = []
        saved_fixture = False
        try:
            for version in ['one', 'two', 'unrelated', 'wrong-id', 'wrong-helper']:
                bundle = temporary / (version + '.app')
                executable = bundle / 'Contents/MacOS/Fixture'
                executable.parent.mkdir(parents=True)
                identifier = 'studio.typebridge.mac' if version != 'wrong-id' else 'studio.typebridge.other'
                (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({
                    'CFBundleIdentifier': identifier, 'CFBundleExecutable': 'Fixture',
                    'CFBundleName': 'Credential Test', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': version}))
                source = temporary / (version + '.swift')
                source.write_text(SOURCE.replace('VERSION', version))
                run(['/usr/bin/swiftc', source, '-I', ROOT / '.build/release/Modules',
                     *objects, '-o', executable, '-module-cache-path', cache])
                service = bundle / 'Contents/XPCServices/TypeBridgeCredentials.xpc'
                service.parent.mkdir(parents=True)
                run(['/bin/cp', '-R', helper, service])
                if version == 'wrong-helper':
                    run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', 'studio.typebridge.mac.credentials', service])
                if version == 'unrelated':
                    run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', identifier, bundle])
                else:
                    signing.sign(bundle, identifier)
                binaries.append(executable)
            first, second, unrelated, wrong_id, wrong_helper = binaries
            assert cdhash(first) != cdhash(second)
            assert cdhash(first.parents[1] / 'XPCServices/TypeBridgeCredentials.xpc') == cdhash(second.parents[1] / 'XPCServices/TypeBridgeCredentials.xpc')
            saved = run([first, 'save', account])
            assert saved == 'saved', 'Initial save failed: ' + saved
            saved_fixture = True
            assert run([first, 'read', account]) == 'read-ok'
            assert run([second, 'read', account]) == 'read-ok'
            assert run([second, 'read', account]) == 'read-ok'
            print('PASS: changed host code and restarted processes read a synthetic login-keychain item through the fixed service.')
            for invalid in [unrelated, wrong_id, wrong_helper]:
                assert run([invalid, 'read', account]).startswith('denied'), 'Unexpected access: ' + invalid.parent.parent.parent.name
            print('PASS: unrelated host signature, wrong host identifier and unrelated helper signature are rejected.')
            assert run([second, 'read', 'not-a-uuid']) == 'denied'
            print('PASS: invalid account input is rejected.')
        finally:
            if saved_fixture:
                assert run([binaries[0], 'delete', account]) == 'deleted', 'Synthetic key cleanup failed.'
                print('PASS: synthetic key was deleted; no real account key was read.')


if __name__ == '__main__':
    main()
