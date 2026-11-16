#!/usr/bin/env python3
"""
Deterministic .tzst (tar + Zstandard) packager for release archives.

Builds a Zstandard-compressed USTAR tarball of ``pkgdir`` in a way that is
byte-reproducible across runs and runners and compatible with standard
8 MiB-window Zstandard decoders (including Zig's std.compress.zstd and ghr):

* entries are emitted in sorted order;
* every entry has mtime ``SOURCE_DATE_EPOCH``;
* every entry has uid/gid 0 and empty uname/gname;
* file modes are normalized (executables and bin/* 0o755, other files 0o644,
  directories 0o755);
* Zstandard compression uses single-threaded level 19 with windowLog=23
  (8 MiB window).

Usage: pack.py [--root <arcname>] <pkgdir> <archive.tzst>

``SOURCE_DATE_EPOCH`` is read from the environment (decimal seconds since
the Unix epoch; defaults to 0 when invoked via ``zig build release``).
"""
from __future__ import annotations

import argparse
import io
import os
import subprocess
import sys
import tarfile


def _walk_sorted(root: str):
    """Yield ``(disk_path, rel_path)`` pairs under ``root`` (including ``root``
    itself as ``rel_path == ""``) in stable lexicographic order, directories
    before their contents."""
    yield root, ""
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        filenames.sort()
        rel_dir = os.path.relpath(dirpath, root)
        if rel_dir == ".":
            rel_dir = ""
        for name in dirnames:
            rel = f"{rel_dir}/{name}" if rel_dir else name
            yield os.path.join(dirpath, name), rel
        for name in filenames:
            rel = f"{rel_dir}/{name}" if rel_dir else name
            yield os.path.join(dirpath, name), rel


def _normalize(info: tarfile.TarInfo, mtime: int) -> tarfile.TarInfo:
    info.mtime = mtime
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    if info.isdir():
        info.mode = 0o755
    elif info.isfile():
        is_bin = "/bin/" in info.name or bool(info.mode & 0o111)
        info.mode = 0o755 if is_bin else 0o644
    return info


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="pack.py")
    parser.add_argument(
        "--root",
        default=None,
        help="Top-level archive directory name (defaults to basename of pkgdir)",
    )
    parser.add_argument("pkgdir")
    parser.add_argument("archive")
    args = parser.parse_args(argv[1:])

    sde = os.environ.get("SOURCE_DATE_EPOCH")
    if sde is None or sde == "":
        print("error: SOURCE_DATE_EPOCH env var is required", file=sys.stderr)
        return 2
    mtime = int(sde)

    root_name = args.root or os.path.basename(os.path.normpath(args.pkgdir))
    if not root_name or root_name in (".", ".."):
        print("error: invalid archive root name", file=sys.stderr)
        return 2

    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.USTAR_FORMAT) as tar:
        for disk_path, rel_path in _walk_sorted(args.pkgdir):
            arcname = f"{root_name}/{rel_path}" if rel_path else root_name
            info = tar.gettarinfo(disk_path, arcname=arcname)
            info = _normalize(info, mtime)
            if info.isfile():
                with open(disk_path, "rb") as fh:
                    tar.addfile(info, fh)
            else:
                tar.addfile(info)

    subprocess.run(
        [
            "zstd",
            "-q",
            "-19",
            "--zstd=windowLog=23",
            "--threads=1",
            "-f",
            "-o",
            args.archive,
        ],
        input=buf.getvalue(),
        check=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
