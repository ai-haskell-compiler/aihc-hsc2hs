# Architecture and limits

## Pipeline

```text
.hsc + explicit generation settings
  -> pure parser / template lowering
  -> C probe sources + reconstruction plan
  -> Clang --target=... --sysroot=... -c (external process)
  -> target object bytes
  -> pure object decoder / answer validation
  -> pure Haskell reconstruction
  -> .hs and optional companion .c/.h artifacts
```

Clang is the only compiler backend. Its textual IR and assembly are not the
primary extraction interface. The candidate does not link or execute probes.
Do not invoke `lli`, an emulator, `wasmtime`, native probe executables, or
constant evaluators that execute compiled input code as a fallback.

The native **reference** hsc2hs invocation deliberately compiles and executes its
emitter. This oracle behavior is isolated from the candidate. Cross reference
invocations use `--cross-compile` and the same target compiler/context as the
candidate.

Suggested pure Haskell boundaries (design sketches, not existing exports):

```haskell
prepare :: GenerationConfig -> SourceName -> HscSource
        -> Either Diagnostic (ProbeSources, ReconstructionPlan)
decodeAnswers :: ObjectFormat -> ByteString
              -> Either Diagnostic Answers
finish :: ReconstructionPlan -> Answers
       -> Either Diagnostic GeneratedSources
```

Generation settings explicitly contain source names, target settings, includes,
definitions and template semantics. Discovery of tool binaries, sysroots and
headers belongs in the IO layer. Keep temporary host paths out of logical names.

## Answer records

Use a versioned, validated record with a magic value, query IDs, kinds, lengths
and payloads. Generate scalar and byte-array constant initializers that Clang can
evaluate using the target ABI. Encode integers into an explicit byte order;
record signedness and width instead of truncating to the host's integer type.
Do not use target pointers to refer between record fields. Handle zero-filled
sections and compiler retention rules explicitly.

Locate the record through the object format's section/symbol metadata, not
assumed file offsets or a blind search for magic bytes. ELF, Mach-O, COFF and
WebAssembly need separate container handling. Reject malformed, incomplete,
duplicate, unexpected or relocation-dependent answers. Test the decoder using
malformed bytes and multiple actual Clang targets.

A compiler version change should not silently alter decoded results. Pin the
Nix toolchain and sysroots; run additional toolchain-version checks before
widening supported versions. Object inspection avoids relying on LLVM textual
IR compatibility, but does not remove ABI/header/compiler behavior differences.

## Custom templates

The Stackage audit found 297 `#const_str` occurrences, 22 `#let` definitions and
3,139 custom directive calls. Those are lexical findings, not build failures.
Examples include bindings-DSL directives (`#ccall`, `#num`, `#field`), GTK's
`#gtk2hs_type`, ALSA accessor generators, and old alignment fallbacks.

Strings backed by compile-time byte arrays can be extracted. Corpus-specific
formatting and binding generators can be represented as pure reconstruction
rules plus explicit target queries. This is how compatibility should expand.

There is no general static solution for a template that reads a runtime file,
queries the environment, performs arbitrary IO, or computes output with an
arbitrary C program. Do not claim universality for such templates. Preserve the
ambitious corpus/target goal while keeping unsupported behavior explicit and
never escaping the no-execution rule.

A sysroot supplies a platform runtime and headers; it does not automatically
supply libgit2, GTK, ALSA or every other dependency. Some packages intentionally
only build on particular platforms. A successful target matrix needs applicable
components and the appropriate target library derivations as well as a sysroot.
