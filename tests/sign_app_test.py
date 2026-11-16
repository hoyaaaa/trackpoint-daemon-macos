"""Exercise launch-time signing without real keys, processes or app launches."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
ROOT=Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='trackpointd-sign-app-test.') as directory:
    root=Path(directory);fakebin=root/'bin';fakebin.mkdir()
    app=root/'TrackPointD.app';(app/'Contents/MacOS').mkdir(parents=True)
    info=app/'Contents/Info.plist'
    info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'com.user.trackpointd'}))
    calls=root/'calls'
    stub='''#!/usr/bin/env python3
import os,json,sys
from pathlib import Path
name=Path(sys.argv[0]).name
with open(os.environ['CALLS'],'a') as out:out.write(json.dumps([name,*sys.argv[1:]])+'\\n')
if name=='pgrep':
    if os.environ.get('RUNNING'):print('123')
    sys.exit(0 if os.environ.get('RUNNING') else 1)
if name=='ps':
    print(os.environ['TARGET_EXE'] if os.environ.get('RUNNING')=='1' else '/old-keg/trackpointd')
    sys.exit(0)
if any(x.startswith('-R=') for x in sys.argv):sys.exit(0 if os.environ.get('MATCH') else 1)
if '--sign' in sys.argv:sys.exit(1 if os.environ.get('SIGN_FAIL') else 0)
sys.exit(1 if os.environ.get('VERIFY_FAIL') else 0)
'''
    for name in ('codesign','pgrep','ps'):
        path=fakebin/name;path.write_text(stub);path.chmod(0o700)
    script=root/'sign-app.sh'
    script.write_text((ROOT/'scripts/sign-app.sh').read_text().replace('/bin/ps',str(fakebin/'ps')).replace('source \"$(cd \"$(dirname \"$0\")\" && pwd)/signing-identity.sh\"','source \"'+str(ROOT/'scripts/signing-identity.sh')+'\"'))
    env=dict(os.environ,PATH=str(fakebin)+os.pathsep+os.environ['PATH'],CALLS=str(calls),TRACKPOINTD_SIGN_IDENTITY='AB'*20,TARGET_EXE=str((app/'Contents/MacOS/trackpointd').resolve()))
    for flags,expected in [({'MATCH':'1','RUNNING':'1'},0),({'RUNNING':'1'},1),({'RUNNING':'other'},0),({},0),({'SIGN_FAIL':'1'},1),({'VERIFY_FAIL':'1'},1)]:
        calls.write_text('')
        result=subprocess.run(['bash',str(script),str(app)],env=dict(env,**flags),capture_output=True,text=True)
        assert result.returncode==expected,(flags,result.stderr)
        rows=[json.loads(x) for x in calls.read_text().splitlines()]
        signed=any('--sign' in row for row in rows)
        assert signed==(not flags.get('MATCH') and flags.get('RUNNING')!='1')
        if flags.get('MATCH'):
            assert len(rows)==1 and 'certificate leaf' in rows[0][-2]
    info.write_bytes(plistlib.dumps({'CFBundleIdentifier':'unrelated.app'}))
    calls.write_text('')
    result=subprocess.run(['bash',str(script),str(app)],env=env,capture_output=True)
    assert result.returncode==2 and not calls.read_text()
print('Launch-time signing: identity match, running-process guard, sign/verify failures and bundle validation: ok')
