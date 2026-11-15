"""Release preparation is tested without publishing tags, releases or packages."""
import gzip
import hashlib
import importlib.util
from pathlib import Path
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('release', ROOT / 'scripts/release.py')
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
header = '#define TRACKPOINTD_VERSION "2.3.0"\n#define TRACKPOINTD_BUILD "13"\n'
assert release.metadata(header) == ('2.3.0', 13)
for value in ('', header.replace('2.3.0', '02.3.0'), header.replace('"13"', '"0"')):
    try:
        release.metadata(value)
    except ValueError:
        pass
    else:
        raise AssertionError(value)
changelog = '# Changelog\n## 2.3.0 — Unreleased\n\nNew notes\n\n## 2.2.1 — Old\nOld notes\n'
assert release.release_notes(changelog, '2.3.0') == 'New notes\n'
for value in ('3.0.0', '2.3.1'):
    try:
        release.release_notes(changelog, value)
    except ValueError:
        pass
    else:
        raise AssertionError('missing notes accepted')
template = (ROOT / 'Formula/trackpointd.rb').read_text()
digest = hashlib.sha256(b'archive').hexdigest()
formula = release.stable_formula(template, '2.3.0', digest)
assert f'sha256 "{digest}"' in formula
assert '/releases/download/v2.3.0/trackpointd-2.3.0.tar.gz' in formula
assert release.stable_formula(formula, '2.3.1', digest).count('  sha256 ') == 1
for version, checksum in [('2.3.0; command', digest), ('2.3.0', 'invalid')]:
    try:
        release.stable_formula(template, version, checksum)
    except ValueError:
        pass
    else:
        raise AssertionError('invalid formula metadata accepted')


def git_output(command, **kwargs):
    if command[1] == 'archive':
        return b'test archive bytes'
    path = command[2].split(':', 1)[1]
    return {'version.h': header, 'CHANGELOG.md': changelog, 'Formula/trackpointd.rb': template}[path]


with tempfile.TemporaryDirectory(prefix='trackpointd-release-test.') as directory:
    output = Path(directory)
    with patch.object(release.subprocess, 'check_output', side_effect=git_output):
        archive = release.prepare('HEAD', output, 'v2.3.0')
        before = archive.read_bytes()
        assert gzip.decompress(before) == b'test archive bytes'
        release.prepare('HEAD', output, 'v2.3.0')
        assert archive.read_bytes() == before
        assert hashlib.sha256(before).hexdigest() in (output / 'SHA256SUMS').read_text()
        assert (output / 'RELEASE_NOTES.md').read_text() == 'New notes\n'
        try:
            release.prepare('HEAD', output, 'v2.4.0')
        except ValueError:
            pass
        else:
            raise AssertionError('mismatched tag accepted')
print('release packaging/notes/formula tests: ok')
