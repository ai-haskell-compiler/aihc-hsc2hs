# aihc-hsc2hs

A planned Haskell replacement for `hsc2hs`, tied to Clang, that obtains target
information by inspecting object files. **The candidate must never execute
compiled input code**, whether natively, through an emulator, a WASI runtime,
or a JIT.

This repository starts with the reproducible corpus and differential-testing
infrastructure. **The replacement compiler is not implemented yet.** Passing
bootstrap checks verifies the harness and corpus, not candidate compatibility.

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

No full-Stackage candidate baseline is claimed yet. The bootstrap uses synthetic
tool processes to test counter accounting and three real upstream fixtures to
check native/cross behavior. Full package comparisons need Cabal's actual
configuration, generated headers, native libraries and platform selection; the
corpus itself is not that build environment.

## Development sequence

1. Implement the pure Haskell parser/probe/reconstruction interfaces and a
   compile-only Clang driver.
2. Define a versioned answer-record format and implement ELF, Mach-O, COFF and
   WebAssembly object readers. Avoid pointer relocations in answer records.
3. Implement numeric/layout directives, conditionals, strings and corpus template
   families. Report unsupported cases explicitly.
4. Prepare Nix package contexts from the pinned snapshot, with genuine generated
   headers and target dependencies. Establish a zero-failure native oracle.
5. Wire candidate and reference into `lib.mkComparison`; check in measured
   per-target baselines and reduce candidate failure/divergence counts to zero.
6. Expand the target/sysroot matrix without executing candidate-generated code.

Do not convert the earlier static audit's 108 flagged files into an expected
cross-failure count: conditional compilation and component selection change
which constructs are active.
