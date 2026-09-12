#!/usr/bin/env python3
"""Resolve snapshot Cabal revisions, retaining only hashes/URLs, never sources."""
import argparse
import concurrent.futures
import hashlib
import json
from pathlib import Path
import re
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('corpus', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    manifest = json.loads((root / 'data/stackage.json').read_text())
    yaml = (root / 'data/lts-24.58.yaml').read_text()
    revisions = dict(re.findall(r'hackage: ([^@\s]+)@sha256:([0-9a-f]+)', yaml))
    flags, package = {}, None
    for line in yaml.split('packages:')[0].splitlines()[1:]:
        match = re.fullmatch(r'  ([\w-]+):', line)
        if match:
            package = match[1]
        match = re.fullmatch(r'    ([\w-]+): (true|false)', line)
        if match and package:
            flags.setdefault(package, {})[match[1]] = match[2] == 'true'
    def resolve(p):
        package = p['name']
        directory = args.corpus / 'sources' / package
        cabals = list(directory.glob('*.cabal'))
        if len(cabals) != 1:
            raise ValueError((package, cabals))
        original = cabals[0].read_bytes()
        digest = hashlib.sha256(original).hexdigest()
        wanted = revisions.get(package, digest)
        result = dict(package=package, file=cabals[0].name, sha256=wanted,
                      flags=flags.get(cabals[0].stem, {}))
        if wanted == digest:
            result['archive'] = True
        else:
            history_url = f'https://hackage-content.haskell.org/package/{package}/revisions/'
            request = urllib.request.Request(history_url, headers={'Accept': 'application/json'})
            history = json.load(urllib.request.urlopen(request, timeout=60))
            matches = [r for r in history if r['sha256'] == wanted]
            if len(matches) != 1:
                raise ValueError(f'{package}: pinned revision not found')
            url = f'https://hackage-content.haskell.org/package/{package}/revision/{matches[0]["number"]}.cabal'
            content = urllib.request.urlopen(url, timeout=60).read()
            if hashlib.sha256(content).hexdigest() != wanted:
                raise ValueError(f'{package}: revision hash mismatch')
            result['url'] = url
        return result
    packages = [p for p in manifest['packages'] if p['hsc_files']]
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(resolve, packages))
    args.output.write_text(json.dumps(results, indent=2) + '\n')
    print(f'Pinned {len(results)} package descriptions; {sum("url" in p for p in results)} revised')


if __name__ == '__main__':
    main()
