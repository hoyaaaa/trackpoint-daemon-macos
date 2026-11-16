"""Exercise the real identity selector without accessing any signing keys."""
from pathlib import Path
import os
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='trackpointd-signing-test.') as directory:
    script=Path(directory)/'signing-identity.sh'
    script.write_text((ROOT/'scripts/signing-identity.sh').read_text())
    (Path(directory)/'setup-signing.sh').write_text('echo AUTO-CERTIFICATE\n')
    config=Path(directory)/'signing-identity'
    env=dict(os.environ,TRACKPOINTD_SIGNING_CONFIG=str(config))
    env.pop('TRACKPOINTD_SIGN_IDENTITY',None)
    def select(extra=None):
        return subprocess.run(['/bin/bash','-c','source "$1"; trackpointd_signing_identity','test',str(script)],
                              env=dict(env,**(extra or {})),capture_output=True,text=True)
    assert select().stdout.strip()=='AUTO-CERTIFICATE' # Only absence triggers setup.
    for invalid in ('','not-a-fingerprint','a'*39,'b'*41,'a'*40+'\n'+'b'*40):
        config.write_text(invalid)
        assert select().returncode==2 # Configured errors must never become ad-hoc.
    identity='AB'*20
    config.write_text(identity+'\n')
    assert select().returncode==0 and select().stdout.strip()==identity
    assert select({'TRACKPOINTD_SIGN_IDENTITY':'-'}).stdout.strip()=='-'
    assert select({'TRACKPOINTD_SIGN_IDENTITY':'Chosen certificate'}).stdout.strip()=='Chosen certificate'
    assert select({'TRACKPOINTD_SIGN_IDENTITY':''}).returncode==2
    config.unlink();config.symlink_to(Path(directory)/'missing')
    assert select().returncode==2
print('Persistent signing identity selection tests: ok (no keychain operations)')
