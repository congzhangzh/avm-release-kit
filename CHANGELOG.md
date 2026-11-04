# Changelog

## Unreleased

### The SIMD gate covers AVX-512 (2026-11-04)

- `simd.sh` adds two paths: `avx2` (`AVM_SIMD_CAPS_MASK=0x1ff`) and, in CI,
  `sde`: the released avmenc under Intel SDE 10.13.1 posing as a Sapphire
  Rapids CPU (pinned in `sources.lock` by Intel's SHA-256; realtime speeds 9
  and 10). GitHub's x86 runners are a mixed pool (EPYC 7763 without
  AVX-512; EPYC 9V74 and 9V45 and Xeon 8370C with it), so SDE is what tests
  AVX-512 on every run.
- When the build has AVX-512 kernels, the gate proves that they ran: one
  encode, counted with AVX-512 allowed and twice masked, must differ by more
  than 10 times the run-to-run noise and 0.01% (natively with perf; under
  SDE with its `-mix` total). Checked on this kit's host (Zen 5) with
  feature-avm-rt's AVX-512 commit on top of 20261103.3: 42 of 42 encodes
  identical, and 0.18% fewer instructions with AVX-512. 20261103.3 itself
  has no AVX-512 kernels and passes as such.
- The proof counts with address space randomization off (`setarch -R`):
  with it on, the counts wandered by 30-40k in 2.3G natively and by 470k
  under SDE (the first CI run, an EPYC 7763), too close to a real AVX-512
  signal; without it, by about 1k. With AVX-512 allowed, the 4-way SAD build
  then counts 4.10M fewer instructions on the proof encode.
- The decoders too: each path's avmdec decodes the C stream of every
  vector to the C decoder's MD5, and a decode is counted for the AVX-512
  proof as well. Both counts use masks of the same length (`0xfff` and
  `0x1ff`), because the size of the environment moves the stack by a few
  thousand instructions. On the full AVX-512 group (feature-avm-rt
  8cb7d2b9f, bb0ffabc0, ac2611f6a, 99b4511a3 on 20261103.3): encoder
  −4.67M and decoder −573k instructions with AVX-512, while the two masked
  runs differed by 386 and 4.
- The bench's x86 rows carry no instruction counts: GitHub's x86 VMs say
  "The instructions:u event is not supported". The ARM64 rows have them.

### AVM 20261103.3: bit-exact C speed-ups in the encoder and decoder (2026-11-03)

Seven changes with one meaning: the same streams and decoded pictures,
fewer cycles. Each was checked byte for byte against the release before it,
and the group passes the SIMD gate (AVX2, the SSE2 baseline and plain C
encode the same bytes). Measured on a Zen 5 machine at 1440p, speed 10,
AVX-512 masked, against 20261031.2 (so including 20261103.1 and .2): the
encoder spends 7.5-9.1% fewer cycles, the decoder 4.0-11.8%.

- Realtime partition: the superblock motion estimate's projections sum
  rows along memory and match in 32-bit lanes (encoder).
- The sub-block mode-info pointers are set with the frame's invariants read
  once (encoder and decoder).
- Parity hiding without trellis has no branches on the coefficient levels
  (encoder).
- Motion field projection skips blocks that cannot project and reuses
  repeated projections (encoder and decoder).
- x86: the generic loop filter takes its length decision without a chain of
  masks, with 18 more SSE4.1 unit tests (encoder and decoder).
- Deblocking prefetches the next stripes of the vertical-edge pass, with gcc
  and clang (encoder and decoder).
- The coefficient cost has fewer branches on the levels and computes the
  high-range length inline (encoder).

The AVX-512 commit stays out until a gate can run AVX-512 code on every run.

### The benchmark counts instructions (2026-11-04)

- `bench.sh` runs each AVM encode and decode under `perf stat -e
  instructions:u` and reports billions of instructions next to fps, plus the
  CPU's SIMD level. GitHub's x86 runners are a mixed pool (EPYC 7763,
  9V74 and 9V45, Xeon Platinum 8370C have all run the bench job), so fps
  from two releases often come from different CPUs. Instruction counts
  repeat to about 0.01% for one binary on one dispatch path, so releases
  are compared on them, on runners of the same SIMD level, with a 0.5%
  threshold. The CI job installs perf on a best-effort basis; when perf
  can't count, the report says why.

