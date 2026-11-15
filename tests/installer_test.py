"""Run copied production scripts in a temporary filesystem with OS commands intercepted."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STUB = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ['TEST_LOG'], 'a') as out:
    out.write(json.dumps([name, *args]) + '\n')
fail = os.environ.get('FAIL_STEP', '')
if name == 'clang':
    if fail == 'build': sys.exit(1)
    dest = pathlib.Path(args[args.index('-o') + 1])
    dest.write_text('#!/bin/bash\n[ "${FAIL_STEP:-}" != "self-test" ]\n')
    dest.chmod(0o755)
elif name == 'codesign':
    if (fail == 'sign' and '--sign' in args) or (fail == 'verify' and '--verify' in args): sys.exit(1)
elif name == 'mv':
    if fail == 'move' and args[-1].endswith('/Applications/TrackPointD.app') and 'previous.app' not in args[0]: sys.exit(1)
    sys.exit(subprocess.call(['/bin/mv', *args]))
elif name == 'open':
    if fail == 'open': sys.exit(1)
elif name == 'osascript':
    sys.stdin.read()
    if fail == 'login': sys.exit(1)
elif name == 'pgrep':
    sys.exit(1)
elif name not in ('pkill', 'launchctl', 'hidutil', 'lsregister'):
    raise AssertionError('unexpected command: ' + name)
'''


def scenario(mode, failure='', existing=True):
    with tempfile.TemporaryDirectory(prefix='trackpointd-script-test.') as tmp:
        base = Path(tmp)
        fakebin = base / 'bin'
        fakebin.mkdir()
        for command in ('clang', 'codesign', 'mv', 'open', 'osascript', 'pgrep',
                        'pkill', 'launchctl', 'hidutil', 'lsregister'):
            path = fakebin / command
            path.write_text(STUB)
            path.chmod(0o755)
        home = base / 'user'
        app = home / 'Applications/TrackPointD.app'
        app.parent.mkdir(parents=True)
        if existing:
            app.mkdir()
            (app / 'old-version').write_text('preserve me')
        legacy = home / 'Library/LaunchAgents/com.user.trackpointd.plist'
        legacy.parent.mkdir(parents=True)
        legacy.write_text('old agent')
        sentinel = home / 'unrelated-file'
        sentinel.write_text('untouched')
        source = base / 'source'
        source.mkdir()
        for name in ('install.sh', 'uninstall.sh'):
            text = (ROOT / name).read_text()
            # Only the private copy is redirected. Never override the user's HOME.
            text = text.replace('${HOME:?}', '${TEST_HOME:?}').replace('$HOME', '$TEST_HOME')
            text = text.replace('/usr/bin/hidutil', str(fakebin / 'hidutil'))
            text = text.replace('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
                                str(fakebin / 'lsregister'))
            (source / name).write_text(text)
        log = base / 'commands.jsonl'
        env = dict(os.environ, TEST_HOME=str(home), TEST_LOG=str(log), FAIL_STEP=failure,
                   TRACKPOINTD_SIGN_IDENTITY='-', TMPDIR=str(base),
                   PATH=str(fakebin) + os.pathsep + os.environ['PATH'])
        script = 'uninstall.sh' if mode == 'uninstall' else 'install.sh'
        args = ['--check'] if mode == 'check' else []
        if mode == 'refuse':
            shutil.rmtree(app)
            app.write_text('not an app')
        result = subprocess.run(['bash', str(source / script), *args], env=env,
                                capture_output=True, text=True, timeout=30)
        entries = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        names = [entry[0] for entry in entries]
        if mode == 'refuse':
            assert result.returncode != 0 and app.read_text() == 'not an app'
            assert not entries
        elif mode == 'uninstall':
            assert result.returncode == 0, result.stderr
            assert not app.exists() and not legacy.exists()
            calls = [entry for entry in entries if entry[0] == 'hidutil']
            assert len(calls) == 2
            products = set()
            for call in calls:
                match = json.loads(call[call.index('--matching') + 1])
                assert match['VendorID'] == 6127
                products.add(match['ProductID'])
                assert json.loads(call[call.index('--set') + 1]) == {'UserKeyMapping': []}
            assert products == {24814, 24801}
        elif mode == 'check':
            assert result.returncode == 0, result.stderr
            assert (app / 'old-version').read_text() == 'preserve me'
            assert not any(name in names for name in ('open', 'pkill', 'osascript', 'lsregister'))
        elif failure and failure != 'login':
            assert result.returncode != 0, failure
            if existing:
                assert (app / 'old-version').read_text() == 'preserve me', failure
            else:
                assert not app.exists(), failure
            assert legacy.exists()
            if failure in ('build', 'self-test', 'sign', 'verify'):
                assert 'pkill' not in names and 'open' not in names
        else:
            assert result.returncode == 0, result.stderr
            assert (app / 'Contents/MacOS/trackpointd').exists()
            assert not (app / 'old-version').exists()
            assert legacy.exists() == (failure == 'login')
            assert names.index('codesign') < names.index('pkill')
        assert sentinel.read_text() == 'untouched'
        assert not list(base.glob('trackpointd-install.*')), 'staging leaked'


scenario('check')
scenario('refuse')
scenario('install')
scenario('install', existing=False)
for failure in ('build', 'self-test', 'sign', 'verify', 'move', 'open', 'login'):
    scenario('install', failure)
scenario('install', 'open', existing=False)
scenario('uninstall')
scenario('uninstall', existing=False)
# Invalid arguments must be rejected before touching the filesystem or OS commands.
for script, arguments in [('install.sh', ['--bad']), ('install.sh', ['--check', 'extra']),
                          ('uninstall.sh', ['extra'])]:
    result = subprocess.run(['bash', str(ROOT / script), *arguments], capture_output=True, text=True)
    assert result.returncode == 2
print('installer/uninstaller tests: ok (isolated filesystem and intercepted commands)')
