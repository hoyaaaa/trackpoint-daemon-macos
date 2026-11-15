"""Run the updater's real script with private fake brew/app/signature tools."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
for failure in ('', 'update', 'promotion', 'upgrade', 'signature', 'version', 'self-test'):
    with tempfile.TemporaryDirectory(prefix='trackpointd-upgrade-test.') as directory:
        root = Path(directory)
        prefix = root / 'brew prefix'
        (prefix / 'bin').mkdir(parents=True)
        app = prefix / 'opt/trackpointd/TrackPointD.app/Contents/MacOS'
        app.mkdir(parents=True)
        log = root / 'calls.jsonl'
        common = f'#!{sys.executable}\nimport os,sys,json\nfrom pathlib import Path\nfailure=os.environ.get("FAIL_STEP", "")\nwith open(os.environ["TEST_LOG"],"a") as f: f.write(json.dumps([Path(sys.argv[0]).name, *sys.argv[1:]])+"\\n")\n'
        brew = prefix / 'bin/brew'
        brew.write_text(common + '''command=sys.argv[1]
if command == 'info':
    print(json.dumps({'formulae':[{'versions':{'stable':'2.0.0' if failure=='promotion' else '9.0.0'}}]}))
sys.exit(1 if failure==command else 0)
''')
        signature = root / 'codesign'
        signature.write_text(common + "sys.exit(1 if failure=='signature' else 0)\n")
        executable = app / 'trackpointd'
        executable.write_text(common + '''if sys.argv[1]=='--version': print('8.0.0' if failure=='version' else '9.0.0')
sys.exit(1 if failure=='self-test' and sys.argv[1]=='--self-test' else 0)
''')
        for tool in (brew, signature, executable):
            tool.chmod(0o700)
        # Redirect only a private copy; never execute real brew, open or codesign.
        text = (ROOT / 'scripts/upgrade.sh').read_text()
        text = text.replace('/opt/homebrew', str(prefix)).replace('/usr/bin/codesign', str(signature))
        script = root / 'upgrade.sh'
        script.write_text(text)
        env = dict(os.environ, FAIL_STEP=failure, TEST_LOG=str(log))
        result = subprocess.run(['/bin/bash', str(script), 'upgrade', str(brew), str(prefix), '9.0.0'],
                                env=env, capture_output=True, text=True, errors="replace")
        assert (result.returncode == 0) == (not failure), (failure, result.stdout, result.stderr)
        calls = [json.loads(line) for line in log.read_text().splitlines()]
        assert calls[0] == ['brew', 'update']
        if failure not in ('update', 'promotion'):
            assert ['brew', 'upgrade', 'hoyaaaa/trackpointd/trackpointd'] in calls
        else:
            assert not any(row[:2] == ['brew', 'upgrade'] for row in calls)
        before = log.read_bytes()
        for version in ('9.0.0;touch /tmp/forbidden', 'v9.0.0', '9.0.0\n', '09.0.0'):
            result = subprocess.run(['/bin/bash', str(script), 'upgrade', str(brew), str(prefix), version],
                                    env=env, capture_output=True, text=True, errors="replace")
            assert result.returncode == 2 and log.read_bytes() == before
print('Homebrew updater success/failure/validation tests: ok (isolated commands)')

# Reopening waits for the old process; tests never open the real app.
with tempfile.TemporaryDirectory(prefix='trackpointd-relaunch-test.') as directory:
    root = Path(directory)
    prefix = root / 'brew'
    prefix.mkdir()
    log = root / 'open.log'
    opener = root / 'open'
    opener.write_text(f'#!{sys.executable}\nfrom pathlib import Path\nimport sys\nPath({str(log)!r}).write_text(sys.argv[1])\n')
    opener.chmod(0o700)
    text = (ROOT / 'scripts/upgrade.sh').read_text().replace('/opt/homebrew', str(prefix))
    text = text.replace('/usr/bin/open', str(opener)).replace('{1..100}', '{1..3}')
    script = root / 'upgrade.sh'
    script.write_text(text)
    parent = subprocess.Popen(['/bin/sleep', '0.1'])
    updater = subprocess.Popen(['/bin/bash', str(script), 'relaunch', str(parent.pid), str(prefix)],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    parent.wait()
    updater.communicate(timeout=5)
    assert updater.returncode == 0
    assert log.read_text() == str(prefix / 'opt/trackpointd/TrackPointD.app')
    log.unlink()
    result = subprocess.run(['/bin/bash', str(script), 'relaunch', str(os.getpid()), str(prefix)],
                            capture_output=True)
    assert result.returncode == 1 and not log.exists()
    result = subprocess.run(['/bin/bash', str(script), 'relaunch', '1;bad', str(prefix)],
                            capture_output=True)
    assert result.returncode == 2 and not log.exists()
print('Updater relaunch ordering/timeout tests: ok (no real app launch)')
