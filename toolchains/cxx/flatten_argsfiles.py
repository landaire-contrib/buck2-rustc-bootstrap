#!/usr/bin/env python3
"""Runs a tool with its response files spliced into one.

cl.exe does not read a response file named inside another response file, as
`@$(location ...)` flags inside the prelude's argsfiles do.
"""

import codecs
import os
import subprocess
import sys
import tempfile
from pathlib import Path


def read_lines(path: Path) -> list[str]:
    content = path.read_bytes()
    if content.startswith(codecs.BOM_UTF16_LE) or content.startswith(codecs.BOM_UTF16_BE):
        return content.decode("utf-16").splitlines()
    return content.decode("utf-8-sig").splitlines()


def response_file(token: str) -> Path | None:
    token = token.strip()
    if len(token) > 1 and token[0] == '"' and token[-1] == '"':
        token = token[1:-1]
    return Path(token[1:]) if token.startswith("@") else None


def splice(lines: list[str], output: list[str]) -> None:
    for line in lines:
        path = response_file(line)
        if path is None:
            output.append(line)
        else:
            splice(read_lines(path), output)


def main() -> int:
    tool, arguments = sys.argv[1], sys.argv[2:]
    lines: list[str] = []
    for argument in arguments:
        path = response_file(argument)
        if path is None:
            lines.append(subprocess.list2cmdline([argument]))
        else:
            splice(read_lines(path), lines)

    descriptor, name = tempfile.mkstemp(suffix=".rsp", text=True)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            file.write("\n".join(lines) + "\n")
        return subprocess.run([tool, "@" + name]).returncode
    finally:
        os.unlink(name)


if __name__ == "__main__":
    raise SystemExit(main())
