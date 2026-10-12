#!/usr/bin/env python3
"""Relocate a copied Nanhu-G initramfs manifest and validate its file inputs."""
import argparse
from pathlib import Path
import shlex


def relocate(source, rootfs):
    lines = []
    for number, line in enumerate(source.splitlines(), 1):
        fields = shlex.split(line, comments=True)
        if fields and fields[0] == "file":
            if len(fields) < 6:
                raise ValueError(f"manifest line {number}: incomplete file entry")
            old = fields[2]
            marker = "/nanhu-g/software/rootfs/"
            if marker in old:
                fields[2] = str((rootfs / old.split(marker, 1)[1]).resolve())
            if not Path(fields[2]).is_file():
                raise ValueError(f"manifest line {number}: missing {fields[2]}; rebuild rootfs first")
            if any(character.isspace() for character in fields[2]):
                raise ValueError("initramfs source paths cannot contain whitespace")
            line = " ".join(fields)
        lines.append(line)
    return "\n".join(lines) + "\n"


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=root / "nanhu-g/software/rootfs/initramfs.txt")
    parser.add_argument("--output", type=Path, default=root / "build/nanhu-host/initramfs.txt")
    args = parser.parse_args()
    try:
        if args.source.resolve() == args.output.resolve():
            raise ValueError("write to a separate output manifest")
        contents = relocate(args.source.read_text(), root / "nanhu-g/software/rootfs")
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(contents)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print(args.output.resolve())


if __name__ == "__main__":
    main()
