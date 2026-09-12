import hashlib
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parents[1] / 'tools'))
import stackage


class ContextTests(unittest.TestCase):
    def test_cross_backend_retains_enum_oracle(self):
        for source in [b'x = #enum T, C, A, B', b'#{enum T, C, A}', b'#{\n enum T, C, A}',
                       b'-- even a comment mentioning #enum stays conservative']:
            self.assertEqual(stackage.cross_backend(source), 'classic')
        self.assertEqual(stackage.cross_backend(b'#include <stddef.h>\nx = #{const 42}'), 'asm')

    def test_pkgconfig_conjunction_and_alternative(self):
        results = [dict(exit=1, stderr='too old'), dict(exit=0),
                   dict(exit=0, stdout='-I/provider/include -lfoo')]
        with patch.object(stackage, 'run', side_effect=results) as run:
            result = stackage.pkgconfig_options(['foo >=2 && <3 || >=4'], '.', {})
        self.assertEqual(result['exit'], 0)
        self.assertEqual(run.call_args_list[0].args[0],
                         ['pkg-config', '--print-errors', '--exists', 'foo >= 2', 'foo < 3'])
        self.assertEqual(run.call_args_list[1].args[0][-1], 'foo >= 4')
        self.assertEqual(run.call_args_list[2].args[0], ['pkg-config', '--cflags', '--libs', 'foo'])

    def test_pkgconfig_failure_preserves_diagnostics(self):
        with patch.object(stackage, 'run', return_value=dict(exit=1, stderr='missing provider')):
            result = stackage.pkgconfig_options(['foo >=2'], '.', {})
        self.assertEqual(result['exit'], 1)
        self.assertIn('missing provider', result['stderr'])

    def test_source_bytes_cannot_be_changed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'Input.hsc'
            source.write_bytes(b'original\r\n')
            inventory = {'files': [{'id': 'Input.hsc',
                                    'sha256': hashlib.sha256(source.read_bytes()).hexdigest()}]}
            stackage.verify_sources(inventory, root)
            source.write_bytes(b'original\n')
            with self.assertRaisesRegex(ValueError, 'differs from pinned corpus'):
                stackage.verify_sources(inventory, root)
