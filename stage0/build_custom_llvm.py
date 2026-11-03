#!/usr/bin/env python3
"""Build and install the Xbox 360 LLVM toolchain.

The CMake build tree persists outside buck-out so that a build after a change
of the LLVM sources rebuilds only what changed. Its location is keyed by the
build configuration and the host tools, not by the sources: the sources are
mirrored into it without touching unchanged files. Every run installs into the
action's own fresh output directory.
"""

import argparse
import hashlib
import json
import os
import platform
import shutil
import stat
import subprocess
import sys
import time
from pathlib import Path
from typing import IO

WINDOWS = os.name == "nt"
EXE_SUFFIX = ".exe" if WINDOWS else ""

if WINDOWS:
    import msvcrt
else:
    import fcntl


def try_lock(file: IO[str]) -> bool:
    """Takes an exclusive lock of `file` if no other process holds it."""
    try:
        if WINDOWS:
            msvcrt.locking(file.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    return True


def lock(file: IO[str]) -> None:
    """Takes an exclusive lock of `file`, waiting for other processes."""
    if not WINDOWS:
        fcntl.flock(file, fcntl.LOCK_EX)
        return
    while not try_lock(file):
        time.sleep(1)


def run(command: list[str], env: dict[str, str]) -> None:
    print("+", " ".join(command), flush=True)
    subprocess.run(command, check=True, env=env)


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
                # A fresh modification time: archives carry the commit time,
                # which can be older than the objects Ninja built before.
                shutil.copyfile(source_path, destination_path)
                shutil.copymode(source_path, destination_path)
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


def find_program(name: str) -> Path:
    path = shutil.which(name)
    if path is None:
        raise SystemExit(f"{name} not found on PATH")
    return Path(path).resolve()


def version(program: Path) -> str:
    return subprocess.check_output([program, "--version"], text=True)


def file_digest(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def compiler_file(compiler: Path, option: str, name: str) -> Path | None:
    """The file that `compiler -print-<option>=name` names, or `name` on PATH."""
    output = subprocess.check_output([compiler, f"-print-{option}={name}"], text=True).strip()
    path = Path(output) if os.path.isabs(output) else shutil.which(output)
    if path is None or not Path(path).is_file():
        return None
    return Path(path).resolve()


def host_tool_digests(cc: Path, cxx: Path) -> dict[str, str]:
    """Content digests of the host C/C++ toolchain files that the build uses.

    That toolchain is an undeclared input of the action; its digests key the
    build tree so that an update in place does not reuse stale objects.
    """
    if WINDOWS:
        # cl.exe, and the link.exe and lib.exe beside it.
        files = {name: cc.parent / f"{name}.exe" for name in ["cl", "link", "lib"]}
        return {name: f"{path}:{file_digest(path)}" for name, path in files.items()}

    files = {
        "cc": cc,
        "cxx": cxx,
        "cc1": compiler_file(cc, "prog-name", "cc1"),
        "cc1plus": compiler_file(cxx, "prog-name", "cc1plus"),
        "ld": compiler_file(cxx, "prog-name", "ld"),
        "libstdc++": compiler_file(cxx, "file-name", "libstdc++.so"),
    }
    for name in ["ar", "ranlib"]:
        path = shutil.which(name)
        files[name] = Path(path).resolve() if path else None
    return {
        name: f"{path}:{file_digest(path)}" if path else "absent"
        for name, path in files.items()
    }


# The LLVM target of the host, for which the compiler builds build scripts,
# procedural macros and its own standard library.
HOST_TARGETS = {
    "AMD64": "X86",
    "x86_64": "X86",
    "arm64": "AArch64",
    "aarch64": "AArch64",
}


def cmake_arguments(cc: Path, cxx: Path) -> list[str]:
    host_target = HOST_TARGETS[platform.machine()]
    arguments = [
        "-G",
        "Ninja",
        f"-DCMAKE_C_COMPILER={cc.as_posix()}",
        f"-DCMAKE_CXX_COMPILER={cxx.as_posix()}",
        f"-DPython3_EXECUTABLE={Path(sys.executable).as_posix()}",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DLLVM_ENABLE_PROJECTS=clang;lld",
        f"-DLLVM_TARGETS_TO_BUILD={host_target};PowerPC",
        "-DLLVM_ENABLE_ASSERTIONS=ON",
        "-DLLVM_INSTALL_UTILS=ON",
        "-DLLVM_INCLUDE_TESTS=OFF",
        "-DLLVM_INCLUDE_BENCHMARKS=OFF",
        "-DCLANG_INCLUDE_TESTS=OFF",
        "-DLLVM_ENABLE_ZLIB=OFF",
        "-DLLVM_ENABLE_ZSTD=OFF",
        "-DLLVM_ENABLE_LIBXML2=OFF",
        "-DLLVM_ENABLE_TERMINFO=OFF",
        # Linking the static tools takes several GB each.
        "-DLLVM_PARALLEL_LINK_JOBS=2",
    ]
    if sys.platform == "darwin":
        # The deployment target of rustc for aarch64-apple-darwin.
        arguments.append("-DCMAKE_OSX_DEPLOYMENT_TARGET=11.0")
    if WINDOWS:
        # The DIA SDK would add an absolute Visual Studio path to the
        # libraries that link LLVM.
        arguments.append("-DLLVM_ENABLE_DIA_SDK=OFF")
    return arguments


def configuration_key(
    args: argparse.Namespace, cc: Path, cxx: Path, arguments: list[str]
) -> str:
    identity = {
        "arguments": arguments,
        "cmake": version(args.cmake),
        "ninja": version(args.ninja),
        "host_tools": host_tool_digests(cc, cxx),
        "python": sys.version,
    }
    # cl.exe has no --version; its digest identifies it.
    if not WINDOWS:
        identity["cc"] = version(cc)
        identity["cxx"] = version(cxx)
    encoded = json.dumps(identity, sort_keys=True).encode()
    return hashlib.sha256(encoded).hexdigest()[:24]


def evict(cache: Path, keep: Path) -> None:
    """Remove build trees of other configurations that no build is using."""
    for entry in cache.iterdir():
        if entry == keep or entry.name == "lock":
            continue
        if entry.is_dir() and (entry / "lock").is_file():
            with (entry / "lock").open("w") as tree_lock:
                if not try_lock(tree_lock):
                    continue
            # Windows cannot remove the open lock file. A build takes a tree
            # lock only while it holds the cache lock, which the caller holds.
            shutil.rmtree(entry)
        elif entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry)
        else:
            entry.unlink()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--cmake", type=Path, required=True)
    parser.add_argument("--ninja", type=Path, required=True)
    compilers = parser.add_mutually_exclusive_group(required=True)
    compilers.add_argument("--cc")
    compilers.add_argument(
        "--msvc-cl",
        type=Path,
        help="JSON of cl.exe and its environment from prelude//toolchains/msvc",
    )
    parser.add_argument("--cxx")
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
    if args.cc is not None and args.cxx is None:
        parser.error("--cc requires --cxx")

    args.cmake = args.cmake.resolve()
    args.ninja = args.ninja.resolve()
    if args.msvc_cl:
        msvc = json.loads(args.msvc_cl.read_text(encoding="utf-8"))
        cc = cxx = Path(msvc["exe"])
    else:
        cc = find_program(args.cc)
        cxx = find_program(args.cxx)
    source = args.source.resolve()
    output = args.output.resolve()
    cache = args.cache.expanduser().resolve()
    arguments = cmake_arguments(cc, cxx)
    tree = cache / configuration_key(args, cc, cxx, arguments)

    cache.mkdir(parents=True, exist_ok=True)
    with (cache / "lock").open("w") as cache_lock:
        lock(cache_lock)
        tree.mkdir(exist_ok=True)
        # Held until the process exits.
        tree_lock = (tree / "lock").open("w")
        lock(tree_lock)
        evict(cache, tree)

    if args.msvc_cl:
        # cl.exe and the tools beside it need the rest of the Windows
        # environment (SystemRoot, TEMP).
        env = dict(os.environ)
        for name in ["PATH", "INCLUDE", "LIB"]:
            entries = msvc[name] + ([env[name]] if env.get(name) else [])
            env[name] = os.pathsep.join(entries)
    else:
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "LC_ALL": "C",
        }
        if "TMPDIR" in os.environ:
            env["TMPDIR"] = os.environ["TMPDIR"]

    mirrored_source = tree / "source"
    build = tree / "build"
    sync_source(source, mirrored_source)
    run(
        [str(args.cmake), "-S", str(mirrored_source / "llvm"), "-B", str(build)]
        + [f"-DCMAKE_MAKE_PROGRAM={args.ninja.as_posix()}"]
        + arguments,
        env,
    )
    run([str(args.cmake), "--build", str(build), "--parallel", str(args.jobs)], env)

    shutil.rmtree(output, ignore_errors=True)
    run([str(args.cmake), "--install", str(build), "--prefix", str(output)], env)
    (output / "link-type.txt").write_text("static\n", encoding="utf-8")

    required = [
        "FileCheck",
        "clang",
        "clang++",
        "ld.lld",
        "llc",
        "llvm-ar",
        "llvm-config",
        "llvm-objcopy",
        "llvm-objdump",
    ]
    missing = [
        name for name in required if not (output / "bin" / (name + EXE_SUFFIX)).exists()
    ]
    if missing:
        raise SystemExit("custom LLVM install is missing: " + ", ".join(missing))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
