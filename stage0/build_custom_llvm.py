#!/usr/bin/env python3
"""Build and install the experimental Xbox 360 LLVM toolchain."""

import argparse
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path


def run(command: list[str]) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, check=True)



def files_equal(left: Path, right: Path) -> bool:
    try:
        if left.stat().st_size != right.stat().st_size:
            return False
    except FileNotFoundError:
        return False
    with left.open("rb") as left_file, right.open("rb") as right_file:
        while True:
            left_chunk = left_file.read(1024 * 1024)
            if left_chunk != right_file.read(1024 * 1024):
                return False
            if not left_chunk:
                return True


def sync_source(source: Path, destination: Path) -> None:
    """Mirror source without touching unchanged files used by Ninja."""
    destination.mkdir(parents=True, exist_ok=True)
    source_entries: set[Path] = set()
    for source_path in source.rglob("*"):
        relative = source_path.relative_to(source)
        source_entries.add(relative)
        destination_path = destination / relative
        if source_path.is_symlink():
            target = os.readlink(source_path)
            if destination_path.is_symlink() and os.readlink(destination_path) == target:
                continue
            if destination_path.is_dir() and not destination_path.is_symlink():
                shutil.rmtree(destination_path)
            else:
                destination_path.unlink(missing_ok=True)
            destination_path.parent.mkdir(parents=True, exist_ok=True)
            destination_path.symlink_to(target)
        elif source_path.is_dir():
            if destination_path.is_symlink() or (
                destination_path.exists() and not destination_path.is_dir()
            ):
                destination_path.unlink()
            destination_path.mkdir(parents=True, exist_ok=True)
        else:
            if destination_path.is_symlink() or destination_path.is_dir():
                if destination_path.is_dir() and not destination_path.is_symlink():
                    shutil.rmtree(destination_path)
                else:
                    destination_path.unlink()
            if not files_equal(source_path, destination_path):
                destination_path.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source_path, destination_path)
            elif stat.S_IMODE(source_path.stat().st_mode) != stat.S_IMODE(
                destination_path.stat().st_mode
            ):
                shutil.copymode(source_path, destination_path)

    for destination_path in sorted(
        destination.rglob("*"), key=lambda path: len(path.parts), reverse=True
    ):
        if destination_path.relative_to(destination) in source_entries:
            continue
        if destination_path.is_dir() and not destination_path.is_symlink():
            destination_path.rmdir()
        else:
            destination_path.unlink()


def default_cache() -> Path:
    cache_home = os.environ.get("XDG_CACHE_HOME")
    root = Path(cache_home) if cache_home else Path.home() / ".cache"
    return root / "buck2-rustc-bootstrap" / "xbox360-llvm"

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--jobs", type=int, required=True)
    parser.add_argument(
        "--cache",
        type=Path,
        default=default_cache(),
        help="persistent CMake/Ninja cache (default: %(default)s)",
    )
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")

    if sys.platform != "linux":
        raise SystemExit("the experimental source-built toolchain currently supports Linux hosts only")
    import fcntl

    source = args.source.resolve()
    output = args.output.resolve()
    cache = args.cache.expanduser().resolve()
    mirrored_source = cache / "source"
    build = cache / "build"
    install = cache / "install"
    cache.mkdir(parents=True, exist_ok=True)

    lock_file = (cache / "build.lock").open("w")
    fcntl.flock(lock_file, fcntl.LOCK_EX)
    sync_source(source, mirrored_source)

    run(
        [
            "cmake",
            "-S",
            str(mirrored_source / "llvm"),
            "-B",
            str(build),
            "-G",
            "Ninja",
            "-DCMAKE_BUILD_TYPE=Release",
            f"-DCMAKE_INSTALL_PREFIX={install}",
            "-DLLVM_ENABLE_PROJECTS=clang;lld",
            "-DLLVM_TARGETS_TO_BUILD=X86;PowerPC",
            "-DLLVM_ENABLE_ASSERTIONS=ON",
            "-DLLVM_INSTALL_UTILS=ON",
            "-DLLVM_INCLUDE_TESTS=OFF",
            "-DLLVM_INCLUDE_BENCHMARKS=OFF",
            "-DCLANG_INCLUDE_TESTS=OFF",
            "-DLLVM_ENABLE_ZLIB=OFF",
            "-DLLVM_ENABLE_ZSTD=OFF",
            "-DLLVM_ENABLE_LIBXML2=OFF",
            "-DLLVM_ENABLE_TERMINFO=OFF",
        ]
    )
    run(["cmake", "--build", str(build), "--target", "install", "--parallel", str(args.jobs)])
    (install / "link-type.txt").write_text("static\n", encoding="utf-8")

    required = [
        "FileCheck",
        "clang",
        "ld.lld",
        "llc",
        "llvm-ar",
        "llvm-config",
        "llvm-objcopy",
        "llvm-objdump",
    ]
    missing = [name for name in required if not (install / "bin" / name).is_file()]
    if missing:
        shutil.rmtree(install, ignore_errors=True)
        raise SystemExit("custom LLVM install is missing: " + ", ".join(missing))

    shutil.rmtree(output, ignore_errors=True)
    shutil.copytree(install, output / "install", copy_function=shutil.copy2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
