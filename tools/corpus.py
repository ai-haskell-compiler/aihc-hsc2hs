#!/usr/bin/env python3
"""Materialize a pinned, checked corpus without executing package code."""
import argparse
import hashlib
import json
import os
import tarfile
from pathlib import Path, PurePosixPath


def unpack(manifest_path, archives_path, output):
    manifest = json.loads(Path(manifest_path).read_text())
    archives = json.loads(Path(archives_path).read_text())
    output = Path(output)
    sources = output / 'sources'
    sources.mkdir(parents=True)
    found = []
    packages = manifest['packages']
    assert len(packages) == manifest['package_count']
    assert len({p['name'] for p in packages}) == len(packages)
    assert set(archives) == {p['name'] for p in packages}
    for package in packages:
        name = package['name']
        archive = Path(archives[name])
        if hashlib.sha256(archive.read_bytes()).hexdigest() != package['sha256']:
            raise ValueError(f'{name}: archive hash mismatch')
        actual = {}
        with tarfile.open(archive, 'r:gz') as tar:
            seen = set()
            for member in tar:
                path = PurePosixPath(member.name)
                if path.is_absolute() or '..' in path.parts or not path.parts or path.parts[0] != name:
                    raise ValueError(f'{name}: unsafe archive path {member.name!r}')
                if member.isdir():
                    continue
                # Hackage sdists consist of regular files, not executable links.
                if not member.isfile():
                    raise ValueError(f'{name}: unsupported archive member {member.name!r}')
                normalized = str(path)
                dest = sources / normalized
                data = tar.extractfile(member).read()
                if normalized in seen:
                    if dest.read_bytes() != data:
                        raise ValueError(f'{name}: conflicting duplicate archive member {normalized}')
                    continue
                seen.add(normalized)
                dest.parent.mkdir(parents=True, exist_ok=True)
                dest.write_bytes(data)
                dest.chmod(0o755 if member.mode & 0o111 else 0o644)
                if normalized.endswith('.hsc'):
                    actual[normalized] = hashlib.sha256(data).hexdigest()
        expected = {f['path']: f['sha256'] for f in package['hsc_files']}
        if actual != expected:
            raise ValueError(f'{name}: .hsc inventory/content mismatch')
        found.extend({'id': path, 'package': name, 'sha256': digest}
                     for path, digest in sorted(actual.items()))
    assert len(found) == manifest['file_count']
    assert len({f['package'] for f in found}) == manifest['packages_with_hsc']
    (output / 'manifest.json').write_text(json.dumps({
        'snapshot': manifest['snapshot'], 'compiler': manifest['compiler'],
        'packages': len(packages), 'files': found,
    }, indent=2) + '\n')
    (output / 'hsc-files.txt').write_text(''.join(f['id'] + '\n' for f in found))
    hsc = output / 'hsc'
    hsc.mkdir()
    for item in found:
        dest = hsc / item['id']
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.symlink_to(os.path.relpath(sources / item['id'], dest.parent))
    print(f"Verified {len(found)} .hsc files in {len(packages)} source archives")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest')
    parser.add_argument('archives')
    parser.add_argument('output')
    args = parser.parse_args()
    unpack(args.manifest, args.archives, args.output)
