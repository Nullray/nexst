#!/usr/bin/env python3
"""Check build orchestration failures without invoking Mill or Vivado."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "tools/build_vp1902.sh"
MAKEFILE = REPO / "kmh/scripts/hardware.mk"
LIMITS = REPO / "shell/common/fpga/vivado_limits.tcl"

FAKE_MAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
farm = pathlib.Path(args[args.index("-C") + 1])
root = farm.parent
mode = os.environ["BUILD_TEST_MODE"]
assert os.environ["SCOPE_HOST_PROXY"] == "1"
assert os.environ["FPGA_BD"] == "uvhs2"
assert os.environ["NUM_CORES"] == "1"
assert os.environ["VIVADO_SYNTH_THREADS"] == "1"
native_logs = pathlib.Path(os.environ["VIVADO_NATIVE_LOG_DIR"])
assert native_logs.is_dir()
assert native_logs.name == "vivado-native"
assert native_logs.parent.parent.name == "hardware-logs"
assert "SHELL=/bin/bash" in args
assert ".SHELLFLAGS=-o pipefail -c" in args
with (root / "calls.jsonl").open("a") as output:
    output.write(json.dumps(args) + "\n")
if mode == "masked-error":
    print("ERROR: [Common 17-39] mock Vivado failure hidden by tee")
    sys.exit(0)
if mode == "masked-kill":
    print('/opt/Vivado/bin/rdiArgs.sh: line 454: 401020 Killed "$RDI_PROG" "$@"')
    print("Parent process (pid 401020) has died. This helper process will now exit")
    sys.exit(0)
if mode == "command-failed":
    sys.exit(7)
if mode == "stale":
    print("INFO: no new output")
    sys.exit(0)
def write(name, content="new artifact\n"):
    path = root / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
if "xs_gen" in args:
    write("kmh/hardware/sources/generated/XSTop.v")
else:
    project = next(arg.split("=", 1)[1] for arg in args if arg.startswith("PRJ="))
    action = next(arg.split("=", 1)[1] for arg in args if arg.startswith("FPGA_ACT="))
    identity = "shell_uvhs2_uvhs2" if project == "shell:uvhs2" else "target_kmh_proto_uvhs2"
    if action == "prj_gen":
        write(f"work_farm/hw_plat/{identity}/system.hdf")
        write(f"work_farm/fpga/vivado_prj/{identity}/{identity}.xpr")
        if project == "shell:uvhs2":
            write(f"work_farm/fpga/vivado_prj/{identity}/{identity}.srcs/sources_1/bd/xiangshan/xiangshan.bd",
                  '{"scope_proxy": {}, "scope_cmpt": {}, "dma_intf_sel_qdma": "AXI_MM_and_AXI_Stream_with_Completion"}\n')
    elif action == "run_syn":
        write(f"work_farm/fpga/vivado_out/{identity}/dcp/synth.dcp")
    elif action == "bit_gen":
        write(f"work_farm/hw_plat/{identity}/system.pdi")
        write(f"work_farm/fpga/vivado_out/{identity}/impl_rpt/post_route_timing.rpt",
              "Timing constraints are not met.\n" if mode == "unmet-timing"
              else "All user specified timing constraints are met.\n")
'''


def executable(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    path.chmod(0o755)


def fixture(root, mode):
    (root / "tools").mkdir()
    shutil.copy2(SCRIPT, root / "tools/build_vp1902.sh")
    helpers = root / "tools/hardware"
    helpers.mkdir()
    (helpers / "prepare_xstop_wrapper.py").write_text("print('mock CPU wrapper generation passed')\n")
    (helpers / "check_frontend.py").write_text("print('mock frontend gate passed')\n")
    for path in ("work_farm/Makefile", "kmh/hardware/xs-gen/Makefile"):
        target = root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("# test fixture\n")
    (root / "shell").mkdir()
    binary = root / "bin"
    executable(binary / "make", FAKE_MAKE)
    for name in ("java", "mill", "git"):
        executable(binary / name, "#!/bin/sh\nexit 0\n")
    executable(root / "vivado/Vivado/2025.1/Vivado/bin/vivado", "#!/bin/sh\nexit 0\n")
    return dict(os.environ, PATH=f"{binary}:{os.environ['PATH']}",
                CONFIG="FpgaDefaultConfig", NUM_CORES="1", VIVADO_VERSION="2025.1",
                VIVADO_TOOL_BASE=str(root / "vivado"), SCOPE_HOST_PROXY="0",
                VIVADO_MAX_THREADS="8", VIVADO_SYNTH_THREADS="1", VIVADO_MIN_AVAILABLE_GIB="0",
                BUILD_TEST_MODE=mode)


def check_flow(mode, arguments, expected_success, text):
    with tempfile.TemporaryDirectory(prefix="vp1902-build-test-") as directory:
        root = Path(directory)
        env = fixture(root, mode)
        if "--from-step" in arguments:
            # Model a previous successful RTL/shell/role project generation.
            for name in (
                "kmh/hardware/sources/generated/XSTop.v",
                "work_farm/fpga/vivado_prj/target_kmh_proto_uvhs2/target_kmh_proto_uvhs2.xpr",
                "work_farm/fpga/vivado_prj/shell_uvhs2_uvhs2/shell_uvhs2_uvhs2.xpr",
                "work_farm/fpga/vivado_out/shell_uvhs2_uvhs2/dcp/synth.dcp",
            ):
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text("previous successful output\n")
            bd = root / "work_farm/fpga/vivado_prj/shell_uvhs2_uvhs2/shell_uvhs2_uvhs2.srcs/sources_1/bd/xiangshan/xiangshan.bd"
            bd.parent.mkdir(parents=True)
            bd.write_text('{"scope_proxy": {}, "scope_cmpt": {}, "dma_intf_sel_qdma": "AXI_MM_and_AXI_Stream_with_Completion"}\n')
        if mode == "stale":
            old = root / "work_farm/hw_plat/shell_uvhs2_uvhs2/system.hdf"
            old.parent.mkdir(parents=True)
            old.write_text("previous output\n")
            os.utime(old, (1, 1))
        result = subprocess.run(["bash", str(root / "tools/build_vp1902.sh"), *arguments],
                                cwd=root, env=env, text=True, capture_output=True)
        assert (result.returncode == 0) == expected_success, result.stdout + result.stderr
        assert text in result.stdout + result.stderr, result.stdout + result.stderr
        calls = root / "calls.jsonl"
        if "--dry-run" in arguments:
            assert not calls.exists()
            assert not (root / "build").exists()
            assert not (root / "work_farm/shell").exists()
        elif mode == "success":
            records = [json.loads(line) for line in calls.read_text().splitlines()]
            if "--from-step" in arguments:
                assert len(records) == 2
                assert ["FPGA_ACT=run_syn", "FPGA_ACT=bit_gen"] == [
                    next(arg for arg in row if arg.startswith("FPGA_ACT=")) for row in records]
                assert not list((root / "build").glob("hardware-logs/*/previous-rtl"))
            else:
                assert len(records) == 6
                assert "xs_gen" in records[0]
                assert ["FPGA_ACT=prj_gen", "FPGA_ACT=run_syn", "FPGA_ACT=prj_gen",
                        "FPGA_ACT=run_syn", "FPGA_ACT=bit_gen"] == [
                    next(arg for arg in row if arg.startswith("FPGA_ACT=")) for row in records[1:]]
        elif mode in ("masked-error", "masked-kill", "command-failed", "stale"):
            assert len(calls.read_text().splitlines()) == 1
            assert len(list((root / "build").glob("hardware-logs/*/failure.log"))) == 1
    print(f"PASS: {mode} {' '.join(arguments) or 'all'}")


def check_rtl_copy():
    with tempfile.TemporaryDirectory(prefix="vp1902-rtl-copy-test-") as directory:
        root = Path(directory)
        hardware = root / "target/kmh/hardware"
        xs = hardware / "xs-gen"
        xs.mkdir(parents=True)
        (root / "Makefile").write_text(f"include {MAKEFILE}\n")
        # Mirror the upstream GNU time recipe, which conflicts with Bash's time keyword.
        (xs / "Makefile").write_text(
            "TIME_CMD = time -avp -o ./build/time.log\n"
            "verilog:\n\tmkdir -p build\n\t$(TIME_CMD) python3 generate.py\n")
        (xs / "generate.py").write_text(
            "from pathlib import Path\nimport os\n"
            "assert Path(os.environ['NOOP_HOME']) == Path.cwd()\n"
            "assert os.environ.get('LLC', '') != 'OpenLLC'\n"
            "p=Path('build/rtl'); p.mkdir(parents=True,exist_ok=True)\n"
            "(p/'XSTop.sv').write_text('module XSTop; endmodule\\n')\n"
            "(p/'Example.sv').write_text('module Example; endmodule\\n')\n")
        patches = hardware / "sources/patch"
        patches.mkdir(parents=True)
        (patches / "ClockGate.sv").write_text("module ClockGate; endmodule\n")
        actual_make = shutil.which("make")
        result = subprocess.run([actual_make, "-C", str(root), "xs_gen",
                                 "SHELL=/bin/bash", ".SHELLFLAGS=-o pipefail -c"],
                                text=True, capture_output=True)
        assert result.returncode == 0, result.stdout + result.stderr
        generated = hardware / "sources/generated"
        assert (generated / "XSTop.v").is_file()
        assert (generated / "Example.sv").is_file()
        assert (generated / "ClockGate.sv").is_file()
        assert not (generated / "XSTop.sv").exists()
        assert (xs / "build/time.log").stat().st_size > 0
        assert "/usr/bin/time -avp" in result.stdout
    print("PASS: recursive RTL generation uses GNU time under Bash and copies SystemVerilog output")


def check_recursive_pipefail():
    with tempfile.TemporaryDirectory(prefix="vp1902-pipefail-test-") as directory:
        root = Path(directory)
        child = root / "child"
        child.mkdir()
        (root / "Makefile").write_text("all:\n\t$(MAKE) -C child\n")
        (child / "Makefile").write_text("all:\n\t@sh -c 'exit 17' | tee hidden.log\n")
        command = [shutil.which("make"), "-C", str(root)]
        masked = subprocess.run(command, capture_output=True)
        fixed = subprocess.run(command + ["SHELL=/bin/bash", ".SHELLFLAGS=-o pipefail -c"],
                               capture_output=True)
        assert masked.returncode == 0
        assert fixed.returncode != 0
    print("PASS: pipefail propagates through recursive GNU make")


def check_thread_limits():
    script = ('proc set_param {name value} {global parameters; set parameters($name) $value}\n'
              'proc get_param {name} {global parameters; return $parameters($name)}\n'
              f'source {{{LIMITS}}}\n'
              'if {[get_param synth.maxThreads] != 1} {error "wrong synthesis limit"}\n')
    env = dict(os.environ, VIVADO_MAX_THREADS="8", VIVADO_SYNTH_THREADS="1")
    result = subprocess.run(["tclsh"], input=script, env=env, text=True, capture_output=True)
    assert result.returncode == 0 and not result.stderr, result.stdout + result.stderr
    print("PASS: Vivado thread-limit Tcl uses one synthesis process")


def check_native_logs():
    with tempfile.TemporaryDirectory(prefix="vp1902-native-log-test-") as directory:
        root = Path(directory)
        fpga = root / "fpga"
        fpga.mkdir()
        shutil.copy2(REPO / "work_farm/fpga/Makefile", fpga / "Makefile")
        executable(root / "fake-vivado", '''#!/usr/bin/env python3
import pathlib, sys
args = sys.argv[1:]
assert "-nolog" not in args and "-nojournal" not in args
log = pathlib.Path(args[args.index("-log") + 1])
journal = pathlib.Path(args[args.index("-journal") + 1])
assert log.parent.is_dir() and journal.parent == log.parent
log.write_text("native diagnostic\\n")
journal.write_text("synth_design\\n")
print("stdout diagnostic", flush=True)
print("stderr diagnostic", file=sys.stderr, flush=True)
''')
        for project, action, target in [
            ("shell:uvhs2", "run_syn", "shell_uvhs2_uvhs2"),
            ("target:kmh:proto", "run_syn", "target_kmh_proto_uvhs2"),
            ("target:kmh:proto", "bit_gen", "target_kmh_proto_uvhs2"),
        ]:
            result = subprocess.run([
                shutil.which("make"), "-C", str(fpga), "vivado_prj",
                f"VIVADO={root / 'fake-vivado'}", "FPGA_BD=uvhs2",
                f"FPGA_PRJ={project}", f"FPGA_ACT={action}",
                f"VIVADO_NATIVE_LOG_DIR={root / 'native'}",
                "SHELL=/bin/bash", ".SHELLFLAGS=-o pipefail -c",
            ], text=True, capture_output=True)
            assert result.returncode == 0, result.stdout + result.stderr
            native = root / "native" / target
            assert (native / f"{action}.vivado.log").read_text() == "native diagnostic\n"
            assert (native / f"{action}.vivado.jou").read_text() == "synth_design\n"
            stream = (fpga / "vivado_out" / target / "run_log" / f"{action}.log").read_text()
            assert "stdout diagnostic" in stream and "stderr diagnostic" in stream
        assert len(list((root / "native").rglob("*.vivado.log"))) == 3
    print("PASS: native logs/journals are separate for shell, role and PDI; console captures both streams")


if __name__ == "__main__":
    check_flow("success", ["--dry-run"], True, "预览完成")
    check_flow("success", [], True, "步骤 rtl shell-gen shell-synth role-gen role-synth pdi 完成")
    check_flow("success", ["--from-step", "role-synth"], True, "步骤 role-synth pdi 完成")
    check_flow("masked-error", ["--stage", "shell"], False, "日志包含错误")
    check_flow("masked-kill", ["--stage", "shell"], False, "日志包含错误")
    check_flow("command-failed", ["--stage", "shell"], False, "命令失败")
    check_flow("stale", ["--stage", "shell"], False, "未生成新的非空产物")
    check_flow("unmet-timing", [], False, "时序报告没有确认约束已满足")
    check_rtl_copy()
    check_recursive_pipefail()
    check_thread_limits()
    check_native_logs()
