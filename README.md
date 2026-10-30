# avm-release-kit

Reproducible builds of AVM, the AV2 reference codec, for the platforms the
RDP clients and servers run on, with the tests that gate a release and a
realtime benchmark that rides along with it. The consumer is
[rdp-release-kit](https://github.com/congzhangzh/rdp-release-kit): its xrdp
packages link the encoder (realtime mode), its FreeRDP clients the decoder,
the web client the WebAssembly build. This is an unofficial community kit,
not affiliated with the Alliance for Open Media.

## What it builds

| Target | Script | Toolchain | SIMD | Tested by the gate (`test.sh`) |
|---|---|---|---|---|
| `linux-x86_64` | `build.sh` | host gcc | SSE2…AVX2, picked at run time | encodes the vectors (the reference), decodes them |
| `linux-aarch64` | `build.sh` | clang `--target=aarch64-linux-gnu` + lld, cross | NEON | decodes the vectors under `qemu-aarch64`; benchmarked natively in CI |
| `wasm` | `build.sh` | Emscripten 6.0.12, the image rdp-release-kit pins | none yet (scalar C) | decoder only; decodes the vectors under node |
| `windows-x86_64` | `build-windows.sh` | llvm-mingw (clang, lld, UCRT), in a container | SSE2…AVX2, picked at run time | decodes the vectors under wine |
| `windows-aarch64` | `build-windows.sh` | llvm-mingw, in a container | NEON (fixed at build time) | **built, not tested**: nothing here runs ARM64 Windows |
| `macos-arm64` | `build-macos.sh` | Apple clang, on a Mac | NEON | decodes the vectors natively (CI's `macos-15`) |
| `macos-x86_64` | `build-macos.sh` | Apple clang, on a Mac | SSE2…AVX2 | decodes the vectors natively (CI's `macos-15-intel`) |

Every archive holds `lib/libavm.a`, `include/avm/`, `lib/pkgconfig/avm.pc`
(relocatable: its prefix is `${pcfiledir}/../..`), `bin/avmenc` and
`bin/avmdec` (`.exe` on Windows; `avmdec.js`/`.wasm` for wasm) and a
`MANIFEST`: the source (URL and commit), the kit commit, the compiler, every
CMake option and the SHA-256 of each file.

Every build uses the same CMake options (`build/lib.sh`, `COMMON`) and
leaves out AVM's TensorFlow Lite dependency (`CONFIG_ML_PART_SPLIT=0`,
`CONFIG_DIP_EXT_PRUNING=0`): it serves only two encoder pruning heuristics
and brings a C++ dependency tree the consumers do not want.

Why these toolchains:

- **clang for every cross build.** One clang targets every architecture, so
  Linux ARM64, Windows (llvm-mingw) and WebAssembly (Emscripten) all build
  with LLVM. The Linux ARM64 build still links against the cross glibc and
  libgcc of Debian/Ubuntu's `gcc-aarch64-linux-gnu` packages: clang finds
  them in `/usr/aarch64-linux-gnu` and `/usr/lib/gcc-cross` itself
  (`build/toolchains/aarch64-linux-clang.cmake` says why no `--sysroot`).
  `CLANG=clang-18` picks another clang. The native x86_64 build stays on the
  host gcc.
- **Windows ARM64 has no run-time CPU detection.** AVM detects ARM features
  at run time on Windows only when built with MSVC; with mingw it does what
  AVM's own `arm64-mingw-gcc.cmake` does: NEON at build time, which every
  ARM64 Windows machine has.
- **The Windows `.exe` files need no DLL of their own**: libc++, libunwind
  and winpthreads are linked statically; `build-windows.sh` fails a build
  whose `.exe` imports anything but Windows' own DLLs and the UCRT.

### What is not built or not tested, and why

- **Windows ARM64 is built, not tested.** No CI runner or emulator here runs
  ARM64 Windows binaries (wine runs x86_64 only); the decode conformance of
  the same NEON code is covered by `linux-aarch64` and `macos-arm64`.
- **`build-macos.sh` has not run yet.** It was written on Linux, modelled on
  rdp-release-kit's; its first run is the `macos` CI job. Until that job is
  green, the macOS archives are unverified.
- **The encoder is exercised on linux-x86_64 only** (the vectors); the other
  targets' `avmenc` is built and packaged but only their decoder is checked.
- **wasm has no SIMD kernels yet** and no encoder.

## Use

```bash
./build.sh linux-x86_64 linux-aarch64 wasm    # dist/<target>/ and dist/avm-<version>-<target>.tar.gz
./build-windows.sh                            # windows-x86_64 and windows-aarch64 (docker or podman)
./build-macos.sh                              # on a Mac: macos-arm64 and/or macos-x86_64
./test.sh linux-x86_64 linux-aarch64 wasm windows-x86_64 windows-aarch64   # the release gate
./bench.sh --res 720p                         # the benchmark of this machine's native target
```

What the scripts need: CMake, Ninja, ccache and nasm; for `linux-aarch64`
clang, lld and `g++-aarch64-linux-gnu` (for its glibc and libgcc); docker or
podman for `wasm` and Windows; ffmpeg, `qemu-user` and
`libc6-arm64-cross`, `libstdc++6-arm64-cross` and `libgcc-s1-arm64-cross` for `test.sh`; ffmpeg (with libx264, libaom, libsvtav1)
and python3 for `bench.sh`.

Knobs shared by the scripts (`build/lib.sh`): `WORK=<dir>` (work trees,
sources, caches; default `~/.cache/avm-release-kit`), `DIST=<dir>` (default
`dist/`), `ENGINE=docker|podman`, `ENGINE_RUN_OPTS=<options>` for every
container run (e.g. `--cpuset-cpus=4-7`), `CMAKE_BUILD_PARALLEL_LEVEL=<n>`
(also passed into the containers).

### Local sources

`sources.lock` is the only input of a release. For the development loop,
`SRC_avm=<checkout>` builds a checkout as it is, uncommitted edits included,
or a plain tree with a `SOURCE_COMMIT` file (a `git archive` of a commit);
the version then ends in `-local` and the MANIFEST says
`OVERRIDE … not a release`.

```bash
SRC_avm=<your AVM checkout> ./build.sh linux-x86_64
```

The C and C++ objects carry no build paths (`-ffile-prefix-map`); nasm has
no such option, so the x86_64 assembly objects keep the absolute path of
their `.asm` source (in CI, the runner's work directory).

## The release gate (`test.sh`)

1. **Encoder ↔ decoder agreement.** The x86_64 `avmenc` encodes two synthetic
   640×360 clips (scrolling text; ffmpeg's `testsrc2` for camera-like motion)
   in realtime at speeds 6, 7, 8, 9, 10, at 9 also on 4 threads with row
   multi-threading and 2 tiles, and in good quality with lookahead (TIP,
   optical flow), each with `--test-decode=fatal`: every frame the encoder
   reconstructs must equal what its decoder makes of the stream.
2. **Cross-target conformance.** Every target decodes all fourteen vectors to the
   MD5s of the x86_64 decoder: `linux-aarch64` under `qemu-aarch64`, `wasm`
   under node in its build image, `windows-x86_64` under wine in its build
   image, `macos-*` natively. A SIMD kernel that is not bit-exact on its
   platform fails here. `VECTORS=<dir>` takes the vectors of an earlier run
   (how the macOS CI job gets them).

Note: upstream AVM main at the pinned commit fails step 1 in realtime mode
(`Invalid intrabc dv` on the first keyframe at every speed); the realtime
fixes on the fork's feature branch pass it. See CHANGELOG.md.

## The benchmark (`bench.sh`)

Every release carries `bench-<release>.md` and `.json`: each Linux target
measured on a machine that runs it natively (GitHub's `ubuntu-24.04` and
`ubuntu-24.04-arm` runners, the released binaries themselves), with AVM in
realtime mode (`--rt --cpu-used=9 --lag-in-frames=0 --end-usage=q --qp=160
--threads=4 --row-mt=1 --tile-columns=1`, `--tune-content=screen` for the
screen clips) next to x264 (ultrafast and veryfast, zerolatency), libaom
realtime (cpu-used 10) and SVT-AV1 (preset 10, rtc). It reports the
keyframe time, inter-frame mean and 95th percentile (avmenc's own per-frame
times), the fps they imply, kbps, PSNR-Y and decode fps with 4 threads, and
flags changes over 10% against the previous release.

The clips are generated by ffmpeg, so anyone can make them again: a page of
code scrolling, a still desktop where a counter and a cursor change, and
`testsrc2` motion, at 1280×720 and 2560×1440, 60 frames at 30 fps. The
benchmark is informational, not a gate: CI runners are noisy. A release
whose benchmark could not run still needs every target built and through
`test.sh`, and its notes say "Benchmark not run: <why>". Windows, macOS and
wasm are not benchmarked.

## CI (`.github/workflows/`)

| Workflow | When | What |
|---|---|---|
| `kit.yml` | push to main, pull request, by hand | builds every target, runs the gate, benchmarks; on main, publishes the release `<YYYYMMDD>.<N>` |
| `upstream.yml` | daily | `check-upstream.sh`: opens an issue when AVM's main has moved past the pin, or a newer emsdk image, llvm-mingw or Debian image exists |

## Layout

| Path | What |
|---|---|
| `sources.lock` | pinned sources: AVM, the emsdk image, llvm-mingw, the Debian image |
| `build.sh` | Linux and wasm targets |
| `build-windows.sh` | Windows targets, llvm-mingw in a container |
| `build-macos.sh` | macOS targets, natively (untested so far) |
| `test.sh` | the release gate |
| `bench.sh`, `build/bench.py` | the realtime benchmark and its report |
| `check-upstream.sh` | compares the pins with upstream |
| `build/lib.sh` | what the scripts share: the source, CMake options, packaging, containers |
| `build/toolchains/` | the clang toolchain files: Linux ARM64, Windows x86_64 and ARM64 |
| `build/Dockerfile.wasm`, `build/Dockerfile.windows` | the builder images, made once |
| `build/release-tag.sh`, `build/publish-release.sh`, `build/release-notes.sh` | naming, publishing and describing a release |
| `test/publish.sh` | tests the publishing logic against a fake `gh` |
| `docs/RELEASE.md` | how a build becomes a release, and what a release promises |
| `CHANGELOG.md` | what changed in the kit, and why |
