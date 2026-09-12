#!/usr/bin/env python3
"""Real upstream smoke test; this is not candidate compatibility coverage."""
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

fixtures, out = map(Path, sys.argv[1:])
out.mkdir()
counts = {'cases': 3, 'native_failures': 0, 'cross_failures': 0,
          'cross_unsupported': 0, 'successful_mode_divergences': 0}
with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    for fixture in sorted(fixtures.glob('*.hsc')):
        results = {}
        for mode in ('native', 'cross'):
            work = root / fixture.stem / mode
            work.mkdir(parents=True)
            shutil.copyfile(fixture, work / fixture.name)
            argv = ['hsc2hs'] + (['--cross-compile'] if mode == 'cross' else [])
            result = subprocess.run(argv + ['-o', 'Result.hs', fixture.name],
                                    cwd=work, capture_output=True, timeout=120)
            success = result.returncode == 0 and (work / 'Result.hs').is_file()
            (out / (fixture.stem + '-' + mode + '.log')).write_bytes(result.stdout + result.stderr)
            if not success:
                counts[mode + '_failures'] += 1
                if mode == 'cross' and b'cannot be handled in cross-compilation mode' in result.stderr:
                    counts['cross_unsupported'] += 1
            else:
                results[mode] = (work / 'Result.hs').read_bytes()
                (out / (fixture.stem + '-' + mode + '.hs')).write_bytes(results[mode])
        if len(results) == 2:
            counts['successful_mode_divergences'] += int(results['native'] != results['cross'])
expected = {'cases': 3, 'native_failures': 0, 'cross_failures': 2,
            'cross_unsupported': 2, 'successful_mode_divergences': 0}
(out / 'summary.json').write_text(json.dumps(counts, indent=2) + '\n')
assert counts == expected, (counts, expected)
print(json.dumps(counts))
