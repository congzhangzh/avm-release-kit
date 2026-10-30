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
(`./test.sh linux-x86_64 linux-aarch64 wasm`, plus speed measured on real
x86_64 and ARM machines), it is named `release-<YYYYMMDD>.<N>` on the fork,
`<N>` counting that day's picks from 1. `sources.lock` then pins it:

```
avm  20261030.1  git+https://github.com/congzhangzh/avm.git  <commit>
```

A fix never changes a release: it goes to the feature branch, the
integration is rebuilt, and a new pick follows (`.N+1`).

## What a release contains

`avm-<version>-<target>.tar.gz` for each target, each with its `.sha256`
and a `MANIFEST` inside. The version is the pick's name (`20261030.1`); a
build from a local checkout is `<version>-local` and is never published.

## What the consumer relies on

- The archive for a version never changes once published.
- `libavm.a` and the headers are from the commit the MANIFEST names, built
  with the options it lists; nothing else is linked in.
- Every target decodes the gate's vectors to the same pictures.

## Upstream

AVM upstream is AOMediaCodec/avm. Whether a change goes upstream, and how,
is decided per change by the owner (see the upstream ledger); the kit never
submits anything.
