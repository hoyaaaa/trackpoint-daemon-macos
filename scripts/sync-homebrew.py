#!/usr/bin/env python3
"""Regenerate the tap formula from the latest published stable GitHub release."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

from release import ROOT, REPO, metadata, stable_formula


def release_version(payload):
    tag = payload.get('tag_name') if isinstance(payload, dict) else None
    if (not isinstance(tag, str) or not re.fullmatch(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', tag)
            or payload.get('draft') is not False or payload.get('prerelease') is not False):
        raise ValueError('Expected a published stable vMAJOR.MINOR.PATCH release')
    return tag[1:]


def formula_for_archive(path, version, template):
    with tarfile.open(path, 'r:gz') as archive:
        # Read one known metadata file without extracting/executing downloaded files.
        member = archive.getmember(f'trackpointd-{version}/version.h')
        if not member.isfile() or member.size > 4096:
            raise ValueError('Invalid source version metadata')
        with archive.extractfile(member) as file:
            packaged_version, _ = metadata(file.read().decode())
    if packaged_version != version:
        raise ValueError('Release tag and packaged version differ')
    return stable_formula(template, version, hashlib.sha256(path.read_bytes()).hexdigest())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--write', action='store_true', help='Update Formula/trackpointd.rb for review; never commit or push')
    args = parser.parse_args()
    payload = json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/releases/latest'], text=True))
    version = release_version(payload)
    formula = ROOT / 'Formula/trackpointd.rb'
    with tempfile.TemporaryDirectory(prefix='trackpointd-brew.') as directory:
        subprocess.run(['gh', 'release', 'download', 'v'+version, '--repo', REPO,
                        '--pattern', f'trackpointd-{version}.tar.gz', '--dir', directory], check=True)
        updated = formula_for_archive(Path(directory) / f'trackpointd-{version}.tar.gz', version, formula.read_text())
    if args.write:
        subprocess.run(['git', 'diff', '--exit-code', 'HEAD', '--', 'Formula/trackpointd.rb'], cwd=ROOT, check=True)
        formula.write_text(updated)
        print('Updated Formula/trackpointd.rb. Run tests, review, and submit a signed PR.')
    else:
        print(updated, end='')


if __name__ == '__main__':
    main()
