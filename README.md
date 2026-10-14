# limn-lunasvg-natives

The SVG renderer behind the [Limn toolkit](https://github.com/limn-toolkit/limn-toolkit):
[lunasvg](https://github.com/sammycage/lunasvg) and the plutovg it draws with, compiled together
with Limn's JNI shim into one library per platform, **versioned with lunasvg rather than with the
toolkit**. A Limn release re-uploads no native byte, and an application's cache keeps these jars
across every toolkit upgrade that names the same payload version. Why lunasvg, and what the toolkit
does with it, is ADR 066 in limn-toolkit.

One artifact, `io.github.limn-toolkit:limn-lunasvg-natives`, seven jars:

| Jar | Carries | Who names it |
| --- | --- | --- |
| the main jar | the licences and notice of lunasvg and plutovg | the toolkit's backend |
| `natives-<os>-<arch>` ×6 | that platform's `liblimnsvg`: lunasvg, plutovg and the shim in one file, a few hundred kilobytes | the toolkit's backend, all six, as it names LWJGL's natives |

An application adds nothing: depending on the toolkit's backend brings all of it. One that ships to
fewer platforms may exclude the classifiers it does not need, as it may LWJGL's.

Targets: `linux-x86_64`, `linux-aarch64`, `macos-x86_64`, `macos-aarch64`, `windows-x86_64`,
`windows-aarch64`.

## What is inside, and what is not

- **lunasvg and plutovg, unmodified,** from the pinned source archive in
  `scripts/build-lunasvg.sh` (version and SHA-256), built for release (`NDEBUG`: an assertion is an
  abort, and damaged files reach them). MIT; their licences travel in every jar.
- **The shim,** `src/main/cpp/limn_svg.cpp`, Apache 2.0: open a document from bytes, read its size,
  set an attribute of an element by id, draw it into straight RGBA, close it, register a font.
  Every call takes one process-wide lock, and no C++ exception crosses into Java.
- **System fonts are looked up** for SVG text, beside the fonts the toolkit registers.
- **No path and no address is ever given to lunasvg:** the toolkit parses and sanitizes every SVG
  in Java first and reads whatever a file refers to itself.
- **On Linux** the C++ runtime is inside the library and nothing needs a glibc newer than 2.28; **on
  Windows** the DLL imports Windows and nothing else; **on macOS** each slice needs macOS 11. The
  build script refuses a library that breaks any of these.

## Building one locally

```bash
./scripts/build-lunasvg.sh        # this JVM's architecture; on macOS both slices
./gradlew test                    # the JNI tests, against the slice built here
./scripts/fuzz.sh                 # 6,000 damaged copies of the seeds; fails on a crash or a hang
./scripts/rehearse-consumer.sh    # publish to build/repo and resolve it as a consumer would
```

A C and C++ compiler and a JDK (for `jni.h`) are what it needs. A Linux library built on a current
distribution needs a newer glibc than the payload promises and is refused: build in
`quay.io/pypa/manylinux_2_28_$(uname -m)`, as the workflows do. On Windows, build from MSYS2's
CLANG64 or CLANGARM64 shell.

## Releasing

See [RELEASING.md](RELEASING.md). In one line: bump `versions.properties` and push to `main`.
