# Changelog

## Unreleased

### AVM 20261119.4: cheaper realtime key frames at speed 10 and up (2026-11-19)

An encoder change, on its own; realtime output at speed 10 changes (inter
frames too, as SDP is a sequence switch), speed 9 and non-realtime encodes do
not, decoders not at all. At speed 10 and up, realtime key and intra-only
frames skip the smooth and Paeth intra modes (luma and chroma) and use the
reduced transform set, and the realtime sequence turns semi-decoupled
partitioning (SDP) off.

Measured by the AVM component developer at the FreeRDP shadow's settings
against the typing-fixed encoder, 40 streams at QP 100 and 140: total bytes
+0.01%, encoder instructions -4.1%, decoder instructions -3.4%, worst PSNR
-0.33 dB (one scrolling browser pane at QP 100). At QP 130 and 150 (the band
around Boss Cong's QP 140): typing and clock -1.5% bytes and -0.5 dB at
64 dB; one 1080p text scroll at QP 150 +9.2% bytes (with SDP on it would be
-0.3%). Kept as chosen: same bytes overall, a cheaper decode for every client.
Speed 9 and non-realtime byte-identical (6 of 6).

### AVM 20261119.3: typing no longer blurs a static block (2026-11-19)

A realtime encoder fix, on its own; realtime output changes from speed 7 up,
other encodes do not, decoders not at all. Since 2026-10-30 (AVM 20261103.1)
our realtime static-block shortcut searched a static block with reference 0's
NEARMV and GLOBALMV only, while `init_mode_skip_mask()` could already have
masked exactly those two (reference 0's predicted-MV SAD four times the best
reference's, which a neighbour's motion causes although the block is an
exact copy). Nothing was left but intra: on a 1440p typing session at QP 100
one 128x128 DC block took PSNR-Y from 65 to 43 dB, and the next 32 frames cost
about 50 times their usual bytes until the next refresh. The static block now
keeps those two modes searchable.

Measured by the AVM component developer at the FreeRDP shadow's settings (speed
10, 2 tile columns, 4 threads), 40 streams at QP 100 and 140: total bytes
-1.66%; the 300-frame desktop session at QP 100 -11.3% bytes (typing -58%)
and +1.09 dB, no typing frame below 55 dB (17 before); at QP 140 -0.6% and
+0.09 dB; encoder and decoder instructions -0.25% / -0.39%; no stream worse
than -0.02 dB. Decoded MD5 the same on 1 and 4 threads (80 of 80).

### AVM 20261119.2: the arm64 encoder hashes blocks with the CRC32C instructions (2026-11-19)

