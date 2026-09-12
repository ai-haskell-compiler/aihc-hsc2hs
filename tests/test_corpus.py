import hashlib
import importlib.util
import io
import json
import tarfile
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location('corpus', Path(__file__).parents[1] / 'tools/corpus.py')
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


class CorpusTests(unittest.TestCase):
    def test_complete_extraction_and_links(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            archive = root / 'pkg-1.tar.gz'
            files = {'pkg-1/src/One.hsc': b'module One where\n', 'pkg-1/include/test.h': b'#define VALUE 1\n'}
            with tarfile.open(archive, 'w:gz') as tar:
                for name, data in files.items():
                    info = tarfile.TarInfo(name)
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
                    # Some Hackage sdists repeat an identical LICENSE entry.
                    tar.addfile(info, io.BytesIO(data))
            manifest = {'snapshot': 'fixture', 'compiler': 'fixture', 'package_count': 1,
                        'file_count': 1, 'packages_with_hsc': 1, 'packages': [{
                            'name': 'pkg-1', 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest(),
                            'hsc_files': [{'path': 'pkg-1/src/One.hsc',
                                           'sha256': hashlib.sha256(files['pkg-1/src/One.hsc']).hexdigest()}]}]}
            (root / 'manifest.json').write_text(json.dumps(manifest))
            (root / 'archives.json').write_text(json.dumps({'pkg-1': str(archive)}))
            corpus.unpack(root / 'manifest.json', root / 'archives.json', root / 'out')
            self.assertEqual((root / 'out/hsc/pkg-1/src/One.hsc').read_bytes(), files['pkg-1/src/One.hsc'])
            self.assertTrue((root / 'out/sources/pkg-1/include/test.h').is_file())
            manifest['file_count'] = 2
            (root / 'manifest.json').write_text(json.dumps(manifest))
            with self.assertRaises(AssertionError):
                corpus.unpack(root / 'manifest.json', root / 'archives.json', root / 'bad')
