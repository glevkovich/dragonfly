#!/usr/bin/env python3

"""Generate and validate dependency-cache manifests.

Usage:
    python3 tools/deps_cache_manifest.py generate --root BUILD_DIR --manifest FILE PATH [...]
    python3 tools/deps_cache_manifest.py validate --root BUILD_DIR --manifest FILE PATH [...]

The CI builder saves this manifest with its dependency cache. On an exact cache hit it
regenerates the manifest before CMake/Ninja; a mismatch means the restored tree is
discarded locally and that job cold-builds dependencies instead of failing repeatedly.
"""

import argparse
import concurrent.futures
import hashlib
import json
import os
import stat
import sys
from pathlib import Path


FORMAT = "deps-cache-manifest-v1"


def fail(message: str) -> None:
    print(f"deps-cache-manifest: {message}", file=sys.stderr)
    raise SystemExit(2)


def requested_path(root: Path, requested: str) -> Path:
    path = Path(requested)
    if path.is_absolute() or ".." in path.parts:
        fail(f"cached path must be a relative path below the root: {requested}")
    full_path = root / path
    if not os.path.lexists(full_path):
        fail(f"cached path is missing: {requested}")
    return full_path


def walk(path: Path):
    yield path
    if path.is_dir() and not path.is_symlink():
        with os.scandir(path) as entries:
            for entry in sorted(entries, key=lambda item: os.fsencode(item.name)):
                yield from walk(Path(entry.path))


def relative_path(root: Path, path: Path) -> str:
    return path.relative_to(root).as_posix()


def hash_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        while chunk := file.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def record_path(root: Path, path: Path, checksums: dict[Path, str]) -> dict[str, object]:
    metadata = path.lstat()
    record: dict[str, object] = {
        "path": relative_path(root, path),
        "mode": stat.S_IMODE(metadata.st_mode),
        "mtime_ns": metadata.st_mtime_ns,
    }

    if stat.S_ISREG(metadata.st_mode):
        record.update(type="file", size=metadata.st_size, sha256=checksums[path])
    elif stat.S_ISDIR(metadata.st_mode):
        record["type"] = "directory"
    elif stat.S_ISLNK(metadata.st_mode):
        record.update(type="symlink", target=os.readlink(path))
    else:
        fail(f"unsupported filesystem type at {record['path']}")
    return record


def manifest(root: Path, requested: list[str], workers: int) -> bytes:
    paths: list[Path] = []
    for item in requested:
        paths.extend(walk(requested_path(root, item)))

    paths.sort(key=lambda path: os.fsencode(relative_path(root, path)))
    regular_files = [path for path in paths if stat.S_ISREG(path.lstat().st_mode)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        checksums = dict(zip(regular_files, executor.map(hash_file, regular_files)))

    records = [record_path(root, path, checksums) for path in paths]
    lines = [FORMAT]
    lines.extend(json.dumps(record, separators=(",", ":"), sort_keys=True) for record in records)
    return ("\n".join(lines) + "\n").encode()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("generate", "validate"))
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--workers", type=int, default=min(os.cpu_count() or 1, 8))
    parser.add_argument("paths", nargs="+")
    arguments = parser.parse_args()
    if arguments.workers < 1:
        parser.error("--workers must be positive")
    return arguments


def main() -> None:
    arguments = parse_args()
    root = arguments.root.resolve()
    if not root.is_dir():
        fail(f"root is not a directory: {root}")

    contents = manifest(root, arguments.paths, arguments.workers)
    if arguments.command == "generate":
        arguments.manifest.write_bytes(contents)
        return

    if not arguments.manifest.is_file():
        fail(f"manifest is missing: {arguments.manifest}")
    if arguments.manifest.read_bytes() != contents:
        print(
            f"deps-cache-manifest: restored cache does not match {arguments.manifest}",
            file=sys.stderr,
        )
        raise SystemExit(1)


if __name__ == "__main__":
    main()
