"""Run the production setup with real certificate generation, isolated OS stubs."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STUB = '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args=sys.argv[1:]
root=Path(os.environ['CASE_ROOT'])
with (root/'calls').open('a') as log: log.write(' '.join(args)+'\\n')
if Path(sys.argv[0]).name=='security':
    if args[0]=='login-keychain':
        assert args==['login-keychain']
        print('"'+str(root/'login.keychain-db')+'"')
    elif args[0]=='find-certificate':
        if os.environ.get('READ_ERROR'): sys.exit(36)
        cert=root/'existing.pem'
        if not cert.exists(): sys.exit(44)
        print(cert.read_text())
    elif args[0]=='import':
        if os.environ.get('IMPORT_ERROR'): sys.exit(1)
        import subprocess
        cert=subprocess.check_output(['openssl','pkcs12','-in',args[1],'-passin','pass:','-nokeys'])
        (root/'existing.pem').write_bytes(cert)
    else: raise AssertionError(args)
else:
    if os.environ.get('SIGN_ERROR'): sys.exit(1)
'''
with tempfile.TemporaryDirectory(prefix='trackpointd-setup-test.') as directory:
    root=Path(directory)
    fakebin=root/'bin';fakebin.mkdir()
    for name in ('security','codesign'):
        path=fakebin/name;path.write_text(STUB);path.chmod(0o755)
    env=dict(os.environ,CASE_ROOT=str(root),TMPDIR=str(root),PATH=str(fakebin)+os.pathsep+os.environ['PATH'])
    def run(**extra):
        result=subprocess.run(['bash',str(ROOT/'scripts/setup-signing.sh')],env=dict(env,**extra),capture_output=True,text=True,timeout=30)
        assert not list(root.glob('trackpointd-signing.*'))
        assert not (root/'login.keychain-db.trackpointd-lock').exists()
        return result
    assert run(READ_ERROR='1').returncode!=0
    assert not (root/'existing.pem').exists()
    assert run(IMPORT_ERROR='1').returncode!=0
    assert not (root/'existing.pem').exists()
    lock=root/'login.keychain-db.trackpointd-lock'
    lock.mkdir()
    concurrent=subprocess.run(['bash',str(ROOT/'scripts/setup-signing.sh')],env=env,capture_output=True,text=True,timeout=30)
    assert concurrent.returncode!=0 and lock.is_dir()
    assert not (root/'existing.pem').exists()
    lock.rmdir()
    first=run(); assert first.returncode==0,first.stderr
    identity=first.stdout.strip();assert len(identity)==40
    cert=(root/'existing.pem').read_bytes()
    details=subprocess.check_output(['openssl','x509','-in',str(root/'existing.pem'),'-text','-noout'],text=True)
    assert 'Code Signing' in details and 'Digital Signature' in details and 'CA:FALSE' in details
    assert 'TLS Web' not in details
    calls=(root/'calls').read_text();assert '-T /usr/bin/codesign' in calls
    (root/'calls').write_text('')
    second=run();assert second.returncode==0 and second.stdout.strip()==identity
    assert 'import' not in (root/'calls').read_text()
    assert run(SIGN_ERROR='1').returncode!=0
    assert (root/'existing.pem').read_bytes()==cert # Never replace an unusable identity.
    assert 'import' not in (root/'calls').read_text()
print('Automatic signing setup: creation, reuse, scoped key access, failures and cleanup: ok')
