# Changelog

## Unreleased

### Release engineering: CI, rolling releases, Windows, macOS, benchmarks (2026-10-30)

The kit could build and test, but only by hand on one machine, for Linux and
wasm. It now does what rdp-release-kit does for the RDP projects, so its
consumers can download a tested build instead of trusting a local one.

- **CI and rolling releases** (`.github/workflows/kit.yml`): every push to
  main builds every target, runs the gate, and when everything passes
  publishes the GitHub release `<YYYYMMDD>.<N>`: the archives, their
  `.sha256`, `SHA256SUMS`, build provenance attestations and the benchmark
  report, with notes made from the archives' MANIFESTs
  (`build/release-notes.sh`). Releases are frozen as in rdp-release-kit: a
  draft first, then published and checked asset by asset; never replaced; a
  name never used twice (`build/publish-release.sh`, `build/release-tag.sh`,
  tested without a network by `test/publish.sh` against a fake `gh`).
  Pull requests build and test only; documentation changes build nothing.
- **Upstream watch** (`check-upstream.sh`, `.github/workflows/upstream.yml`):
  a daily issue when AVM's main has moved past the pinned commit (with how
  many commits the pin lacks), or a newer emsdk image, llvm-mingw or Debian
  image exists; the same two-week rule as rdp-release-kit.
- **Windows x86_64 and ARM64** (`build-windows.sh`): llvm-mingw 20261020
  (the release rdp-release-kit uses, pinned with its SHA-256) in a Debian 13
  container (pinned by digest), docker or podman, files owned by the
  caller, objects in `ccache-windows`. Static `.exe` files that need only
  Windows' own DLLs and the UCRT, checked at build time. ARM64 builds NEON
  in without run-time detection, because AVM detects ARM features on
  Windows only under MSVC. x86_64 decodes the gate's vectors under wine;
  ARM64 is built, not tested.
- **macOS arm64 and x86_64** (`build-macos.sh`): native Apple clang, macOS
  12 and newer, `AVM_TARGET_CPU` named explicitly (an Apple Silicon Mac
  building x86_64 would otherwise get the host's CPU). **Untested**: written
  on Linux; the `macos` CI job is its first run.
- **linux-aarch64 now builds with clang and lld** (`--target=aarch64-linux-gnu`,
  `build/toolchains/aarch64-linux-clang.cmake`) instead of
  `aarch64-linux-gnu-gcc`: one LLVM toolchain for every cross build (Linux
  ARM64, Windows, wasm). It still links the cross glibc and libgcc of the
  Debian/Ubuntu `gcc-aarch64-linux-gnu` packages. The gcc path is gone, since
  clang builds it and its decoder passes the gate under qemu.
- **Benchmarks** (`bench.sh`, `build/bench.py`): every release measures the
  Linux targets natively (x86_64 and ARM64 runners) in realtime mode against
  x264, libaom and SVT-AV1, on clips ffmpeg generates (scrolling code, a
  still desktop, testsrc2; 720p and 1440p), and ships `bench-<release>.md`
  and `.json`, comparing with the previous release. Informational: a release
  without one says "Benchmark not run: <why>".
- **Shared code** (`build/lib.sh`): the source, the CMake options, the
  packaging and the container helpers, for all build scripts and `test.sh`.
  `DIST=<dir>` builds elsewhere than `dist/`; `ENGINE_RUN_OPTS` adds options
  to every container run (CPU pinning); `SRC_avm` also takes a plain tree
  with a `SOURCE_COMMIT` file.
- **No local paths in an archive.** `avm.pc` named the build machine's
  install directory (`prefix=/home/…/dist/<target>`): it is relocatable now
  (`prefix=${pcfiledir}/../..`), so the unpacked archive works from any
  directory. The MANIFEST's options show `<kit>`, `<avm source>`, `<work>`
  instead of paths, and C/C++ objects are built with `-ffile-prefix-map`.
  nasm has no such option: the x86_64 assembly objects still name their
  source path (in CI, the runner's work directory).
- **test.sh**: Windows x86_64 under wine and macOS natively; a target that
  runs in a container decodes all vectors in one run of it; `VECTORS=<dir>`
  reuses the vectors of an earlier run; the wasm image is made when missing
  instead of being looked up among local images.

Found on the way: AVM upstream main at the pinned commit (edaf3ebc7ce3)
fails the gate's realtime vectors: avmenc's `--test-decode=fatal` stops on
the first keyframe at every realtime speed (`Invalid intrabc dv`). The
feature branch's fix ("Fix realtime (var-based partition) streams the
decoder rejects") passes. So the gate is red until `sources.lock` pins a
pick of the fork that carries it.

### First version (2026-10-29)

- `build.sh` for linux-x86_64, linux-aarch64 (cross, NEON) and wasm
  (Emscripten 6.0.12, the image rdp-release-kit pins, decoder only,
  `-pthread`); `test.sh` with the encoder/decoder agreement check at
  realtime speeds 6–9 and good quality, and decode conformance of every
  target against x86_64. AVM is pinned to upstream main until the realtime
  branch is published on the fork; local builds use `SRC_avm`.
