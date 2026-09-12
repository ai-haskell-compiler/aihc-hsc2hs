# Nix comparison contract

`nix flake check` runs corpus integrity checks, harness unit tests, upstream mode
smoke tests, the Haskell library unit tests, and the MVP candidate comparisons.
On the measured ARM64 hosts it also runs the full-inventory corpus assertions
described in [corpus contexts](corpus-contexts.md). Passing these assertions means
coverage matches the reviewed baseline; it does not mean every file passes.

`nix build .#mvp-tests` retains per-case commands, diagnostics, artifacts and
diffs. `tests/mvp.py` declares eleven feature fixtures with exact zero failure
and divergence counts in native mode and both upstream cross backends
(classic and `--via-asm`): 42 comparisons. Darwin adds both backends for the
real x86-64 cross target using the Nix Apple SDK, for 70 comparisons total. All invocations share compiler, sysroot and language flags; the
candidate also receives explicit target arguments and the matching output mode.
Every case first compiles the real fixture header as a target preflight.

The unit suite covers each numeric/layout rendering rule, source parsing,
answer completeness and malformed objects. Independently constructed COFF and
little/big-endian ELF objects test decoding without relying on host byte order.
Native integration exercises the host format; the Darwin cross job additionally
exercises x86-64 Mach-O. These tests do not establish a Windows package/sysroot
matrix or full ELF ABI coverage.

When testing an uncommitted checkout with new files, use `nix flake check path:.`
and `nix build path:.#stackage-hsc` so Nix includes untracked source files.

## Configuring a suite

`tools/compare.py` consumes JSON with:

```json
{
  "candidate": ["/nix/store/.../bin/aihc-hsc2hs"],
  "reference": ["/nix/store/.../bin/hsc2hs"],
  "timeout": 120,
  "cases": [{
    "id": "example/native/x86_64-linux",
    "target": "x86_64-unknown-linux-gnu",
    "mode": "native",
    "context": "/nix/store/...-prepared-example",
    "source": "src/Example.hsc",
    "flags": ["--cc=/nix/store/.../bin/clang", "--cflag=--sysroot=/nix/store/..."],
    "preflight": ["/nix/store/.../bin/check-example-target-headers"]
  }]
}
```

Command arrays are executed directly, never through shell interpolation. The
runner appends `-o Result.hs SOURCE` to each command. It appends `--cross-compile`
only to the reference in cross mode. The candidate's design has no run-based
native mode: it always inspects target objects. `candidate_flags` and
`reference_flags` allow deliberate tool-specific CLI adapters. `env` is an
optional map at suite or case scope.

The MVP CLI accepts output, include, define, compiler and compiler-flag options.
It additionally requires `--target` and `--sysroot` in `candidate_flags`;
cross cases must pass `--cross-compile` there to match upstream output pragmas.
The eventual candidate CLI should accept the other common hsc2hs options used here,
including explicit Clang `--cc` and repeated `--cflag` / `--lflag` as appropriate.
Link flags may be relevant to reference execution, but the candidate never links
and runs probes. Keep codegen-affecting options identical.

A context is a Nix derivation containing the package source, generated Cabal
headers and any relevant configuration. `preflight` must check the actual target
compiler, sysroot, and package headers; it is run before either tool. Do not use
a dummy success command for real corpus tests. Supply genuine target settings
and dependencies; adding every archive's include directory to one global include
path would not reproduce the package build.

Native comparison requires a target executable runnable on the build host.
Cross comparisons use each declared Clang target with upstream's cross backend.
Some Stackage components require a Windows or Linux native host, so complete
native coverage requires multiple applicable platform jobs. A Darwin sysroot on
Linux is not a runnable native oracle.

## Nix builder

A downstream or future in-repository check can use:

```nix
aihc-hsc2hs.lib.mkComparison {
  inherit system;
  name = "stackage-hsc-x86_64-linux";
  config = {
    candidate = [ "${candidate}/bin/aihc-hsc2hs" ];
    reference = [ "${upstream}/bin/hsc2hs" ];
    cases = preparedCases;
  };
  expected = ./baselines/x86_64-linux.json;
  nativeBuildInputs = [ clang ];
}
```

Store paths in the config retain their Nix dependencies. The build produces a
report tree or fails on a baseline mismatch. Every case has a timeout. Missing
executables, signals, timeouts and preflight failures are never accepted, even
if someone writes their counts into the expected JSON. Native reference failure
is likewise a hard error.

The result contains exact aggregate and per-target/mode counters, ordered case
IDs and explicit inapplicable entries. Corpus reports additionally assert each
file’s failure categories and the exact list of verified matches. Expected files use exactly the same
schema as `summary.json`; missing/extra counters or changed case lists fail.
Only compare bytes when both tools succeed; a candidate failure is not also
counted as a divergence. Cross failures are partitioned into explicit unsupported
directives and other diagnostics. The latter are not automatically described as
language limitations.

To collect a baseline deliberately:

```sh
nix run .#comparison-runner -- --config suite.json --output report --report-only
# Review report/summary.json, per-case diagnostics, and diffs first.
# Then check in the reviewed summary as the expected baseline.
nix run .#comparison-runner -- --config suite.json --output checked-report \
  --expected baselines/target.json
```

Never generate and accept a new baseline inside the same Nix check. Candidate
failure/divergence counts should eventually both be zero. Upstream cross failure
counts may remain nonzero, with reviewed reasons. Counts are exact, not upper
bounds, so unexpected improvements also trigger review.

## Enforcing full corpus accounting

For a corpus suite, add:

```json
{
  "corpus": "/nix/store/...-stackage-hsc-lts-24.58/manifest.json",
  "matrix": [
    {"target": "x86_64-unknown-linux-gnu", "mode": "native"},
    {"target": "wasm32-wasi", "mode": "cross"}
  ],
  "inapplicable": []
}
```

Every case then also has `corpus_id`, matching its package-relative inventory ID.
Each matrix cell must account for every corpus file exactly once, either as a
case or as an explicit inapplicable record containing `corpus_id`, `target`,
`mode` and `reason`. Inapplicability must come from component/platform selection,
not a missing feature in either hsc2hs implementation. These entries are asserted
in the baseline and cannot silently disappear. To claim full native corpus
coverage, also ensure the union of applicable native jobs covers every relevant
file and review any file that is inapplicable everywhere.

## Updating Stackage

`data/stackage.json` pins all listed source archives and the exact `.hsc`
inventory by SHA-256. `data/lts-24.58.yaml` preserves the snapshot definition,
including Cabal revision metadata. Updating requires downloading all package
archives for the new snapshot, enumerating them, and reviewing the inventory and
hash changes. Cabal revisions do not change the `.hsc` bytes in Hackage tarballs,
but they matter when constructing package build contexts.

The initial manifest was generated from the September 12, 2026 full archive scan
of https://www.stackage.org/lts-24.58. It intentionally includes the 37 compiler
packages listed by that page, rather than every package in global compiler hints.
