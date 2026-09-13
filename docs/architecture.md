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

The MVP public API has these pure boundaries:

```haskell
prepare :: FilePath -> String -> Either Diagnostic (String, Plan)
prepareWithStyle :: OutputStyle -> FilePath -> String
                 -> Either Diagnostic (String, Plan)
decodeAnswers :: ByteString -> Either String (Map Int Answer)
finish :: Plan -> Map Int Answer -> Either Diagnostic String
generate :: Config -> FilePath -> String -> IO (Either Diagnostic String)
generateBytes :: Config -> FilePath -> ByteString
              -> IO (Either Diagnostic ByteString)
```

`Config` contains a `Target`, Clang executable, compiler flags, timeout, and
upstream output style. `NativeStyle` hoists C preprocessor setup like the native
oracle; `CrossStyle` keeps its sequential setup and different output pragmas.
Neither style executes compiled code. `Plan` is opaque; parsed tokens and
decoded answers are exposed for library use. These interfaces are experimental.

The executable uses `generateBytes` and binary file IO. The parser removes every
carriage return before tokenization, including isolated CR bytes and CRLF in C
continuations, matching upstream. Other source bytes are passed through the
probe without locale decoding. Native output preserves those bytes; cross output
encodes each byte-valued character as UTF-8, matching the pinned upstream cross
oracle under the corpus's `C.UTF-8` locale. This intentionally reproduces
upstream's re-encoding of non-ASCII source text. It does not claim equivalence to
upstream under every possible output locale. Candidate byte IO is locale-independent.

The existing `String` API continues to accept decoded characters and return
characters; its C probes use explicit UTF-8. Use the byte API for file-compatible
preprocessing, including source that is not valid UTF-8.

Generation settings explicitly contain source names, target settings, includes,
definitions and template semantics. Discovery of tool binaries, sysroots and
headers belongs in the IO layer. Keep temporary host paths out of logical names.

## Answer records

Most directives own a single query ID. `#enum` owns one presence marker plus one
constant query per enumerated name, and `#const_str` owns a length query plus a
fixed number of byte chunks, so plan IDs are threaded through the token list
rather than assigned one per token.

The MVP uses fixed 24-byte records: four magic/version bytes (`HSC`, version 1),
a four-byte little-endian query ID, one kind byte, one negative flag, six reserved
zero bytes, and an eight-byte little-endian value. Kind zero records mark active
source fragments/branches; kind one records carry query answers. ID zero is a
required sentinel. The reconstruction plan checks missing and unexpected IDs.
Records live in `aihc_ans` (ELF/COFF) or `__aihc_ans` (Mach-O).

`#const_str` reuses that record shape rather than extending it. Eight string
bytes are laid out directly in one record's little-endian value field, so a
string costs one length query plus 32 chunk records and no new record kind. The
probe names the directive argument as a macro once and clamps every index to a
byte the string certainly has, keeping each read inside a constant expression
that Clang folds:

```c
#define AIHC_BYTE(x,k) ((unsigned char)((x)[(k) < AIHC_LEN(x) ? (k) : 0]))
```

This works for any string the target compiler can evaluate at compile time:
literals, concatenations, macros and named constant arrays. An argument that is
only known at run time (`getenv("HOME")`, a `char *` variable) is rejected by a
static assertion instead of being answered with garbage, as is a string longer
than the 256-byte probe capacity. Upstream answers those by running the emitter;
there is no static equivalent, and the candidate never gains one. The escaping
itself is a pure function of the extracted bytes and reproduces
`template-hsc.h`'s `hsc_const_str`, including its decimal escapes and the `\&`
separator before a following digit. Its output is always ASCII, so it does not
interact with output encoding.
Generate scalar and byte-array constant initializers that Clang can
evaluate using the target ABI. Encode integers into an explicit byte order;
record signedness and width instead of truncating to the host's integer type.
Do not use target pointers to refer between record fields. Handle zero-filled
sections and compiler retention rules explicitly.

The MVP locates records through section metadata, not
assumed file offsets or a blind search for magic bytes. ELF, Mach-O, COFF and
WebAssembly need separate container handling (WebAssembly remains unimplemented).
Reject malformed, incomplete,
duplicate, unexpected or relocation-dependent answers. Test the decoder using
malformed bytes and multiple actual Clang targets.

A compiler version change should not silently alter decoded results. Pin the
Nix toolchain and sysroots; run additional toolchain-version checks before
widening supported versions. Object inspection avoids relying on LLVM textual
IR compatibility, but does not remove ABI/header/compiler behavior differences.

## Custom templates

The Stackage audit found 297 `#const_str` occurrences, 22 `#let` definitions and
3,139 custom directive calls. `#const_str` is now implemented for
compile-time-constant strings (see above); the rest remain open. Those are lexical findings, not build failures.
Examples include bindings-DSL directives (`#ccall`, `#num`, `#field`), GTK's
`#gtk2hs_type`, ALSA accessor generators, and old alignment fallbacks.

Corpus-specific
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
