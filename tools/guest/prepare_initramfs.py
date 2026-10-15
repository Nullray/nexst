#!/usr/bin/env python3
"""Relocate a Nanhu-G USB manifest and install the saved hvc0 console inputs."""
import argparse
from pathlib import Path
import shlex


def usb_console_inputs(source):
    include = Path(__file__).resolve().parent / "include"
    inputs = {"/init": include / "nanhu-usb-init.sh",
              "/etc/inittab": include / "nanhu-usb-inittab"}
    seen = set()
    lines = []
    for line in source.splitlines():
        fields = shlex.split(line, comments=True)
        if fields and fields[0] == "file" and len(fields) > 1 and fields[1] in inputs:
            if len(fields) < 6 or fields[1] in seen:
                raise ValueError(f"invalid or duplicate USB console entry: {fields[1]}")
            seen.add(fields[1])
            fields[2] = str(inputs[fields[1]])
            line = " ".join(fields)
        lines.append(line)
    if seen != set(inputs):
        raise ValueError("USB manifest requires file entries for /init and /etc/inittab")
    return "\n".join(lines) + "\n"


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


def add_overlay(source, overlay):
    """Add files from a staging root without replacing existing guest entries."""
    entries = {fields[1]: fields[0] for line in source.splitlines()
               if (fields := shlex.split(line, comments=True))}
    lines = [source.rstrip()]
    for path in sorted(overlay.rglob("*"), key=lambda p: (len(p.parts), str(p))):
        target = "/" + path.relative_to(overlay).as_posix()
        if any(char.isspace() for char in str(path)):
            raise ValueError(f"overlay paths cannot contain whitespace: {path}")
        if target in entries:
            if path.is_dir() and not path.is_symlink() and entries[target] == "dir":
                continue
            raise ValueError(f"overlay conflicts with existing guest entry: {target}")
        mode = path.lstat().st_mode & 0o777
        if path.is_symlink():
            link = str(path.readlink())
            if any(char.isspace() for char in link):
                raise ValueError(f"overlay symlink contains whitespace: {path}")
            lines.append(f"slink {target} {link} {mode:o} 0 0")
        elif path.is_dir():
            lines.append(f"dir {target} {mode:o} 0 0")
        elif path.is_file():
            lines.append(f"file {target} {path} {mode:o} 0 0")
        else:
            raise ValueError(f"unsupported overlay entry: {path}")
        entries[target] = lines[-1].split()[0]
    return "\n".join(lines) + "\n"


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=root / "nanhu-g/software/rootfs/initramfs.txt")
    parser.add_argument("--output", type=Path, default=root / "build/nanhu-host/initramfs.txt")
    parser.add_argument("--overlay", type=Path, help="additional staging root, e.g. UHD runtime")
    args = parser.parse_args()
    try:
        if args.source.resolve() == args.output.resolve():
            raise ValueError("write to a separate output manifest")
        contents = relocate(usb_console_inputs(args.source.read_text()),
                            root / "nanhu-g/software/rootfs")
        if args.overlay:
            overlay = args.overlay.resolve()
            if not overlay.is_dir():
                raise ValueError(f"missing overlay directory: {overlay}")
            contents = add_overlay(contents, overlay)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(contents)
    except (ValueError, OSError) as error:
        parser.error(str(error))
    print(args.output.resolve())


if __name__ == "__main__":
    main()
