import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('readme_stats', Path(__file__).parents[1] / 'tools/readme-stats.py')
readme_stats = importlib.util.module_from_spec(spec)
spec.loader.exec_module(readme_stats)


class ReadmeTests(unittest.TestCase):
    def test_generated_sections_are_current(self):
        current = readme_stats.README.read_text()
        self.assertEqual(readme_stats.render(current), current,
                         'README.md is out of date; run tools/readme-stats.py --write')

    def test_every_baseline_accounts_for_the_whole_inventory(self):
        rows = readme_stats.stackage_rows()
        self.assertTrue(rows)
        for row in rows:
            self.assertGreater(row['matches'], 0, row['label'])
            self.assertLessEqual(row['matches'] + row['candidate_failures'] + row['divergences'],
                                 row['applicable'], row['label'])

    def test_directive_counting(self):
        counts = readme_stats.count_directives(
            'x = #{const 1}\ny = (#size int)\n#include "a.h"\nz = ##const\n("peek struct S, x", 8)\n#{twice 21}')
        self.assertEqual({k: v for k, v in counts.items() if v},
                         {'const': 1, 'size': 1, 'include': 1, 'peek': 1})

    def test_import_rejects_hard_errors(self):
        import json
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            bad = Path(tmp) / 'aarch64-linux-native.json'
            bad.write_text(json.dumps({'counts': {k: 0 for k in readme_stats.HARD_ERRORS} | {'setup_failures': 1},
                                       'by_target_mode': {}, 'inapplicable': [], 'verified_match_ids': []}))
            with self.assertRaises(ValueError):
                readme_stats.import_summary(bad)
