"""Exercise real Cabal conditional resolution and generated buildinfo."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    cabal = root / 'example.cabal'
    cabal.write_text('''cabal-version: 2.4
name: example
version: 1.0
build-type: Configure
flag alternate
  default: False
  manual: True
library
  exposed-modules: Example
  hs-source-dirs: src
  build-depends: base >=4
  if os(windows)
    other-modules: Windows
  else
    other-modules: Unix
  if flag(alternate)
    cpp-options: -DALTERNATE
test-suite smoke
  type: exitcode-stdio-1.0
  main-is: Main.hsc
  hs-source-dirs: test
  build-depends: base
''')
    versions = root / 'versions.txt'
    versions.write_text('example-1.0\nbase-4.20.2.0\n')
    (root / 'example.buildinfo').write_text('include-dirs: generated\ninstall-includes: config.h\n')
    def resolve(os, flag):
        return json.loads(subprocess.check_output(
            [sys.argv[1], 'aarch64', os, str(cabal), str(versions), flag], text=True))
    unix = resolve('linux', '-alternate')['components']
    assert unix[0]['modules'] == ['Example', 'Unix'], unix
    assert unix[0]['include_dirs'] == ['generated'], unix
    assert unix[0]['install_includes'] == ['config.h'], unix
    assert 'MIN_VERSION_base' in unix[0]['macros'], unix
    assert unix[0]['dependency_libraries'] == [{'package': 'base', 'libraries': ['library:LMainLibName']}], unix
    assert unix[1]['modules'] == ['Main'], unix
    windows = resolve('windows', '+alternate')['components']
    assert windows[0]['modules'] == ['Example', 'Windows'], windows
    assert windows[0]['cpp_options'] == ['-DALTERNATE'], windows
print('Cabal contexts: platform, flags, main-is, buildinfo and version macros verified')
