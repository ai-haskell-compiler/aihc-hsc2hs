# aihc-hsc2hs

Build a Haskell hsc2hs replacement using Clang as the target C compiler and
object-file inspection as the source of target information.

- Never execute code compiled from an input .hsc file in the candidate pipeline.
  No emulator, WASI runtime, JIT, linking-and-running fallback, or native probe.
  The native upstream hsc2hs test oracle is the deliberate exception.
- Keep parsing, probe generation, object decoding and Haskell reconstruction
  pure; isolate Clang invocation and filesystem access.
- Test through Nix. `nix flake check` exercises the harness; `nix build
  .#stackage-hsc` materializes and verifies the complete pinned corpus.
- Compare the same source and build context with upstream in native and cross
  modes. Assert exact candidate failure, divergence and upstream cross failure
  counts. Improvements require explicit baseline updates, just like regressions.
- Never equate an absent header, missing sysroot, timeout or tool crash with a
  genuinely unsupported cross-compilation directive. Preserve diagnostics.
- Do not remove difficult files, fabricate headers, skip cases silently, or
  regenerate expected counts automatically to make checks pass.
- Targets must carry explicit Clang triples, Nix-provided sysroots, ABI flags and
  package C dependencies. A sysroot alone does not supply every external library.
- Report implemented coverage honestly. Arbitrary executable C template code is
  not generally reducible to static object data. Diagnose unsupported templates;
  extend explicit template support without executing compiled code.
- Source distributions retained by Nix carry their own licenses. Do not copy
  upstream source into this repository without preserving its license.
- Use Conventional Commits for commit messages and pull request titles.
- Write new and updated prose in ASD-STE100 Simplified Technical English.
