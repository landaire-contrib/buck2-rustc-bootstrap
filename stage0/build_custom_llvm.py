#!/usr/bin/env python3
"""Build and install the experimental Xbox 360 LLVM toolchain."""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def run(command: list[str]) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, check=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--jobs", type=int, required=True)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")

    if sys.platform != "linux":
        raise SystemExit("the experimental source-built toolchain currently supports Linux hosts only")

    source = args.source.resolve()
    output = args.output.resolve()
    build = output / "build"
    install = output / "install"
    output.mkdir(parents=True, exist_ok=True)

    run(
        [
            "cmake",
            "-S",
            str(source / "llvm"),
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
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
