#!/usr/bin/env python3
"""Run differential hsc2hs cases and assert exact, reviewed failure counts.

Only the native reference is allowed to run compiled input code. The runner
executes tool commands; the candidate implementation must enforce compile-only.
"""
import argparse
import difflib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

COUNTERS = (
    'cases', 'candidate_failures', 'divergences', 'reference_native_failures',
    'reference_cross_failures', 'reference_cross_unsupported',
    'reference_cross_other_failures', 'setup_failures', 'tool_errors',
)
UNSUPPORTED = re.compile(r'directive\s+.+?\s+cannot be handled in cross-compilation mode')


def invoke(argv, cwd, env, timeout):
    try:
        result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True,
                                timeout=timeout, check=False)
        return {'argv': argv, 'exit': result.returncode,
                'stdout': result.stdout.decode('utf-8', errors='replace'),
                'stderr': result.stderr.decode('utf-8', errors='replace'),
                'error': 'signal' if result.returncode < 0 else None}
    except (OSError, subprocess.TimeoutExpired) as exc:
        return {'argv': argv, 'exit': None, 'stdout': '', 'stderr': str(exc),
                'error': type(exc).__name__}


def artifacts(directory):
    # The main module must exist even if the process exits successfully.
    names = ('Result.hs', 'Result_hsc.c', 'Result_hsc.h')
    return {name: (directory / name).read_bytes()
            for name in names if (directory / name).is_file()}


def valid_relative(value):
    path = Path(value)
    return not path.is_absolute() and '..' not in path.parts and bool(path.parts)


