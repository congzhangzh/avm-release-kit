# Release process

How a commit of AVM becomes a release of this kit, and what rdp-release-kit
may rely on. The kit is the one place that builds libavm for the RDP
projects; consumers download its archives and check their SHA-256, they do
not compile AVM themselves.

## Where the source comes from

AVM work happens on the fork, in branches with the usual roles:

| Branch | Role | Rule |
|---|---|---|
| `feature-avm-rt` | feature: realtime fixes, the realtime tool set, NEON and WASM SIMD kernels | the source of truth for this work; fixes land here |
| one branch per upstream topic | for_clean_mr | only if upstream accepts the change (see the upstream policy below) |
| `integration-avm` | for_integration: upstream main + the feature branches, rebuilt with `heads rebuild` | never the source of an upstream PR |
| `release-<YYYYMMDD>.<N>` | release: a ripe integration commit, picked and frozen | never moved, never deleted while a consumer pins it |

A release is **picked**, not cut: once an integration commit passes the gate
(`./test.sh linux-x86_64 linux-aarch64 wasm windows-x86_64 windows-aarch64`,
and the macOS builds decoding the same vectors in CI; plus speed measured on
real x86_64 and ARM machines), it is named `release-<YYYYMMDD>.<N>` on the fork,
`<N>` counting that day's picks from 1. `sources.lock` then pins it:

```
avm  20261030.1  git+https://github.com/congzhangzh/avm.git  <commit>
```

A fix never changes a release: it goes to the feature branch, the
integration is rebuilt, and a new pick follows (`.N+1`).

Two names, two things: `release-<YYYYMMDD>.<N>` is a pick of AVM on the
fork (the source); the kit's own GitHub release `<YYYYMMDD>.<N>` (below) is
a build of the kit, whose archives carry the AVM version they were built
from in their names.

## Releases of the kit

The kit is rolling, like rdp-release-kit: every push to main that changes a
build (`kit.yml`; a push that changes only docs, the README or the upstream
check builds nothing) runs every job, and when all targets pass, publishes
the GitHub release `<YYYYMMDD>.<N>`, by its UTC date and that day's number,
made GitHub's latest. A pull request only builds and tests; a run started by
hand from main releases like a push.

| Job | Runner | What | Holds the release back |
|---|---|---|---|
| `scripts` | ubuntu-24.04 | shellcheck, `test/publish.sh` (the publishing logic, fake `gh`) | yes |
| `linux` | ubuntu-24.04 | `build.sh` per target | yes |
| `windows` | ubuntu-24.04 | `build-windows.sh` per architecture | yes |
| `macos` | macos-15, macos-15-intel | `build-macos.sh` per architecture | yes |
| `test` | ubuntu-24.04 | `test.sh` for the Linux, wasm and Windows targets | yes |
| `macos-test` | macos-15, macos-15-intel | the same vectors decoded natively | yes |
| `bench` | ubuntu-24.04, ubuntu-24.04-arm | `bench.sh` on the Linux targets | **no**: informational |
| `release` | ubuntu-24.04 | names, describes and publishes | — |

**Frozen.** A published name always means the same files
(`build/publish-release.sh`, as rdp-release-kit's "Frozen releases"): a
release is made as a draft with every file, then published, then checked
asset by asset against the SHA-256 of what was given; an existing release is
never replaced or added to; a tag left without its release is never reused.
The release's key, `AVM <version> <commit> (kit <commit>)`, is a marker in
its notes, so a second run of one commit finds its release and publishes
nothing (`build/release-tag.sh`).

## What a release contains

- `avm-<version>-<target>.tar.gz` for each target, each with its `.sha256`
  and a `MANIFEST` inside. The version is the AVM pin's (`20261030.1` for a
  pick, `upstream` while upstream main is pinned); a build from a local
  checkout is `<version>-local` and is never published.
- `bench-<release>.md` and `bench-<release>.json`: the benchmark (README,
  "The benchmark"), or a report that says why it did not run.
- `SHA256SUMS` over all of them, and GitHub's build provenance attestation
  of each (`gh attestation verify <file> -R <repository>`).
- The notes (`build/release-notes.sh`): a row per target from its MANIFEST
  (file, compiler, how it was tested), the source and the CMake options, the
  benchmark's summary table or "Benchmark not run: <why>", and a link to
  CHANGELOG.md at the kit commit.

**Without a benchmark.** The benchmark needs runners that may be busy or
gone (the ARM64 one above all) and timings that vary; it never holds a
release back. A release always needs every target built and through the
gate; when the bench job fails or leaves no results, the report and the
notes say "Benchmark not run: <why>", and when only one runner measured,
which one did.

## What the consumer relies on

- The archive for a version never changes once published.
- `libavm.a` and the headers are from the commit the MANIFEST names, built
  with the options it lists; nothing else is linked in.
- Every target decodes the gate's vectors to the same pictures, except
  `windows-aarch64`, which is built and not run (README, "What is not built
  or not tested").
- The benchmark is a measurement on a shared CI runner, not a promise.

## Keeping pins fresh

The daily `upstream` workflow runs `check-upstream.sh` and opens one issue
per pin that upstream has moved past: AVM's main (one issue per pinned
commit, whose body says how many upstream commits the pin lacks), the emsdk
image (to bump together with rdp-release-kit, whose web client links
libavm), llvm-mingw and the Debian image. It closes an issue once
`sources.lock` pins something else, and fails every day once an issue is
two weeks old without being done or labelled `deferred` with a reason.

## Upstream

AVM upstream is AOMediaCodec/avm. Whether a change goes upstream, and how,
is decided per change by the owner (see the upstream ledger); the kit never
submits anything.