### The SIMD gate (2026-11-03)

- `simd.sh` (CI job `simd`, which every release now waits for) builds avmenc
  twice from the pinned source: for x86_64 as released, and with
  `AVM_TARGET_CPU=generic`, plain C. It encodes every vector of `test.sh`
  three ways and compares the `.obu` files byte for byte: on the CPU's SIMD
  paths (AVX2 on CI's runners), on the SSE2 baseline
  (`AVM_SIMD_CAPS_MASK=0`), and in C. A SIMD kernel that returns anything
  but what its C version returns changes the encoder's decisions while the
  decoder still decodes the stream, so `test.sh` alone could not see it.
  `AVM_SIMD_CAPS_MASK=0` alone is not C on x86_64: rtcd binds 205
  functions to SSE2 at compile time (`cmake/rtcd.pl` requires mmx, sse and
  sse2 there), hence the generic build. AVM 20261103.2 and integration-avm
  with 606685e96 pass it: 28 of 28 identical.
- The clips and avmenc settings moved from `test.sh` to `build/vectors.sh`,
  so both gates encode the same vectors.

### AVM 20261103.2: the nonzero count kept in the cost loop (2026-11-03)

- `av2_cost_coeffs_txb` walked each transform block's scan a second time
  only to count its nonzero coefficients for the parity-hiding decision.
  The loops before it already test every coefficient for zero, so the
  count is now kept there. Encoder only; bit-exact streams (realtime
  speeds 9 and 10, good quality speed 6). The function takes 1.08-1.27x
  fewer cycles, 1.0-2.5% of the inter-frame cycles (measured on a Zen 5
  machine). The AVX-512 commit stays out, as in 20261103.1.

### AVM 20261103.1: the CDFs averaged in one vectorized pass (2026-11-03)

- `av2_avg_cdf_symbols` (once per superblock in row-MT encodes, once per
  frame in the decoder) builds a mask over `FRAME_CONTEXT` once and then
  averages in a single 16-bit loop that the compiler vectorizes. The result
  is exact for weights 3/1 and 7/1; other weights take the old path. It is
  plain C, so every target gets it. Bit-exact streams; the encoder spends
  1.8-4.1% fewer cycles on inter frames (measured on a Zen 5 machine).
- The pick leaves out feature-avm-rt's AVX-512 commit (run-time detection
  and 4-way SAD kernels). It stays out until a gate can run AVX-512 code: the
  CI x86 runners have none.

### emsdk 6.0.13 (2026-11-03)

- The wasm build uses `emscripten/emsdk:6.0.13`
  (`sha256:fb7864e3…`, Docker Hub's digest of the multi-arch index) instead
  of 6.0.12, in step with rdp-release-kit, whose web client links libavm.
  6.0.13 removes the `.bat`/`.ps1` launchers and `FS.filesystems`,
  deprecates `MEMORY64=2`, and stops copying every export into
  `wasmExports`. Neither kit nor the web client uses any of these. Closes #1.

### The thread-safety gate (2026-10-31)

AVM 20261031.1 coded the benchmark's 1440p motion clip differently on the
ARM runner than on x86 (2,712 against 2,719 kbps; the three releases before
agreed), and qemu-aarch64 made the x86 stream exactly: a data race, which
x86 hides more often. ThreadSanitizer found it on x86 (tile packing on
several threads updating two frame-wide counters; fixed in AVM).

- `tsan.sh`: avmenc from the pinned source with gcc's ThreadSanitizer
  encodes synthetic camera and screen clips on 2 and 4 threads (realtime
  speeds 7 to 10, 1 to 4 tiles, intraBC, good quality with lookahead); any
  report fails it, except one in `build/tsan.supp`: AVM's AVX2 MHCCP
  neighbour fetch reads 32 columns at a time past its region, at a tile edge
  into the next tile's pixels, and never uses those values (multi-threaded
  encodes give the one-thread stream).
- `kit.yml`: a `tsan` job, which the release waits for, and `tsan.sh` in
  shellcheck. The job sets `vm.mmap_rnd_bits=28`: gcc's TSan cannot map
  its shadow memory with the runner kernel's 32 random bits.

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
