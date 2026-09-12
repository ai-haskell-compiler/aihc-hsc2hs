import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('compare', Path(__file__).parents[1] / 'tools/compare.py')
compare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compare)

TOOL = r'''
import pathlib, sys, time
role = sys.argv[1]
case = pathlib.Path(sys.argv[-1]).read_text()
cross = '--cross-compile' in sys.argv
if case == 'timeout' and role == 'candidate': time.sleep(3)
if case == 'no-output' and role == 'candidate': sys.exit(0)
if case == 'native-failure' and role == 'reference': sys.exit(1)
if case == 'unsupported' and role == 'reference' and cross:
    print('directive const_str cannot be handled in cross-compilation mode', file=sys.stderr)
    sys.exit(1)
if case == 'header-error' and role == 'reference' and cross:
    print('missing.h not found', file=sys.stderr)
    sys.exit(1)
if case == 'diverge' and role == 'candidate': result = 'value = 43\n'
else: result = 'value = 42\n'
pathlib.Path('Result.hs').write_text(result)
if case == 'companion' and role == 'candidate': pathlib.Path('Result_hsc.c').write_text('extra')
'''


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tool = self.root / 'tool.py'
        self.tool.write_text(TOOL)
        self.config = {'candidate': [sys.executable, str(self.tool), 'candidate'],
                       'reference': [sys.executable, str(self.tool), 'reference'], 'cases': []}

    def add(self, name, mode='native', **kwargs):
        context = self.root / ('context-' + str(len(self.config['cases'])))
        context.mkdir()
        (context / 'Input.hsc').write_text(name)
        case = {'id': name + '-' + mode, 'source': 'Input.hsc', 'context': str(context),
                'mode': mode, 'target': 'test-target',
                'preflight': [sys.executable, '-c', 'pass'], **kwargs}
        self.config['cases'].append(case)
        return case

    def run_config(self):
        return compare.run_suite(self.config, self.root / 'report')

    def test_counters_and_native_cross_partition(self):
        for name, mode in [('ok', 'native'), ('no-output', 'native'), ('diverge', 'native'),
                           ('unsupported', 'cross'), ('header-error', 'cross'), ('companion', 'native')]:
            self.add(name, mode)
        result = self.run_config()
        self.assertEqual(result['counts'], dict(zip(compare.COUNTERS, [6, 1, 2, 0, 2, 1, 1, 0, 0])))
        self.assertEqual(result['by_target_mode']['test-target/native']['divergences'], 2)
        compare.assert_expected(result, copy.deepcopy(result))
        changed = copy.deepcopy(result)
        changed['counts']['candidate_failures'] = 0
        with self.assertRaises(ValueError): compare.assert_expected(result, changed)

    def test_improvement_also_requires_baseline_review(self):
        self.add('ok')
        result = self.run_config()
        expected = copy.deepcopy(result)
        expected['counts']['candidate_failures'] = 1
        with self.assertRaises(ValueError): compare.assert_expected(result, expected)

    def test_missing_executable_is_not_cross_unsupported(self):
        self.add('ok', 'cross')
        self.config['reference'] = [str(self.root / 'missing')]
        result = self.run_config()
        self.assertEqual(result['counts']['tool_errors'], 1)
        self.assertEqual(result['counts']['reference_cross_unsupported'], 0)
        with self.assertRaises(ValueError): compare.assert_expected(result, result)

    def test_timeout_fails_even_if_baselined(self):
        self.add('timeout', timeout=0.5)
        result = self.run_config()
        self.assertEqual(result['counts']['tool_errors'], 1)
        with self.assertRaises(ValueError): compare.assert_expected(result, result)

    def test_setup_failure_cannot_be_baselined(self):
        self.add('ok', preflight=[sys.executable, '-c', 'raise SystemExit(1)'])
        result = self.run_config()
        self.assertEqual(result['counts']['setup_failures'], 1)
        self.assertEqual(result['counts']['candidate_failures'], 0)
        with self.assertRaises(ValueError): compare.assert_expected(result, result)

    def test_native_reference_failure_cannot_be_baselined(self):
        self.add('native-failure')
        result = self.run_config()
        self.assertEqual(result['counts']['reference_native_failures'], 1)
        with self.assertRaises(ValueError): compare.assert_expected(result, result)

    def test_stale_outputs_do_not_count_as_success(self):
        case = self.add('no-output')
        (Path(case['context']) / 'Result.hs').write_text('stale')
        result = self.run_config()
        self.assertEqual(result['counts']['candidate_failures'], 1)

    def test_corpus_cannot_silently_shrink(self):
        case = self.add('ok')
        case['corpus_id'] = 'pkg/Input.hsc'
        inventory = self.root / 'inventory.json'
        inventory.write_text(json.dumps({'files': [{'id': 'pkg/Input.hsc'}, {'id': 'pkg/Other.hsc'}]}))
        self.config.update(corpus=str(inventory), matrix=[{'target': 'test-target', 'mode': 'native'}])
        with self.assertRaisesRegex(ValueError, 'coverage'): self.run_config()

    def test_case_list_is_asserted_not_just_totals(self):
        self.add('ok')
        result = self.run_config()
        expected = copy.deepcopy(result)
        expected['case_ids'] = ['different-test']
        with self.assertRaises(ValueError): compare.assert_expected(result, expected)

    def test_empty_suite_rejected(self):
        with self.assertRaises(ValueError): self.run_config()


if __name__ == '__main__': unittest.main()
