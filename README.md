# aihc-hsc2hs

A Haskell MVP replacement for `hsc2hs`, tied to Clang, that obtains target
information by inspecting object files. **The candidate must never execute
compiled input code**, whether natively, through an emulator, a WASI runtime,
or a JIT.

The Unlicense Cabal package exposes the `Hsc2hs` and `Hsc2hs.Object` libraries
and the `aihc-hsc2hs` executable. The MVP implements `const`, `size`, `alignment`,
`offset`, `type`, `peek`, `poke`, `ptr`, C preprocessor directives, and ordinary
and braced directive syntax. It reads ELF, Mach-O and COFF objects directly.
`const` currently accepts integer expressions of at most 64 bits; floating-point
and wider constant expressions receive an unsupported-value diagnostic.
**Full Stackage compatibility is not yet implemented or claimed.**

Unsupported active directives (`enum`, `const_str`, `let`, `def`, and custom
templates) fail explicitly. WebAssembly objects, companion C/header generation,
column pragmas and the complete upstream CLI are not implemented. The CLI
requires an explicit target triple and sysroot; include paths and package C
dependencies must also be supplied. Standard template macro overrides are
diagnosed rather than silently interpreted as built-in directives.

```sh
nix build .#aihc-hsc2hs
nix run .#aihc-hsc2hs -- --help
# Supply real Nix toolchain paths for your target:
result/bin/aihc-hsc2hs --target TRIPLE --sysroot SYSROOT --cc CLANG Input.hsc
nix build .#mvp-tests
```

The default Nix package is now the candidate. Both normal and `--cross-compile`
invocations only compile objects. The flag selects upstream cross-mode macro
handling and output pragmas, which differ from the native reference backend.
The IO driver imposes a configurable timeout (60 seconds by default), retains
compiler errors, and forwards warnings. Library callers can instead use pure
`prepare`, `decodeAnswers`, and `finish` with their own compiler service.

## Intended contract

- Generate C probes, compile them with Clang for the requested target, decode
  object-file data, and reconstruct Haskell source.
- Cover the relevant `.hsc` sources in Stackage in native and cross builds.
- Aim to support every Clang target for which Nix can supply the target sysroot
  and required package libraries. Object formats need explicit decoder support;
  having a Clang backend alone is not sufficient.
- Compare against upstream `hsc2hs` in native and `--cross-compile` modes.
  Native upstream failures are test-environment defects to fix, not an accepted
  compatibility baseline. Cross upstream failures are counted and diagnosed.
- Assert exact counts of candidate failures, divergences and upstream cross
  failures, separately for every target/mode. Count improvements require a
  reviewed baseline update, too.

Arbitrary custom hsc2hs templates can execute arbitrary C. A static object reader
cannot generally reproduce that behavior. The compatibility goal is to implement
the templates used by the corpus explicitly, including string extraction and
binding generators, without introducing an execution fallback. See
[architecture](docs/architecture.md).

## Nix outputs

```sh
# Complete source archives, discovered .hsc files, and an inventory
nix build .#stackage-hsc
cat result/manifest.json
cat result/hsc-files.txt

# Harness tests, real upstream native/cross smoke tests, and the full corpus
nix flake check -L

# Install/run the comparison harness
nix run .#comparison-runner -- --help

# Clang, LLVM tools, GHC, Cabal, upstream hsc2hs, Python, and nixfmt
nix develop
```

`stackage-hsc` is pinned to **LTS 24.58**, published September 7, 2026, using GHC
9.10.3. It downloads and inspects **all 3,442 listed package source archives**;
it does not select packages by a guessed dependency on hsc2hs. Each archive and
each expected `.hsc` file has a checked-in SHA-256 hash. The build asserts
**723 `.hsc` files in 166 packages**.

The output contains:

- `sources/`: complete unpacked sources, preserving headers and Cabal files.
- `hsc/`: a linked tree containing the discovered `.hsc` files.
- `manifest.json`: package/file IDs and content hashes.
- `hsc-files.txt`: the complete path inventory.

This inventory includes tests, examples and platform-specific modules. Files are
counted by package/path, not deduplicated by content. The snapshot YAML contains
3,405 packages; the Stackage page additionally lists 37 GHC-provided packages.
Both groups are included. Their sources contain 560 and 163 `.hsc` files,
respectively. Corpus members remain under their upstream licenses.

## Differential testing

[Testing](docs/testing.md) documents the command interface and Nix builder.
`lib.mkComparison` builds a comparison report and fails unless it exactly matches
a supplied baseline. It requires a real candidate executable, prepared per-case
build contexts, and an explicit target/header preflight command.

The harness records:

| Counter | Meaning |
|---|---|
| `candidate_failures` | Candidate exited unsuccessfully or did not create the module |
| `divergences` | Both succeeded, but module or companion C/header bytes differ |
| `reference_native_failures` | Native upstream failed; never accepted as a baseline |
| `reference_cross_failures` | Cross upstream failed, including missing output |
| `reference_cross_unsupported` | Upstream explicitly diagnosed an unsupported directive |
| `reference_cross_other_failures` | Other cross failures, retained separately for investigation |
| `setup_failures` / `tool_errors` | Preflight failures, missing executables, crashes or timeouts; never accepted |

Reports retain commands, diagnostics, output artifacts and diffs. Tools get
separate copies of the same context and identical relative source/output names.
The comparator does not erase Haskell whitespace or line pragmas. Stale output
files cannot turn a failed invocation into a pass.

No full-Stackage candidate baseline is claimed yet. Synthetic tool processes test
counter accounting and three upstream fixtures check native/cross behavior.
The MVP adds pure feature/decoder tests and eleven focused fixtures compared
byte-for-byte against both upstream modes, with an exact zero-failure baseline.
On Apple Silicon, an additional x86-64 cross-mode job uses the same Nix Apple SDK.
Full package comparisons need Cabal's actual
configuration, generated headers, native libraries and platform selection; the
corpus itself is not that build environment.

## Development sequence

1. Extend and harden the MVP parser, probe/reconstruction APIs and Clang driver.
2. Expand real ABI tests for ELF and COFF, and add a WebAssembly object reader.
   Keep answer records independent of target pointers and relocations.
3. Add enums, strings, companion files and corpus template families, with focused
   tests for every feature. Report unsupported cases explicitly.
4. Prepare Nix package contexts from the pinned snapshot, with genuine generated
   headers and target dependencies. Establish a zero-failure native oracle.
5. Wire candidate and reference into `lib.mkComparison`; check in measured
   per-target baselines and reduce candidate failure/divergence counts to zero.
6. Expand the target/sysroot matrix without executing candidate-generated code.

Do not convert the earlier static audit's 108 flagged files into an expected
cross-failure count: conditional compilation and component selection change
which constructs are active.
