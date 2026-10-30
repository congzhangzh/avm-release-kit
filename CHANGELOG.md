# Changelog

## Unreleased

- First version of the kit (2026-10-29): `build.sh` for linux-x86_64,
  linux-aarch64 (cross, NEON) and wasm (Emscripten 6.0.12, the image
  rdp-release-kit pins, decoder only, `-pthread`); `test.sh` with the
  encoder/decoder agreement check at realtime speeds 6–9 and good quality,
  and decode conformance of every target against x86_64. AVM is pinned to
  upstream main until the realtime branch is published on the fork; local
  builds use `SRC_avm`.
