#!/usr/bin/env python3
"""Prepare and measure pinned corpus contexts; setup defects are never passes."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from functools import lru_cache
import json
import os
import platform
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import threading

import compare


def verify_sources(inventory, contexts):
    for item in inventory['files']:
        path = contexts / item['id']
        if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() != item['sha256']:
            raise ValueError('Prepared source differs from pinned corpus: ' + item['id'])


def cross_backend(source):
    # Upstream's assembly backend is far faster for large constant tables,
    # but emits duplicate symbols for multi-value enum directives. Conservatively
    # retain the ordinary backend whenever enum syntax appears, even in comments
    # or inactive branches. Selection is independent of candidate success.
    return 'classic' if re.search(rb'#[ \t]*(?:\{\s*)?enum\b', source) else 'asm'


def run(argv, cwd, env=None, timeout=120):
    return compare.invoke(list(map(str, argv)), cwd, os.environ.copy() if env is None else env, timeout)


def preflight(spec):
    context = json.loads(Path(spec).read_text())
    if context.get('setup_error'):
        print(context['setup_error'], file=sys.stderr)
        return 1
    ref = run([context['reference'], '--no-compile', '--cc=' + context['clang'],
               *['--cflag=' + f for f in context['cflags']], '-o', 'Preflight.hs', context['source']], '.')
    if ref['exit'] != 0:
        print(json.dumps(ref), file=sys.stderr)
        return 1
    result = run([context['clang'], *context['cflags'], '-c', 'Preflight_hsc_make.c', '-o', 'Preflight.o'], '.')
    print(result['stdout'], end='')
    print(result['stderr'], end='', file=sys.stderr)
    return 0 if result['exit'] == 0 else 1


def propagated(paths):
    result = []
    todo = list(paths)
    while todo:
        path = todo.pop(0)
        if path in result:
            continue
        result.append(path)
        for name in ['propagated-build-inputs', 'propagated-native-build-inputs']:
            file = Path(path) / 'nix-support' / name
            if file.exists():
                todo.extend(file.read_text().split())
    return result


@lru_cache(maxsize=None)
def link_directories(closure):
    # Some providers (notably PulseAudio) keep private DT_NEEDED libraries
    # below lib/. The target sysroot prevents ld from finding those by itself.
    return sorted({str(library.parent) for path in Path(closure).read_text().splitlines()
                   for library in (Path(path) / 'lib').rglob('*.so*')})


def pkgconfig_options(expressions, cwd, env):
    names = []
    for expression in expressions:
        name, _, bounds = expression.partition(' ')
        names.append(name)
        if not bounds:
            continue
        failures = []
        for alternative in bounds.split('||'):
            terms = [name + ' ' + re.sub(r'([<>=]+)(?=[0-9])', r'\1 ', t.strip()) for t in alternative.split('&&')]
            result = run(['pkg-config', '--print-errors', '--exists', *terms], cwd, env)
            if result['exit'] == 0:
                break
            failures.append(result['stderr'])
        else:
            return dict(exit=1, stdout='', stderr='Version/dependency check failed for ' + expression + ':\n' + '\n'.join(failures))
    return run(['pkg-config', '--cflags', '--libs', *names], cwd, env)


def main():
    preliminary = argparse.ArgumentParser(add_help=False)
    preliminary.add_argument('--toolchain', type=Path)
    selected, _ = preliminary.parse_known_args()
    defaults = json.loads(selected.toolchain.read_text()) if selected.toolchain else {}
    p = argparse.ArgumentParser(parents=[preliminary])
    p.set_defaults(**defaults)
    for key in ['corpus', 'inputs', 'info', 'candidate', 'reference', 'clang', 'sysroot', 'target', 'arch', 'output']:
        p.add_argument('--' + key, required=key not in defaults)
    p.add_argument('--configure-clang', default=defaults.get('configure_clang'))
    p.add_argument('--abi-flag', dest='abi_flags', action='append', default=defaults.get('abi_flags', []))
    p.add_argument('--os', default=defaults.get('os', 'osx'))
    p.add_argument('--mode', choices=['native', 'cross'], required=True)
    p.add_argument('--workers', type=int, default=6)
    p.add_argument('--timeout', type=int, default=1800)
    p.add_argument('--ghc-libdir', required='ghc_libdir' not in defaults)
    p.add_argument('--build-triple', default=defaults.get('build_triple', 'arm64-apple-darwin' if sys.platform == 'darwin' else 'aarch64-unknown-linux-gnu'))
    p.add_argument('--report-only', action='store_true')
    p.add_argument('--expected', type=Path)
    args = p.parse_args()
    root = Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=True)
    corpus = Path(args.corpus)
    inputs = json.loads(Path(args.inputs).read_text())
    inventory = json.loads((corpus / 'manifest.json').read_text())
    platform_limits = json.loads((Path(__file__).resolve().parents[1] / 'data/corpus-platforms.json').read_text())
    versions = root / 'versions.txt'
    versions.write_text('\n'.join(p.name for p in (corpus / 'sources').iterdir()) + '\n')
    entries = {p['package']: p for p in inputs}
    package_versions = {re.sub(r'-[0-9][^-]*$', '', x.name): x.name for x in (corpus / 'sources').iterdir()}
    cache, lock = {}, threading.Lock()
    def description(package):
        with lock:
            if package in cache:
                return cache[package]
        pin = entries.get(package)
        source = corpus / 'sources' / package
        file = pin['cabal'] if pin else next(source.glob('*.cabal'))
        flags = [('+' if value else '-') + flag for flag, value in (pin or {}).get('flags', {}).items()]
        result = run([args.info, args.arch, args.os, file, versions, *flags], source)
        if result['exit'] != 0:
            raise ValueError(json.dumps(result))
        desc = json.loads(result['stdout'])
        with lock:
            cache[package] = desc
        return desc
    def exported_headers(component, context):
        dirs = []
        for dependency in component.get('dependency_libraries', []):
            name = dependency['package']
            if name not in package_versions:
                continue
            pkg = package_versions[name]
            desc = description(pkg)
            for lib in desc['components']:
                if lib['component'] not in dependency['libraries'] or not lib['buildable']:
                    continue
                # Cabal's in-place internal libraries expose their include directories.
                if pkg == context.name:
                    dirs.extend('-I' + d for d in lib['include_dirs'])
                exports = lib.get('install_includes', [])
                if not exports:
                    continue
                include = context / '.aihc-context' / 'deps' / pkg
                include.mkdir(parents=True, exist_ok=True)
                for header in exports:
                    candidates = [base / pkg / d / header for base in [root / 'contexts', corpus / 'sources'] for d in (lib['include_dirs'] or ['.'])]
                    actual = next((f for f in candidates if f.is_file()), None)
                    if actual:
                        dest = include / header
                        dest.parent.mkdir(parents=True, exist_ok=True)
                        if not dest.exists():
                            dest.symlink_to(actual)
                dirs.append('-I' + str(include.relative_to(context)))
        return dirs
    ghc_headers = [str(x) for x in Path(args.ghc_libdir).glob('lib/*/*/include')]
    ghc_headers += [str(x) for x in Path(args.ghc_libdir).glob('lib/*/include')]
    ghc_headers += [str(x) for x in Path(args.ghc_libdir).glob('include')]
    for conf in Path(args.ghc_libdir).glob('lib/package.conf.d/*.conf'):
        text = conf.read_text().replace('${pkgroot}', str(conf.parent.parent))
        match = re.search(r'^include-dirs:(.*(?:\n[ \t]+.*)*)', text, re.MULTILINE)
        if match:
            ghc_headers.extend(shlex.split(match[1]))
    ghc_headers = list(dict.fromkeys(ghc_headers))
    target_flags = ['--target=' + args.target, '--sysroot=' + args.sysroot] + args.abi_flags
    platform_flags = ['-D__GLASGOW_HASKELL__=910', '-D' + ('darwin' if sys.platform == 'darwin' else 'linux') + '_BUILD_OS=1', '-D' + ('aarch64' if platform.machine() in ('aarch64', 'arm64') else platform.machine()) + '_BUILD_ARCH=1',
                      '-D' + ('darwin' if args.os == 'osx' else args.os) + '_HOST_OS=1', '-D' + args.arch + '_HOST_ARCH=1']
    def prepare_package(pin):
        package = pin['package']
        files = [f for f in inventory['files'] if f['package'] == package]
        if args.os in platform_limits.get(package, {}):
            return [], [dict(corpus_id=f['id'], target=args.target, mode=args.mode,
                             reason=platform_limits[package][args.os]) for f in files]
        if not pin['available']:
            return [], [dict(corpus_id=f['id'], target=args.target, mode=args.mode,
                             reason='Nixpkgs declares the package or a required C provider unavailable on the selected target') for f in files]
        context = root / 'contexts' / package
        shutil.copytree(corpus / 'sources' / package, context, symlinks=True)
        for file in context.rglob('*'):
            if not file.is_symlink():
                file.chmod(file.stat().st_mode | 0o200)
        context.chmod(context.stat().st_mode | 0o700)
        shutil.copyfile(pin['cabal'], context / pin['file'])
        support = context / '.aihc-context'
        support.mkdir()
        setup_error = None
        try:
            desc = description(package)
        except Exception as exc:
            desc = dict(build_type='Unknown', components=[])
            setup_error = 'Cabal context resolution failed: ' + str(exc)
        (support / 'description.json').write_text(json.dumps(desc, indent=2))
        provider_paths = propagated(pin['paths'])
        system_flags = ['-I' + p + '/include' for p in provider_paths if (Path(p) / 'include').is_dir()]
        system_flags += ['-I' + p for p in ghc_headers]
        lib_flags = ['-L' + p + '/lib' for p in pin['libraries'] if (Path(p) / 'lib').is_dir()]
        if pin.get('link_closure') and args.os == 'linux':
            lib_flags += ['-Wl,-rpath-link,' + p for p in link_directories(pin['link_closure'])]
        env = os.environ.copy()
        pc_dirs = [str(Path(p) / d) for p in provider_paths for d in ['lib/pkgconfig', 'share/pkgconfig'] if (Path(p) / d).is_dir()]
        env['PKG_CONFIG_LIBDIR'] = os.pathsep.join(pc_dirs)
        env['PKG_CONFIG_PATH'] = ''
        if desc['build_type'] == 'Configure':
            include_dirs = sorted({d for c in desc['components'] if c['buildable'] for d in c['include_dirs']})
            env.update(CC=args.configure_clang or args.clang, CFLAGS=shlex.join(target_flags + system_flags + ['-I' + d for d in include_dirs]),
                       CPPFLAGS=shlex.join(target_flags + system_flags + ['-I' + d for d in include_dirs]), LDFLAGS=shlex.join(target_flags + lib_flags))
            argv = ['sh', './configure', '--host=' + args.target, '--build=' + args.build_triple]
            result = run(argv, context, env, timeout=args.timeout)
            (support / 'configure.json').write_text(json.dumps(result, indent=2))
            if result['exit'] != 0:
                setup_error = 'Package configure failed; see .aihc-context/configure.json'
            else:
                flags = [('+' if v else '-') + k for k, v in pin['flags'].items()]
                updated = run([args.info, args.arch, args.os, context / pin['file'], versions, *flags], context)
                if updated['exit'] != 0:
                    setup_error = 'Generated Cabal buildinfo failed: ' + updated['stderr']
                else:
                    desc = json.loads(updated['stdout'])
                    with lock:
                        cache[package] = desc
                    (support / 'description.json').write_text(json.dumps(desc, indent=2))
        cases, omitted = [], []
        for index, item in enumerate(files):
            relative = item['id'][len(package)+1:]
            components = [c for c in desc['components'] if c['buildable'] and
                          any(os.path.normpath(d + '/' + m + '.hsc') == relative for d in (c['source_dirs'] or ['.']) for m in c['modules'])]
            if not components and desc['build_type'] not in ['Custom', 'Unknown']:
                omitted.append(dict(corpus_id=item['id'], target=args.target, mode=args.mode,
                                    reason='Not selected by any buildable Cabal component for this target and the pinned snapshot flags'))
                continue
            component = components[0] if components else dict(component='unresolved', cc_options=[], cpp_options=[], include_dirs=[], libraries=[], library_dirs=[], frameworks=[], pkgconfig=[], macros='', dependencies=[])
            error = setup_error or (None if components else 'Custom package module mapping requires its Setup hooks')
            flags = target_flags + platform_flags + component['cc_options'] + component['cpp_options']
            flags += ['-I' + d for d in component['include_dirs']] + system_flags
            flags += exported_headers(component, context)
            macro = support / (str(index) + '.h')
            macro.write_text(component['macros'])
            flags += ['-I.aihc-context', '-include', str(macro.relative_to(context))]
            links = target_flags + lib_flags + ['-L' + d for d in component['library_dirs']] + ['-l' + l for l in component['libraries']]
            links += [f for framework in component['frameworks'] for f in ['-framework', framework]]
            pkgconfig = component['pkgconfig'][:]
            if pin['file'] in ['hasql.cabal', 'postgresql-libpq.cabal']:
                pkgconfig.append('libpq')
            if pin['file'] == 'mysql.cabal':
                pkgconfig.append('mysqlclient')
            # Ruby exports a versioned .pc on Nix, while this binding requests
            # its unversioned alias. Resolve the alias to the actual provider.
            if pin['file'] == 'hruby.cabal':
                rubies = [f.stem for d in pc_dirs for f in Path(d).glob('ruby-*.pc')]
                if len(rubies) == 1:
                    pkgconfig = [rubies[0] if x == 'ruby' else x for x in pkgconfig]
            if pkgconfig:
                result = pkgconfig_options(pkgconfig, context, env)
                if result['exit'] != 0:
                    error = 'pkg-config failed: ' + result['stderr']
                else:
                    options = shlex.split(result['stdout'])
                    flags += [o for o in options if not o.startswith(('-l', '-L', '-Wl,'))]
                    links += [o for o in options if o.startswith(('-l', '-L', '-Wl,'))]
            if args.os == 'linux':
                links += ['-Wl,-rpath,' + f[2:] for f in links if f.startswith('-L')]
            spec = dict(source=relative, clang=args.clang, reference=args.reference, cflags=flags, setup_error=error,
                        component=component['component'], alternative_components=[c['component'] for c in components[1:]])
            spec_file = support / (str(index) + '.json')
            spec_file.write_text(json.dumps(spec, indent=2))
            backend = cross_backend((context / relative).read_bytes()) if args.mode == 'cross' else 'native'
            cases.append(dict(id=item['id'] + '/' + args.mode, corpus_id=item['id'], target=args.target, mode=args.mode,
                              reference_backend=backend,
                              source=relative, context=str(context), flags=['--cc=' + args.clang] + ['--cflag=' + f for f in flags],
                              candidate_flags=['--target=' + args.target, '--sysroot=' + args.sysroot] + (['--cross-compile'] if args.mode == 'cross' else []),
                              reference_flags=['--lflag=' + f for f in links] + (['--via-asm'] if backend == 'asm' else []),
                              preflight=[sys.executable, str(Path(__file__).resolve()), 'preflight', str(spec_file.relative_to(context))]))
        print(f'Prepared {package}: {len(cases)} cases, {len(omitted)} inapplicable' + ('; ' + setup_error if setup_error else ''), flush=True)
        return cases, omitted
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        prepared = list(pool.map(prepare_package, inputs))
    # Resolve generated exported headers after every dependency has configured.
    for pin in inputs:
        context = root / 'contexts' / pin['package']
        if context.exists():
            desc = json.loads((context / '.aihc-context/description.json').read_text())
            for component in desc['components']:
                if component['buildable']:
                    exported_headers(component, context)
    config = dict(candidate=[args.candidate], reference=[args.reference], corpus=str(corpus / 'manifest.json'),
                  env={'LC_ALL': 'C.UTF-8'},
                  matrix=[dict(target=args.target, mode=args.mode)], workers=args.workers, timeout=args.timeout,
                  cases=[c for cases, _ in prepared for c in cases], inapplicable=[c for _, omitted in prepared for c in omitted])
    verify_sources(inventory, root / 'contexts')
    (root / 'config.json').write_text(json.dumps(config, indent=2))
    summary = compare.run_suite(config, root / 'report')
    print(json.dumps(summary['counts'], indent=2), flush=True)
    if not args.report_only:
        if not args.expected:
            raise ValueError('--expected is required outside report-only measurement')
        compare.assert_expected(summary, json.loads(args.expected.read_text()))


if __name__ == '__main__':
    if len(sys.argv) == 3 and sys.argv[1] == 'preflight':
        sys.exit(preflight(sys.argv[2]))
    main()
