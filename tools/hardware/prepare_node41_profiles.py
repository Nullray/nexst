#!/usr/bin/env python3
"""Prepare isolated ordinary Kunminghu 1/2-core SCOPE workspaces."""
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
from urllib.parse import urlparse
from zoneinfo import ZoneInfo

KMH_MAIN = "8137ac2a299a354ba10acc89c731af90b6d8c8cb"
KMH_CPU = "4bbdccbb077840af5e1b65c7138d31af3966f625"
OLD_ROOTS = ["/home/yanjiarun/nexst_proxy_17/nexst_kunminghu_qdma_hostbuf_node41",
             "/home/yanjiarun/nexst_proxy_17/nexst_kunminghu_qdma_hostbuf",
             "/home/yanjiarun/nexst_proxy_17/nexst_kunminghu_xsai"]


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def rebase_links(root, aliases):
    changes = 0
    for directory, names, files in os.walk(root, followlinks=False):
        for name in names + files:
            path = Path(directory) / name
            if not path.is_symlink():
                continue
            target = os.readlink(path)
            for old in aliases:
                if target == old or target.startswith(old + "/"):
                    path.unlink()
                    path.symlink_to(str(root) + target[len(old):])
                    changes += 1
                    break
    return changes


def rebase_git_paths(root, aliases):
    changes = 0
    candidates = []
    for directory, names, files in os.walk(root, followlinks=False):
        if Path(directory).is_relative_to(root / "build/git-path-backups"):
            names[:] = []
            continue
        if ".git" in files:
            candidates.append(Path(directory) / ".git")
    for path in (root / ".git").rglob("*"):
        if path.is_file() and path.name in {"config", "alternates", "commondir", "gitdir"}:
            candidates.append(path)
    for path in candidates:
        original = path.read_text()
        updated = original
        for old in aliases:
            updated = updated.replace(old + "/", str(root) + "/")
        if updated != original:
            backup = root / "build/git-path-backups" / path.relative_to(root)
            backup.parent.mkdir(parents=True, exist_ok=True)
            if not backup.exists():
                shutil.copy2(path, backup)
            path.write_text(updated)
            changes += 1
    return changes


def overlay(source, target, relative):
    origin, destination = source / relative, target / relative
    destination.parent.mkdir(parents=True, exist_ok=True)
    if origin.is_dir():
        shutil.copytree(origin, destination, dirs_exist_ok=True)
    else:
        shutil.copy2(origin, destination)


def cached_git(base, target):
    """Reuse copied Git object stores for dependency clones when available."""
    repositories = {}
    aliases = set()
    for root in [base, target]:
        for config in (root / ".git/modules").rglob("config"):
            result = subprocess.run(["git", "config", "--file", str(config),
                                     "--get", "remote.origin.url"], text=True, capture_output=True)
            raw = result.stdout.strip()
            parsed = urlparse(raw)
            if parsed.hostname != "github.com":
                continue
            key = parsed.path.strip("/").removesuffix(".git").lower()
            aliases.add(raw)
            size = sum(path.stat().st_size for path in (config.parent / "objects/pack").glob("*.pack"))
            if key not in repositories or size > repositories[key][0]:
                repositories[key] = (size, config.parent)
        for modules in root.rglob(".gitmodules"):
            if modules.is_file():
                for line in modules.read_text().splitlines():
                    if line.strip().startswith("url = https://github.com/"):
                        aliases.add(line.split("=", 1)[1].strip())
    command = ["git", "-c", "protocol.file.allow=always"]
    mirror = base / "build/git-mirrors"
    for raw in list(aliases):
        plain = raw.rstrip("/").removesuffix(".git")
        aliases.update({plain, plain + ".git", plain + "/", plain + ".git/"})
    for raw in sorted(aliases):
        parsed = urlparse(raw)
        key = parsed.path.strip("/").removesuffix(".git").lower()
        if key not in repositories:
            continue
        name = parsed.path.strip("/")
        for variant in {name.removesuffix(".git"), name.removesuffix(".git") + ".git"}:
            link = mirror / variant
            link.parent.mkdir(parents=True, exist_ok=True)
            if not link.exists():
                link.symlink_to(repositories[key][1], target_is_directory=True)
        local = (mirror / name).as_uri()
        command += ["-c", f"url.{local}.insteadOf={raw}"]
    return command


def main():
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--single-root", type=Path)
    args = parser.parse_args()
    base = args.base.resolve()
    single = (args.single_root or base.parent / "nexst_kunminghu_single").resolve()
    if subprocess.run(["git", "-C", str(base), "merge-base", "--is-ancestor", KMH_MAIN, "HEAD"]).returncode or git(base / "kmh/hardware/xs-gen", "rev-parse", "HEAD") != KMH_CPU:
        raise RuntimeError("source must be the ordinary kunminghu branch and its pinned XiangShan CPU")
    if "OpenXiangShan/XiangShan.git" not in (base / ".gitmodules").read_text():
        raise RuntimeError("ordinary XiangShan submodule URL required")
    if single.exists():
        raise RuntimeError(f"refusing to overwrite existing profile: {single}")
    excludes = ["/build/", "/work_farm/fpga/vivado_prj/", "/work_farm/fpga/vivado_out/",
                "/work_farm/fpga/.Xil/", "/work_farm/hw_plat/", "/kmh/hardware/xs-gen/out/",
                "/kmh/hardware/xs-gen/build/", "/tools/host/qemu/build-xsai/", "*.pyc"]
    subprocess.run(["rsync", "-a", "--sparse", *[f"--exclude={x}" for x in excludes], str(base)+"/", str(single)+"/"], check=True)
    rebase_git_paths(single, [str(base), *OLD_ROOTS])
    rebase_links(single, [str(base), *OLD_ROOTS])
    for count, root in [(1, single), (2, base)]:
        (root / "build").mkdir(exist_ok=True)
        manifest = root / "config/kunminghu-profile.json"
        if manifest.exists():
            profile = json.loads(manifest.read_text()); profile["num_cores"] = count
            manifest.write_text(json.dumps(profile, indent=2)+"\n")
        source = {"cpu_kind": "kunminghu", "main_branch": "kunminghu", "main_commit": KMH_MAIN,
                  "cpu_commit": KMH_CPU, "cpu_repository": "https://github.com/OpenXiangShan/XiangShan.git",
                  "num_cores": count, "config": "FpgaDefaultConfig", "work_farm_commit": git(root / "work_farm", "rev-parse", "HEAD")}
        (root / "build/CPU_SOURCE.json").write_text(json.dumps(source, indent=2)+"\n")
        branch = f"feature/vp1902-kunminghu-{count}core-scope-bridge"
        subprocess.run(["git", "-C", str(root), "switch", "-c", branch], check=True)
        (root / ".node41-migration-owner.json").write_text(json.dumps({"ordinary_kunminghu": True,"num_cores":count,"source":str(base)})+"\n")
        if count == 1:
            previous = root / "kmh/hardware/sources/generated"
            if previous.exists(): shutil.move(str(previous), str(root / "build/imported-dual-generated"))
        print(json.dumps({"root":str(root),"source":source}), flush=True)


if __name__ == "__main__":
    main()
