# avm-release-kit

Reproducible builds of AVM, the AV2 reference codec, for the platforms the
RDP clients and servers run on, with the tests that gate a release. The
consumer is [rdp-release-kit](https://github.com/congzhangzh/rdp-release-kit):
its xrdp packages link the encoder (realtime mode), its FreeRDP clients the
decoder, the web client the WebAssembly build. This is an unofficial
community kit, not affiliated with the Alliance for Open Media.

## What it builds

| Target | Toolchain | SIMD | Contents |
|---|---|---|---|
| `linux-x86_64` | host gcc (Ninja, ccache) | SSE2…AVX2, picked at run time | `libavm.a`, headers, `avm.pc`, `avmenc`, `avmdec` |
| `linux-aarch64` | `aarch64-linux-gnu-gcc` cross | NEON | the same |
| `wasm` | Emscripten 6.0.12, the image rdp-release-kit pins | none yet (scalar C) | decoder: `libavm.a`, headers, `avm.pc`, `avmdec.js`/`.wasm` for node |

Every build leaves out AVM's TensorFlow Lite dependency
(`CONFIG_ML_PART_SPLIT=0`, `CONFIG_DIP_EXT_PRUNING=0`): it serves only two
encoder pruning heuristics and brings a C++ dependency tree the consumers do
not want.

Not built yet: Windows (x86_64, ARM64) and macOS (arm64, x86_64). They need
the Windows and Mac rigs that rdp-release-kit uses.

## Use

```bash
./build.sh linux-x86_64 linux-aarch64 wasm   # dist/<target>/ and dist/avm-<version>-<target>.tar.gz
./test.sh  linux-x86_64 linux-aarch64 wasm   # the release gate, see below
```

Each archive carries a `MANIFEST`: the source (URL and commit), the kit
commit, the compiler, every CMake option and the SHA-256 of each file.

### Local sources

`sources.lock` is the only input of a release. For the development loop,
`SRC_avm=<checkout>` builds a checkout as it is, uncommitted edits included;
the version then ends in `-local` and the MANIFEST says
`OVERRIDE … not a release`.

```bash
SRC_avm=~/projects/avm-feature-rt ./build.sh linux-x86_64
```

## The release gate (`test.sh`)

1. **Encoder ↔ decoder agreement.** The x86_64 `avmenc` encodes two synthetic
   640×360 clips (scrolling text; ffmpeg's `testsrc2` for camera-like motion)
   in realtime at speeds 6, 7, 8, 9 and in good quality with lookahead (TIP,
   optical flow), each with `--test-decode=fatal`: every frame the encoder
   reconstructs must equal what its decoder makes of the stream.
2. **Cross-target conformance.** Every target decodes all ten vectors to the
   MD5s of the x86_64 decoder: `linux-aarch64` under `qemu-aarch64`, `wasm`
   under node in the build image. A SIMD kernel that is not bit-exact on its
   platform fails here.

Speed is not part of the gate: qemu and node say nothing reliable about it.
It is measured on real machines and noted in the release notes.

## Layout

| Path | What |
|---|---|
| `sources.lock` | pinned sources: AVM, the emsdk image |
| `build.sh` | builds the targets into `dist/` |
| `test.sh` | the release gate |
| `build/Dockerfile.wasm` | the emsdk image plus Ninja and ccache, made once |
| `docs/RELEASE.md` | how a build becomes a release, and what a release promises |
| `CHANGELOG.md` | what changed in the kit, and why |
