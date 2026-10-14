#!/usr/bin/env python3
"""Launch a verified node41 profile; default to dual-core ordinary Kunminghu."""
from datetime import datetime
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
from zoneinfo import ZoneInfo


def main():
    base = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cpu-kind", choices=["xsai", "kunminghu"], default="kunminghu",
                        help="default: ordinary dual-core Kunminghu; XS-AI compilation is deferred")
    parser.add_argument("--from-stage", choices=["full", "wrapper", "role-synth", "pdi"], default="full")
    args = parser.parse_args()
    prepared = json.loads((base / "build/NODE41_PROFILES.json").read_text())
    if {(item["source"]["cpu_kind"], item["source"]["num_cores"]) for item in prepared["profiles"]} != {("xsai", 1), ("kunminghu", 2)}:
        raise RuntimeError("both requested CPU profiles must be prepared and verified first")
    lock = (base / "build/node41-launch.lock").open("w")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    selected = [item for item in prepared["profiles"]
                if item["source"]["cpu_kind"] == args.cpu_kind]
    kinds = {item["source"]["cpu_kind"] for item in selected}
    previous = base / "build/NODE41_LAUNCH.json"
    old = None
    if previous.exists():
        old = json.loads(previous.read_text())
        for job in old["jobs"]:
            if job["source"]["cpu_kind"] not in kinds:
                continue
            process = Path(f'/proc/{job["pid"]}/cmdline')
            if process.exists() and b"run_profile.py" in process.read_bytes():
                raise RuntimeError(f'profile already running: {job["pid"]}')
    mem = {line.split(":", 1)[0]: line.split(":", 1)[1].strip()
           for line in Path("/proc/meminfo").read_text().splitlines()}
    available_gib = int(mem["MemAvailable"].split()[0]) / 1048576
    required_gib = 704 if len(kinds) == 2 else (192 if "xsai" in kinds else 320)
    if available_gib < required_gib:
        raise RuntimeError(f"launch requires {required_gib} GiB available; currently {available_gib:.1f} GiB")
    cache = base / "build/tool-cache"
    for dependency in [cache / "mill/0.12.3", cache / "llvm-firtool/1.62.1/bin/firtool"]:
        if not os.access(dependency, os.X_OK):
            raise RuntimeError(f"missing executable tool: {dependency}")
    started = datetime.now(ZoneInfo("Asia/Shanghai"))
    record = old or {"host": "10.30.19.41", "ssh_port": 2222, "user": "yanjiarun",
                     "started_at": started.isoformat(), "original_local_build_kept": False,
                     "jobs": []}
    record.update({"last_started_at": started.isoformat(),
                   "available_gib_at_start": round(available_gib, 1)})
    for item in selected:
        root = Path(item["path"])
        source = item["source"]
        env = os.environ.copy()
        env.update({"PATH": str(root / "tools/hardware/bin") + ":" + env["PATH"],
                    "VP1902_TOOL_CACHE": str(cache), "COURSIER_CACHE": str(cache / "coursier/v1"),
                    "FIRTOOL": str(cache / "llvm-firtool/1.62.1/bin/firtool"),
                    "VIVADO_VERSION": "2025.1", "VIVADO_TOOL_BASE": "/opt/Xilinx_2025.1",
                    "TZ": "Asia/Shanghai"})
        console = root / "build" / f'profile-console-{started:%Y%m%d_%H%M%S}.log'
        command = ["nohup", "python3", "-u", "tools/hardware/run_profile.py",
                   "--num-cores", str(source["num_cores"]), "--cpu-kind", source["cpu_kind"],
                   "--from-stage", args.from_stage]
        with console.open("xb", buffering=0) as stream:
            process = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                       stdout=stream, stderr=subprocess.STDOUT,
                                       start_new_session=True, close_fds=True)
        job = {"pid": process.pid, "cwd": str(root), "command": command, "source": source,
               "started_at": started.isoformat(), "from_stage": args.from_stage,
               "console_log": str(console), "detached": True,
               "state_file": str(root / "build/PROFILE_BUILD.json"),
               "frontend_check": str(root / "build/FRONTEND_CHECK.json"),
               "pdi": str(root / "work_farm/hw_plat/target_kmh_proto_uvhs2/system.pdi")}
        (root / "build/PROFILE_LAUNCH.json").write_text(json.dumps(job, indent=2) + "\n")
        replaced = [entry for entry in record["jobs"] if entry["source"]["cpu_kind"] == source["cpu_kind"]]
        record.setdefault("job_history", []).extend(replaced)
        record["jobs"] = [entry for entry in record["jobs"]
                          if entry["source"]["cpu_kind"] != source["cpu_kind"]] + [job]
        previous.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()
