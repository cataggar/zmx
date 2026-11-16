#!/usr/bin/env bash
set -euo pipefail

version=0.17.1
case "${RUNNER_OS}-${RUNNER_ARCH}" in
  Linux-X64) target=x86_64-linux; digest=3581863e3cbcfd0fce0efc682ce7e9e93da96668a977791d356a26d2a7e9b17a ;;
  Linux-ARM64) target=aarch64-linux; digest=a1546d5646eb184437918d6635ca6b762a0e889eac09cef720ee7a1ed3fe7795 ;;
  macOS-X64) target=x86_64-macos; digest=9af07b20319fbd0c92ee46ad23e81d6a782b1aaea2cfb8dcbff35f1d2c7ddbb7 ;;
  macOS-ARM64) target=aarch64-macos; digest=75f1bc7a1e9852f17ec9a0c1895f767c4ec56d46bc8a834920eece1d0359dd8d ;;
  *) echo "Unsupported runner: ${RUNNER_OS}-${RUNNER_ARCH}" >&2; exit 1 ;;
esac
archive="zig-${target}-${version}.tar.xz"
mkdir -p .ci-zig
curl -fsSL "https://github.com/cataggar/zig/releases/download/v${version}/${archive}" -o ".ci-zig/${archive}"
actual="$(python3 - ".ci-zig/${archive}" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "rb") as archive:
    print(hashlib.file_digest(archive, "sha256").hexdigest())
PY
)"
[[ "$actual" == "$digest" ]] || { echo "Compiler SHA-256 mismatch" >&2; exit 1; }
tar -xf ".ci-zig/${archive}" -C .ci-zig
echo "$PWD/.ci-zig/zig-${target}-${version}" >> "$GITHUB_PATH"
".ci-zig/zig-${target}-${version}/zig" version
