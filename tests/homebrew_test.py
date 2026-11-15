import importlib.util
import io
from pathlib import Path
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
spec = importlib.util.spec_from_file_location('sync_homebrew', ROOT / 'scripts/sync-homebrew.py')
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)
assert sync.release_version({'tag_name':'v2.3.0','draft':False,'prerelease':False}) == '2.3.0'
for payload in (None, {}, {'tag_name':'v2.3.0','draft':True,'prerelease':False},
                {'tag_name':'v2.3.0-rc1','draft':False,'prerelease':True},
                {'tag_name':'v2.3.0; shell','draft':False,'prerelease':False}):
    try:
        sync.release_version(payload)
    except ValueError:
        pass
    else:
        raise AssertionError('invalid release accepted')
with tempfile.TemporaryDirectory(prefix='trackpointd-brew-test.') as directory:
    archive = Path(directory) / 'source.tar.gz'
    with tarfile.open(archive, 'w:gz') as out:
        header = b'#define TRACKPOINTD_VERSION "2.3.0"\n#define TRACKPOINTD_BUILD "13"\n'
        member = tarfile.TarInfo('trackpointd-2.3.0/version.h')
        member.size = len(header)
        out.addfile(member, io.BytesIO(header))
    result = sync.formula_for_archive(archive,'2.3.0',(ROOT / 'Formula/trackpointd.rb').read_text())
    assert 'version "2.3.0"' in result and 'sha256 ' in result
    try:
        sync.formula_for_archive(archive,'2.4.0',(ROOT / 'Formula/trackpointd.rb').read_text())
    except (KeyError, ValueError):
        pass
    else:
        raise AssertionError('wrong packaged version accepted')
print('Homebrew stable-release/checksum tests: ok')