def run_suite(config, destination):
    destination = Path(destination)
    destination.mkdir(parents=True)
    if not config.get('candidate') or not config.get('reference'):
        raise ValueError('Explicit candidate and reference command arrays are required')
    cases = config['cases']
    if not cases or len({c['id'] for c in cases}) != len(cases):
        raise ValueError('Cases must be nonempty and have unique IDs')
    if any(c['mode'] not in ('native', 'cross') for c in cases):
        raise ValueError('Each case must declare native or cross mode')
    if any(not c.get('target') or not valid_relative(c['source']) for c in cases):
        raise ValueError('Each case needs a target and a relative source path')
    # A supplied corpus must be covered in full for each requested matrix cell.
    # Explicit inapplicable entries preserve platform-specific files in accounting.
    if 'corpus' in config:
        inventory = json.loads(Path(config['corpus']).read_text())
        required = {f['id'] for f in inventory['files']}
        cells = config['matrix']
        if not cells or len({(x['target'], x['mode']) for x in cells}) != len(cells):
            raise ValueError('Matrix cells must be nonempty and unique')
        if {(c['target'], c['mode']) for c in cases} - {(x['target'], x['mode']) for x in cells}:
            raise ValueError('Cases outside the declared target/mode matrix')
        for cell in cells:
            selected = [c['corpus_id'] for c in cases if
                        (c['target'], c['mode']) == (cell['target'], cell['mode'])]
            omitted = [x for x in config.get('inapplicable', []) if
                       (x['target'], x['mode']) == (cell['target'], cell['mode'])]
            if any(not x.get('reason') for x in omitted):
                raise ValueError('Inapplicable files need a reason')
            accounted = selected + [x['corpus_id'] for x in omitted]
            if len(accounted) != len(set(accounted)) or set(accounted) != required:
                raise ValueError(f'Incomplete or duplicate corpus coverage for {cell}')
    counters = {key: 0 for key in COUNTERS}
    results = []
    by_cell = {}
    for index, case in enumerate(cases):
        counts = {key: 0 for key in COUNTERS}
        counts['cases'] = 1
        report = {'id': case['id'], 'target': case['target'], 'mode': case['mode']}
        case_output = destination / f'{index:05d}'
        case_output.mkdir()
        context = Path(case['context'])
        source = case['source']
        if not (context / source).is_file():
            raise ValueError(f"{case['id']}: source missing from context")
        env = os.environ.copy()
        env.update(config.get('env', {}))
        env.update(case.get('env', {}))
        timeout = case.get('timeout', config.get('timeout', 120))
        if timeout <= 0:
            raise ValueError('Timeout must be positive')
        with tempfile.TemporaryDirectory(prefix='hsc-comparison-') as temp:
            root = Path(temp)
            # Separate pristine contexts prevent either tool contaminating the other.
            for role in ('candidate', 'reference', 'preflight'):
                shutil.copytree(context, root / role, symlinks=False)
                for path in (root / role).rglob('*'):
                    path.chmod(path.stat().st_mode | 0o200)
                (root / role).chmod(0o700)
                for name in ('Result.hs', 'Result_hsc.c', 'Result_hsc.h'):
                    (root / role / name).unlink(missing_ok=True)
            if not case.get('preflight'):
                raise ValueError(f"{case['id']}: target/header preflight command is required")
            report['preflight'] = invoke(case['preflight'], root / 'preflight', env, timeout)
            if report['preflight']['exit'] != 0:
                counts['setup_failures'] = 1
                counts['tool_errors'] += int(bool(report['preflight']['error']))
            else:
                outputs = {}
                for role in ('candidate', 'reference'):
                    flags = case.get('flags', []) + case.get(role + '_flags', [])
                    argv = list(config[role]) + flags
                    if role == 'reference' and case['mode'] == 'cross':
                        argv.append('--cross-compile')
                    argv += ['-o', 'Result.hs', source]
                    result = invoke(argv, root / role, env, timeout)
                    files = artifacts(root / role)
                    success = result['exit'] == 0 and 'Result.hs' in files
                    result['produced_output'] = 'Result.hs' in files
                    result['success'] = success
                    counts['tool_errors'] += int(bool(result['error']))
                    report[role] = result
                    outputs[role] = files
                    role_output = case_output / role
                    role_output.mkdir()
                    for name, data in files.items():
                        (role_output / name).write_bytes(data)
                    if not success:
                        if role == 'candidate':
                            counts['candidate_failures'] += 1
                        elif case['mode'] == 'native':
                            counts['reference_native_failures'] += 1
                        else:
                            counts['reference_cross_failures'] += 1
                            unsupported = bool(UNSUPPORTED.search(result['stderr']))
                            counts['reference_cross_unsupported' if unsupported else
                                   'reference_cross_other_failures'] += 1
                if all(report[role]['success'] for role in ('candidate', 'reference')):
                    # Exact bytes, including layout and line pragmas. Both tools see
                    # the same relative input/output names. No whitespace stripping.
                    counts['divergences'] = int(outputs['candidate'] != outputs['reference'])
                    if counts['divergences']:
                        diff = []
                        for name in sorted(set(outputs['candidate']) | set(outputs['reference'])):
                            left = outputs['reference'].get(name, b'').decode('utf-8', 'replace')
                            right = outputs['candidate'].get(name, b'').decode('utf-8', 'replace')
                            diff.extend(difflib.unified_diff(left.splitlines(True), right.splitlines(True),
                                                           'reference/' + name, 'candidate/' + name))
                        (case_output / 'difference.patch').write_text(''.join(diff))
        report['counts'] = counts
        (case_output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
        results.append(report)
        cell = case['target'] + '/' + case['mode']
        cell_counts = by_cell.setdefault(cell, {key: 0 for key in COUNTERS})
        for key in COUNTERS:
            counters[key] += counts[key]
            cell_counts[key] += counts[key]
    summary = {'counts': counters, 'by_target_mode': by_cell,
               'inapplicable': config.get('inapplicable', []),
               'case_ids': [r['id'] for r in results]}
    (destination / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    return summary


def assert_expected(summary, expected):
    # Compare every counter and every cell; aggregate cancellation is insufficient.
    if summary != expected:
        raise ValueError('Comparison baseline changed:\n' + ''.join(difflib.unified_diff(
            (json.dumps(expected, indent=2, sort_keys=True) + '\n').splitlines(True),
            (json.dumps(summary, indent=2, sort_keys=True) + '\n').splitlines(True),
            'expected', 'actual')))
    counts = summary['counts']
    if counts['setup_failures'] or counts['tool_errors'] or counts['reference_native_failures']:
        raise ValueError('Setup/tool/native-oracle failures cannot be accepted as a baseline')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--expected', help='Required unless explicitly collecting a report')
    parser.add_argument('--report-only', action='store_true')
    args = parser.parse_args()
    if bool(args.expected) == args.report_only:
        parser.error('Choose exactly one of --expected and --report-only')
    summary = run_suite(json.loads(Path(args.config).read_text()), args.output)
    print(json.dumps(summary, indent=2))
    if args.expected:
        assert_expected(summary, json.loads(Path(args.expected).read_text()))


if __name__ == '__main__':
    main()