`av2_get_crc32c_value()` (the intraBC block hashes of screen content) uses
the Armv8 CRC32C instructions where the compiler targets them
(`__ARM_FEATURE_CRC32`, Apple clang's default), and the C version elsewhere;
x86 already had SSE4.2. The hash_test unit test now builds for NEON targets
too. Bitstreams unchanged.

Checked by the AVM component developer: 4823 cases (lengths 0 to 300 at 16
offsets, and large blocks) equal to the C version on qemu with and without
CRC and on an Apple M5; hash_test 16 of 16 on arm64. On the M5 the function
is 6.7 to 7 times faster on 128-byte blocks; on x86 the same function was
4.9% of a key frame even with SSE4.2. A full M5 encode comparison was not run.

### AVM 20261119.1: no read of another tile's mode info for the CDEF context (2026-11-19)

A data race fixed, on its own. With two or more tile columns and threads
(FreeRDP's server sends two), the CDEF strength context of a block at a
tile's left edge read the mode info grid of the tile to its left, which
another thread could be writing at that moment; ThreadSanitizer reported it
on such streams, also before today's releases. It could not change pixels:
the grid is cleared before any tile starts, and whatever block the read finds
starts left of the tile, so the inside-tile check rejected it in every case.
The lookup is now skipped there; the context is the same.

Checked by the AVM component developer: ThreadSanitizer on 11 threaded streams
at 2, 4 and 6 threads, 3 reports before and none after; decoded MD5 with row
multithreading unchanged in 192 runs; encoder output unchanged in 30
configurations (it calls the same function). Shared decoder and encoder code
(`av2/common/pred_common.c`).

### AVM 20261118.5: the encoder's key frame, less serial work (2026-11-18)

Three encoder-only changes, byte-identical output:

- The intraBC hash table is built on the worker threads (row and column
  bands), not on the main thread alone.
- The intraBC hash search looks up the frame's 4x4 and 8x8 block hashes
  instead of hashing those blocks again.
- The palette colour map cost derives each pixel's colour context and index
  only where the rate uses them, without building the full colour order;
  checked exhaustively against `av2_get_palette_color_index_context()`.

Measured by the AVM component developer at FreeRDP's server settings (speed
10, QP 100 and 140, 4 threads with row multithreading, 2 tile columns, 4
reference slots): encoder output byte-identical in 30 of 30 configurations
(1, 4 and 8 threads, good quality too); x86 instructions -2.9 to 4.1% on a
1440p key frame and -2.1 to 2.3% over 30 frames; the main thread's share of
a 4-thread key frame's CPU samples from 37.8% to 29.1%. Decoders unchanged.

### AVM 20261118.4: the sub-block mode info grid filled once, MV spans stored directly (2026-11-18)

Two bit-exact decoder changes in the parse, which is the critical path of a
threaded decode (half or more of each frame with row multithreading):

- The sub-block mode info grid is filled once per block geometry instead of
  cell by cell. A grid entry not yet set by a block of the current frame now
  points at its own (valid) element instead of NULL; no reader tests for
  NULL, so only a would-be NULL dereference on malformed input changes into a
  read of a valid element.
- A block's sub-block motion vectors are spanned with direct stores.

Measured by the AVM component developer on an Apple M5, 5 interleaved rounds
(75 of 80 faster): FreeRDP's two-tile screen streams +2.9 to 6.4% on one
thread and +1.7 to 2.1% at four threads with row multithreading, still
desktops +2.5 to 4.7% / +1.4 to 4.2%, camera +1.5% / +3.0%. Decoded MD5 the
same on 47 streams (x86 on 1 and 4 threads, arm64) and 53 with row
multithreading; encoder output unchanged.

### AVM 20261118.3: realtime screen content projects one reference combination for TMVP (2026-11-18)

An encoder default, on its own. At speed 9 and 10, screen content now
projects one reference frame combination for temporal motion vector
prediction, as camera content already did (reduced_ref_frame_mvs_mode 1).
Realtime screen streams change; decoders and every other setting do not.
FreeRDP's own option for it becomes redundant but stays harmless.

Measured by the AVM component developer at the FreeRDP shadow's real settings
(speed 10, 2 tile columns, 4 threads with row multithreading, reference
buffer 4), 18 clips (scrolling at 1 to 64 pixels per frame, a scrolling
window, typing, cursor, clocks, desktop), one point per clip:

- QP 140: bytes -0.76%, PSNR-Y +0.064 dB, overall +0.067 dB, decoder
  instructions -2.8% (17 of 18 clips fewer).
- QP 100 (the shadow's default): bytes -0.36%, +0.024 / +0.029 dB, decoder
  instructions -2.5% (all 18 fewer).
- The weakest clip, text scrolling 16 pixels per frame at 1440p: +1.8% bytes
  and -0.09 dB overall at QP 140, -0.14 dB at QP 100, within what one point
  scatters (about 0.4 dB). Still clips are byte-identical.
- On an Apple M5, today's client decodes these streams 1 to 2% faster than
  the old encoder's.

The benchmark (bench.sh) also measures decoding with row multithreading, as
the FreeRDP client decodes since today, in a column of its own.

### AVM 20261118.2: NEON deblocking two segments per call, and avmdec --row-mt (2026-11-18)

- Deblocking filters two adjacent horizontal-edge segments per call where
  the NEON kernel can take them (a new rtcd function,
  `avm_highbd_lpf_horizontal_generic_dual`: C, SSE4.1 as two singles, NEON).
  x86 keeps the single-segment walk. Measured by the AVM component developer on
  an Apple M5, one thread, 5 interleaved rounds: +3.8 to 4.1% on one-tile
  streams, +2.4 to 4.5% on FreeRDP's two-tile streams. Decoded pictures and
  encoder output unchanged.
- `avmdec --row-mt=1` switches on the decoder's row multithreading, which
  libavm keeps off by default; with one tile, `-t` alone runs one thread.
  Off unless asked, so nothing changes without the flag.

The CI now runs macOS arm64 in one job (build, decode test and the NEON
gate), as GitHub's macOS arm64 runners were too scarce for three, and the
release gate has a 30-minute timeout.

### SIMD gate on arm64: NEON against plain C (2026-11-18)

`simd.sh` runs on arm64 too (Linux aarch64 and Apple Silicon): the released
build, whose NEON kernels rtcd binds at compile time, against the generic
build, every vector's encode byte-compared and every decode MD5-compared; it
fails when no NEON kernel is bound. CI runs it on `ubuntu-24.04-arm` and
`macos-15`, both required for a release. First run on an Apple M5 at
20261106.1: 28/28, 54 NEON kernels bound.

### AVM 20261118.1: decoder bookkeeping, a quarter faster on screen content (2026-11-18)

Ten bit-exact changes with one meaning: the decoder walks less of the frame
for the same pictures. Every stream and decoded picture is unchanged; the
loop filter and motion field projection share code with the encoder, whose
streams are byte-identical too.

- Mark coded blocks, and initialize the transform-skip array, one row at a
  time.
- Deblocking stops its edge walk at the frame's right and bottom edges,
  tests the filter length first in its per-edge loops, and computes the edge
  thresholds once per qindex.
- The decoder skips the motion-compensation border copy for full-pel motion
  vectors inside the frame.
- Motion field projection skips bands whose motion field is already filled,
  takes a direct path when trajectories are off, and notes the other side's
  references in a table.
- The decoder reuses its partition-tree nodes per superblock instead of a
  free and calloc for every superblock.

Measured by the AVM component developer on an Apple M5 (the FreeRDP client's
target), decoder on one thread, FreeRDP-like realtime speed 9 streams with one
tile, 5 interleaved rounds against 20261106.1 (same tree as feature-avm-rt
4d8faad8f), without the last change: desktop 1440p 248.4 to 317.4 fps
(+27.8%), screen 1440p +25.7%, screen 1080p +23.1%, camera 1440p +7.2%. The
partition-tree change adds 0.3 to 3.1% on top. Checked: decoded MD5 the same
as plain C at 4d8faad8f on 47 streams (x86 on 1 and 4 threads, arm64), the
encoder byte-identical in 6 configurations, valgrind clean.

Tried and left out, all bit-exact: a NEON entropy decoder (1.7 to 3.3%
slower: most symbols are found at the first step, and NEON adds a fixed cost
to each), a NEON block copy (no gain: the copy is memory traffic), and an
arm64-only removal of the loop filter's prefetch (1 to 4.6% slower).

### AVM 20261106.1: a key frame the decoder can read, at speed 8 and up (2026-11-06)

A real bug fix, on its own. `av2_nonrd_use_partition` (the realtime partition
path, speed 8 and up) skipped the pseudo-coded marks for blocks outside the
frame that the decoder and the RD partition search both make. The encoder
read 0 where the decoder reads 2, accepted a block vector next to the right
or bottom edge, and wrote a key frame the decoder rejects with "Invalid
intrabc dv". With key frames off, a session that loses its first frame stays
black.

Encoder only: decoders and clients do not change. Streams from speed 8 and up
can differ from the last release where a frame edge is involved.

Measured by the FreeRDP session (commit 4d8faad8f on `feature-avm-rt`):
windows of 4 captured screens at 50 sizes, 328 runs at speed 9, 117 rejected
before and 0 after. Live, default page: 4 black of 10 connects before, 0 of 14
after; AV2 was confirmed in use on 3 of those 14, the rest were not read.

Not covered: `av2_rd_use_partition` has the same gap on its FIXED_PARTITION
and seg_skip paths. It is untouched and untested, and nothing here uses it at
speed 8 and up.

### AVM 20261104.2: decoder speed-ups (2026-11-04)

Five bit-exact changes with one meaning: the decoder does less work for the
same pictures. Most are in code the encoder shares, so it gets a little
faster too. Every stream and decoded picture is unchanged.

- Copy the first motion field entry when all of a block's entries are equal
  (`av2_copy_frame_mvs`).
- `span_submv()` reads the value once and spans both references in one
  pass (common and decoder).
- Motion field projection skips a side whose stored references cannot
  project. This is decided from the data the first projection of a start
  frame recorded, not from a conformance assumption; with the trajectory tool
  on, nothing is skipped.
- Motion field projection reads the frame geometry once per call.
- `avm_calloc()` gets zeroed memory from `calloc()` rather than `malloc()`
  plus `memset()`: the same block, size check, alignment and header, so
  `avm_free()` releases it as before. On Linux, fresh pages from `mmap` are
  not touched until they are used.

Measured by the AVM session, decoder, one thread, 30-frame 1440p speed 10
streams, against the AVX-512 release: 11.6% fewer instructions on screen
content and 4.7% fewer on camera content (cycles 6.3% and 2.5% fewer) for the
first four. With the fifth, peak memory falls from 388 to 327 MB at 1440p and
from 182 to 117 MB at 720p. That is resident memory on Linux, where pages
that `calloc()` takes fresh from `mmap` are never touched until used. A wasm
heap counts every allocated byte, so there it saves writes, not memory. The
encoder runs 0.4-0.7% fewer instructions.

Left out of the group on purpose: a patch that dropped a per-frame clear of
the sub-block motion grid. It was exact only for valid streams; on a
malformed stream (and FreeRDP decodes network input) a stale pointer could
replace a clean NULL crash.

### AVM 20261104.1: AVX-512 (2026-11-04)

Four changes with one meaning: AVX-512 kernels, picked at run time, with
the same streams and decoded pictures as before. The SIMD gate tests them on
every CI run, natively on runners whose CPU has AVX-512 and under Intel SDE
on the others, and proves that they ran by counting instructions with and
without them.

- Run-time AVX-512 detection (F, DQ, CD, BW and VL in CPUID leaf 7, and the
  OS saving the opmask and ZMM state in XCR0), `ENABLE_AVX512` (on by
  default), and 4-way high-bit-depth SAD kernels (encoder).
- An AVX-512 forward transform for the 64-point DCT sizes (encoder). It
  checks the size before it builds its 23 KB aligned stack frame, so other
  sizes go straight to AVX2. The kit's instruction counts caught the first
  version, which made every transform pay about 40 instructions for that
  frame.
- AVX-512 high-bit-depth convolutions, 2-D, x and y (common library:
  encoder and decoder).

Measured on a Zen 5 machine, 1440p camera, speed 10, the same binary with
AVX-512 on and masked: 1.8% fewer encoder and 0.9% fewer decoder
instructions, with cycles within noise. The kernels themselves run 1.1-2.6x
faster. `AVM_SIMD_CAPS_MASK=0x1ff` turns AVX-512 off.

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
