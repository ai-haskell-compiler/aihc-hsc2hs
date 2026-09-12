# Reproducing the Stackage measurement

The inventory is LTS 24.58: 723 `.hsc` files from 166 packages, discovered by
inspecting all 3,442 source archives. Every target/mode accounts for all 723
files. An inapplicable file is never a successful preprocessing result.

The asserted matrix is ARM64 Linux native, ARM64 macOS native, and ARM64 macOS
cross-compiling to x86-64 macOS. Windows-only modules remain visible as
inapplicable; this matrix does not establish Windows coverage. Linux cross
compilation is not yet a measured corpus target.

| Host and mode | Exact matches | Candidate failures | Divergences | Inapplicable | Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| ARM64 Linux, native | 493 | 123 | 0 | 107 | 723 |
| ARM64 macOS, native | 477 | 107 | 0 | 139 | 723 |
| ARM64 macOS → x86-64 macOS, cross | 475 | 109 | 0 | 139 | 723 |

All three measurements have zero divergences, setup failures, tool errors and
native-oracle failures. Matching upstream's carriage-return stripping and byte
encoding resolved 102 former divergences on each native target and 120 on the
cross target. The comparisons remain byte-exact; candidate output now matches
upstream without normalization in the harness.

Upstream cross mode fails on 77 files: 70 explicitly unsupported directives and
seven other compilation failures. The latter are two GD files with undeclared
`EOF`, four files with pointer-valued assembly probes (gtk, gtk3, hashable and
squeather), and hs-bibutils with undeclared C types. Diagnostics are retained;
these are not counted as unsupported directives. All 77 also fail in the
candidate, so there are no successful candidate outputs lacking an oracle result.
The two GD files account for the increase in candidate failures over native
macOS. Cross comparisons use the assembly backend for 554 files and the classic
backend for 30 enum-containing files, as described below.

```sh
nix build .#stackage-hsc       # Verify archive and .hsc hashes and inventory
nix build .#stackage-native    # Native corpus assertions on either ARM64 host
nix build .#stackage-cross     # x86-64 target from an ARM64 macOS host
nix build .#stackage-cross-report  # Deliberate measurement without acceptance
nix flake check -L            # Also runs unit, fixture and corpus assertions
```

`result/report/summary.json` contains the exact counters, per-file failure lists,
verified match IDs and explicit reasons for inapplicability.
`result/report/NNNNN/result.json` preserves commands and diagnostics; sibling
files preserve generated Haskell, companion files and byte-level differences.
`result/config.json` records the suite. `result/contexts/` retains the package
contexts and configuration logs. Source distributions retain their own licenses.

## Context construction

* `data/corpus-cabal.json` pins the 166 corpus packages' snapshot Cabal revisions and flag overrides.
  Thirty-two packages use a revised Cabal file. These files are fetched by Nix
  with verified hashes; the `.hsc` source bytes are unchanged.
* A small program linked against the pinned Cabal library resolves OS, CPU,
  compiler and flag conditionals, including test/benchmark main modules. The
  harness chooses the first applicable component for each file and records
  alternative components. This measures files, not every possible flag or
  component combination.
* This is a preprocessing context, not a complete Haskell dependency build.
  Version macros use the pinned package versions. Unsatisfied Haskell dependency
  bounds are recorded in the component description; unrelated test dependency
  bounds do not prevent library preprocessing.
* Configure packages run their genuine configure scripts and read the resulting
  `.buildinfo`. Declared dependency headers and in-place internal library include
  directories are supplied. Arbitrary Custom `Setup.hs` hooks are not executed;
  unresolved module mappings or required headers fail setup. No replacement
  headers are fabricated.
* Nix supplies Clang, explicit triples, SDK/libc headers, target GHC headers,
  package C libraries, pkg-config metadata and transitive linker search paths.
  The x86-64 Darwin dependency set uses the separately pinned 26.05 branch because
  unstable has dropped that platform. The discount binding uses discount 2.2.7,
  the compatible C API, rather than discount 3.
* `data/corpus-platforms.json` documents target restrictions absent from Nix's
  package platform metadata. Cabal component selection and Nix C-provider
  availability account for the remaining inapplicable files. These reasons are
  included in the assertions. An absent header is never automatically converted
  into inapplicability or an unsupported directive.

Both tools get separate copies of the same context and the same relative input
and output names. A preflight compiles upstream's generated C to check the target
headers. Only the native upstream oracle may execute C generated from an `.hsc`
file. Candidate native and cross modes always inspect objects without running
input-generated code. Cross upstream always uses `--cross-compile`. It also uses
`--via-asm` unless the source mentions an `enum` directive. The assembly backend
avoids thousands of compiler queries for large constant tables, but upstream
0.68.10 emits duplicate symbols for multi-value enums. A conservative source
scan selects the classic backend for those files, even if the enum is in an
inactive branch or comment. This decision is independent of candidate success.
The per-file backend assignments are themselves asserted in the baseline.
The feature fixtures compare against both backends, including a real x86-64
cross target. Neither backend executes target code.

## What counts as correct

A verified match requires both candidate and upstream to succeed and all produced
Haskell/companion artifacts to match byte for byte. We do not normalize whitespace,
comments, line pragmas, encoding or line endings. Consequently a divergence can
be a formatting difference rather than an incorrect ABI value. Successful
candidate output when upstream cross mode fails remains unverified.

Checked-in baselines assert every counter and per-file outcome, including
upstream's explicit unsupported-directive failures separately from other cross
failures. Setup failures, native-oracle failures, timeouts and crashes are hard
errors, even if someone puts their counts in a baseline. Both improvements and
regressions require explicit review; checks never regenerate expected results.

For a deliberate new measurement, build `stackage-native-report` or
`stackage-cross-report`. These immutable Nix reports retain their dependency
closures. Review the diagnostics before updating the corresponding file under
`data/baselines/`. The assertion derivation checks the existing report without
regenerating expectations. Report inputs exclude baseline files, so reviewing a
baseline does not change the measurement.

The lower-level `corpus-native-toolchain`, `corpus-cross-toolchain` and context
input outputs are also available for experiments with `tools/stackage.py` in
`nix develop`. Keep their result links as GC roots throughout such experiments:
unrooted target headers can otherwise disappear during a long sweep. The
accepted reports are built inside Nix, not collected that way.
