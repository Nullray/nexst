#!/usr/bin/env python3
"""Restore saved dependency changes when a source copy lacks Git metadata."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile


def blob_id(data):
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def inspect(source, patch_file):
    entries = []
    for block in re.split(r"(?=^diff --git )", patch_file.read_text(), flags=re.M):
        if not block.strip():
            continue
        paths = re.match(r"diff --git a/(\S+) b/(\S+)\n", block)
        ids = re.search(r"^index ([0-9a-f]+)\.\.([0-9a-f]+)", block, flags=re.M)
        if not paths or not ids or paths[1] != paths[2]:
            raise ValueError("Unsupported saved patch format")
        relative = Path(paths[1])
        path = source / relative
        if relative.is_absolute() or ".." in relative.parts:
            raise ValueError(f"Unsafe patch path: {relative}")
        if path.is_symlink() or not path.resolve().is_relative_to(source):
            raise ValueError(f"Patch path leaves source tree or is a symlink: {relative}")
        old, new = ids.groups()
        if set(new) == {"0"}:
            raise ValueError("Deletion patches are not supported")
        before = path.read_bytes() if path.exists() else None
        normalized = before
        if before is None:
            state = "old" if set(old) == {"0"} else None
        else:
            digest = blob_id(before)
            state = "new" if digest.startswith(new) else "old" if digest.startswith(old) else None
            # Accept the copied defconfig's missing 82599 option only when
            # inserting it reproduces the saved preimage or postimage blob.
            if state is None and str(relative) == "arch/riscv/configs/riscv_serve_defconfig":
                marker = b"CONFIG_IGB=y\n"
                if before.count(marker) == 1 and b"CONFIG_IXGBE=" not in before:
                    candidate = before.replace(marker, marker + b"CONFIG_IXGBE=y\n")
                    digest = blob_id(candidate)
                    state = "new" if digest.startswith(new) else "old" if digest.startswith(old) else None
                    if state:
                        normalized = candidate
        if state is None:
            raise ValueError(f"Source does not match saved patch hashes: {relative}")
        entries.append((relative, old, new, before, normalized, state))
    if not entries:
        raise ValueError("Saved patch contains no files")
    if len({entry[-1] for entry in entries}) != 1:
        raise ValueError("Saved patch is partially applied; inspect source before restoring")
    return entries


def restore(source, patch_file, baseline, backup_root):
    entries = inspect(source, patch_file)
    needs_patch = entries[0][-1] == "old"
    if not needs_patch and all(entry[3] == entry[4] for entry in entries):
        print(f"Dependency patch already present (file hashes verified): {patch_file.name}")
        return
    command = ["patch", "--batch", "--forward", "--fuzz=0", "--no-backup-if-mismatch",
               "-p1", "-d", str(source), "-i", str(patch_file)]
    if needs_patch:
        subprocess.run(command + ["--dry-run"], check=True)
    backup_root.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = Path(tempfile.mkdtemp(prefix=f"{source.name}-{stamp}-", dir=backup_root))
    manifest = {"source": str(source), "patch": str(patch_file),
                "expected_repository_baseline": baseline,
                "verification": "Touched file blob hashes; full repository commit is unavailable",
                "files": {}}
    for relative, old, new, before, normalized, state in entries:
        manifest["files"][str(relative)] = {"existed": before is not None,
                                           "before_blob": blob_id(before) if before is not None else None,
                                           "expected_after_blob_prefix": new}
        if before is not None:
            saved = backup / relative
            saved.parent.mkdir(parents=True, exist_ok=True)
            saved.write_bytes(before)
    (backup / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    try:
        for relative, old, new, before, normalized, state in entries:
            if normalized != before:
                (source / relative).write_bytes(normalized)
                print(f"Restored published CONFIG_IXGBE=y: {relative}")
        if needs_patch:
            subprocess.run(command, check=True)
        for relative, old, new, before, normalized, state in entries:
            if not blob_id((source / relative).read_bytes()).startswith(new):
                raise ValueError(f"Post-patch hash mismatch: {relative}")
    except Exception:
        for relative, old, new, before, normalized, state in entries:
            path = source / relative
            if before is None:
                path.unlink(missing_ok=True)
            else:
                path.write_bytes(before)
        raise
    print(f"Restored dependency patch (file hashes verified): {patch_file.name}")
    print(f"Original source backup: {backup}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("patch", type=Path)
    parser.add_argument("baseline")
    parser.add_argument("backup_root", type=Path)
    args = parser.parse_args()
    try:
        restore(args.source.resolve(), args.patch.resolve(), args.baseline, args.backup_root.resolve())
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Dependency snapshot restore failed: {error}\n")
