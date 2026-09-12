#!/usr/bin/env python3
"""Exact MVP feature comparisons. This is not the full Stackage baseline."""
import argparse
import json
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import compare

NAMES = ['const', 'size', 'alignment', 'offset', 'peek', 'poke', 'ptr',
         'type', 'conditional', 'define', 'syntax']


def main():
    p = argparse.ArgumentParser()
    for key in ['candidate', 'reference', 'clang', 'target', 'sysroot', 'output']:
        p.add_argument('--' + key, required=True)
    p.add_argument('--cross-target')
    args = p.parse_args()
    context = Path(__file__).parent / 'mvp'
    cases = []
    cells = [(args.target, 'native', '', False), (args.target, 'cross', '', False),
             (args.target, 'cross', '/asm', True)]
    if args.cross_target:
        cells += [(args.cross_target, 'cross', '/' + args.cross_target, False),
                  (args.cross_target, 'cross', '/' + args.cross_target + '/asm', True)]
    for triple, mode, suffix, via_asm in cells:
        flags = ['--target=' + triple, '--sysroot=' + args.sysroot, '-std=gnu11']
        for name in NAMES:
            cases.append(dict(id=name + '/' + mode + suffix, target=triple, mode=mode,
                              source=name + '.hsc', context=str(context),
                              flags=['--cc=' + args.clang] + ['--cflag=' + f for f in flags],
                              candidate_flags=['--target=' + triple, '--sysroot=' + args.sysroot] + (['--cross-compile'] if mode == 'cross' else []),
                              reference_flags=['--via-asm'] if via_asm else [],
                              preflight=[args.clang, *flags, '-c', 'preflight.c', '-o', 'preflight.o']))
    summary = compare.run_suite(dict(candidate=[args.candidate], reference=[args.reference], cases=cases), args.output)
    # Deliberate exact zero baseline. Never derive expected counts from results.
    zero = dict(cases=11, candidate_failures=0, divergences=0, reference_native_failures=0,
                reference_cross_failures=0, reference_cross_unsupported=0,
                reference_cross_other_failures=0, setup_failures=0, tool_errors=0)
    expected = dict(counts={**zero, 'cases': 55 if args.cross_target else 33},
                    by_target_mode={triple + '/' + mode: {**zero, 'cases': 22 if mode == 'cross' else 11}
                                    for triple, mode, _, _ in cells},
                    case_ids=[name + '/' + mode + suffix for _, mode, suffix, _ in cells for name in NAMES],
                    inapplicable=[])
    try:
        compare.assert_expected(summary, expected)
    except ValueError:
        for report in sorted(Path(args.output).glob('*/result.json')):
            data = json.loads(report.read_text())
            if any(v for k, v in data['counts'].items() if k != 'cases'):
                print(report.read_text(), file=sys.stderr)
        for diff in sorted(Path(args.output).glob('*/difference.patch')):
            print(diff.read_text(), file=sys.stderr)
        raise
    # Failure tests do not use upstream as an oracle for unsupported features.
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        command = [args.candidate, '--cc=' + args.clang, '--target=' + args.target,
                   '--sysroot=' + args.sysroot, '-o', str(root / 'Result.hs')]
        for source, diagnostic in [('#{const_str "hello"}', 'AIHC_UNSUPPORTED'),
                                   ('#define hsc_size(x) 9\nx = #{size int}', 'AIHC_UNSUPPORTED_template_override'),
                                   ('x = #{const (__int128) 1}', 'AIHC_UNSUPPORTED_value_width'),
                                   ('x = #{const -0.25}', 'AIHC_UNSUPPORTED_noninteger_value'),
                                   ('#define LATE 1\nx = #{const LATE}\n#undef LATE\n', 'LATE'),
                                   ('#include "missing-aihc-header.h"\n', 'missing-aihc-header.h'),
                                   ('#{size MissingType}', 'MissingType')]:
            file = root / 'Input.hsc'
            file.write_text(source)
            result = subprocess.run(command + [str(file)], capture_output=True, text=True, timeout=30)
            assert result.returncode != 0 and diagnostic in result.stderr, result
        file.write_text('#if 0\n#{unknown runtime()}\n#endif\nx = #{const 1}\n')
        subprocess.run(command + [str(file)], check=True, capture_output=True, timeout=30)
        guard = root / 'compile-only-guard'
        log = root / 'compiler-arguments.json'
        guard.write_text('#!' + sys.executable + '\nimport os, sys, json\n'
                         'assert "-c" in sys.argv and "-E" not in sys.argv and "-S" not in sys.argv\n'
                         f'open({str(log)!r}, "w").write(json.dumps(sys.argv[1:]))\n'
                         f'os.execv({args.clang!r}, [{args.clang!r}] + sys.argv[1:])\n')
        guard.chmod(0o755)
        subprocess.run(command + ['--cc=' + str(guard), str(file)], check=True, capture_output=True, timeout=30)
        assert '-c' in json.loads(log.read_text())
        result = subprocess.run(command + ['--sysroot=' + str(root / 'missing'), str(file)], capture_output=True, text=True, timeout=30)
        assert result.returncode != 0 and 'missing sysroot:' in result.stderr
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
