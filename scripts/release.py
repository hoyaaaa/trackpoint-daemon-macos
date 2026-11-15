#!/usr/bin/env python3
"""Prepare immutable source assets, release notes and a checksummed Homebrew formula."""
import argparse
import gzip
import hashlib
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REPO = 'hoyaaaa/trackpoint-daemon-macos'


def metadata(header):
    version = re.search(r'^#define TRACKPOINTD_VERSION "(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)"$', header, re.M)
    build = re.search(r'^#define TRACKPOINTD_BUILD "([1-9][0-9]*)"$', header, re.M)
    if not version or not build:
        raise ValueError('Invalid version.h')
    return '.'.join(version.groups()), int(build[1])


def release_notes(changelog, version):
    headings = list(re.finditer(r'^## ([0-9]+\.[0-9]+\.[0-9]+) — .+$', changelog, re.M))
    for index, heading in enumerate(headings):
        if heading[1] == version:
            end = headings[index+1].start() if index+1 < len(headings) else len(changelog)
            notes = changelog[heading.end():end].strip()
            if not notes:
                break
            return notes + '\n'
    raise ValueError('Missing nonempty changelog entry for ' + version)


def stable_formula(template, version, digest):
    if not re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)', version):
        raise ValueError('Invalid version')
    if not re.fullmatch('[0-9a-f]{64}', digest):
        raise ValueError('Invalid SHA-256')
    url = f'https://github.com/{REPO}/releases/download/v{version}/trackpointd-{version}.tar.gz'
    # Replace any previous stable metadata while retaining HEAD as a development option.
    template = re.sub(r'^  (?:url|sha256|version) .+\n', '', template, flags=re.M)
    if '  head ' not in template:
        raise ValueError('Formula is missing its HEAD source')
    return template.replace('  head ', f'  url "{url}"\n  sha256 "{digest}"\n  version "{version}"\n  head ', 1)


def prepare(ref, output, tag=None):
    def read(path):
        return subprocess.check_output(['git', 'show', f'{ref}:{path}'], cwd=ROOT, text=True)
    version, build = metadata(read('version.h'))
    if tag is not None and tag != 'v' + version:
        raise ValueError('Tag does not match version.h')
    notes = release_notes(read('CHANGELOG.md'), version)
    data = subprocess.check_output(['git', 'archive', '--format=tar', f'--prefix=trackpointd-{version}/', ref], cwd=ROOT)
    output.mkdir(parents=True, exist_ok=True)
    archive = output / f'trackpointd-{version}.tar.gz'
    archive.write_bytes(gzip.compress(data, mtime=0))
    digest = hashlib.sha256(archive.read_bytes()).hexdigest()
    (output / 'SHA256SUMS').write_text(f'{digest}  {archive.name}\n')
    (output / 'RELEASE_NOTES.md').write_text(notes)
    (output / 'trackpointd.rb').write_text(stable_formula(read('Formula/trackpointd.rb'), version, digest))
    print(f'Prepared v{version} (build {build}) in {output}')
    return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ref', default='HEAD')
    parser.add_argument('--tag')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    args = parser.parse_args()
    prepare(args.ref, args.output, args.tag)
