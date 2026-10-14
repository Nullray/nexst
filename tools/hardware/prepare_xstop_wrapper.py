#!/usr/bin/env python3
"""Export ordinary Kunminghu's coherent AXI slave DMA for one or two cores."""
import argparse
import hashlib
import json
from pathlib import Path
import re


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def ports(source, module):
    match = re.search(r"\bmodule\s+" + re.escape(module) + r"\s*\((.*?)\n\);",
                      source, re.S)
    if not match:
        raise ValueError(f"unsupported {module} module declaration")
    found = {}
    for direction, high, low, name in re.findall(
            r"^\s*(input|output)\s+(?:wire\s+|logic\s+)?"
            r"(?:\[(\d+):(\d+)\]\s*)?(\w+)\s*[,\n]", match.group(1) + "\n", re.M):
        if name in found:
            raise ValueError(f"duplicate port {name}")
        found[name] = (direction, abs(int(high) - int(low)) + 1 if high else 1)
    if not found:
        raise ValueError(f"no ports found in {module}")
    return found


def render(top, template, count, kind="kunminghu"):
    if kind != "kunminghu":
        raise ValueError("this SCOPE architecture requires ordinary Kunminghu, not XSAI")
    actual = ports(top, "XSTop")
    dma = {n: p for n, p in actual.items() if n.startswith("dma_")}
    required_dma = {"dma_" + n for n in (
        "awid awaddr awlen awsize awburst awlock awcache awprot awqos awvalid awready "
        "wdata wstrb wlast wvalid wready bid bresp bvalid bready "
        "arid araddr arlen arsize arburst arlock arcache arprot arqos arvalid arready "
        "rid rdata rresp rlast rvalid rready").split()}
    if set(dma) != required_dma:
        raise ValueError(f"ordinary Kunminghu AXI DMA ports differ: {set(dma) ^ required_dma}")
    declarations = []
    for name, (direction, width) in dma.items():
        dimension = f"[{width-1}:0] " if width > 1 else ""
        declarations.append(f"  {direction} wire {dimension}{name},")
    template = template.replace("  input          peripheral_awready,",
                                "\n".join(declarations) + "\n\n  input          peripheral_awready,", 1)
    template = template.replace("  input          clk,", '  (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF dma:memory:peripheral, ASSOCIATED_RESET rst, FREQ_HZ 50000000" *)\n  input          clk,', 1)
    vectors = {int(name.rsplit("_", 1)[1]) for name in actual
               if re.fullmatch(r"io_riscv_rst_vec_\d+", name)}
    if vectors != set(range(count)):
        raise ValueError(f"RTL has reset-vector cores {sorted(vectors)}, requested {count}")
    for core in range(count):
        required = {f"nmi_{core}_0", f"nmi_{core}_1", f"io_riscv_halt_{core}",
                    f"io_riscv_critical_error_{core}", f"io_riscv_rst_vec_{core}",
                    f"io_traceCoreInterface_{core}_fromEncoder_enable",
                    f"io_traceCoreInterface_{core}_fromEncoder_stall"}
        if required - set(actual):
            raise ValueError(f"missing required core {core} ports: {sorted(required - set(actual))}")
    match = re.search(r"\bXSTop\s+xstop\s*\((.*?)\n\s*\);", template, re.S)
    if not match:
        raise ValueError("unsupported wrapper template")
    mapping = dict(re.findall(r"\.(\w+)\(([^()]*)\)", match.group(1)))
    unknown = set(mapping) - set(actual)
    unused_trace = []
    if kind == "kunminghu":
        # Ordinary Kunminghu predates XSAI's extra trace fields. The existing
        # role/ILA interface keeps those outputs, with tracing disabled.
        for name in sorted(unknown & {"io_traceCoreInterface_0_toEncoder_mstatus",
                                      "io_traceCoreInterface_0_toEncoder_valid"}):
            unused_trace.append(mapping.pop(name))
            unknown.remove(name)
    if unknown:
        raise ValueError(f"template ports absent from RTL: {sorted(unknown)}")
    outer = ports(template, "xstop_wrapper")
    prefix = template[:match.start()]
    for name in unused_trace:
        if outer[name][0] != "output":
            raise ValueError(f"unused trace port must be an output: {name}")
        prefix += f"  assign {name} = {outer[name][1]}'b0;\n"
    # Extra cores add AXI IDs in some configurations. Preserve every bit and
    # reject any interface that exceeds the existing role/shell aperture.
    for bus, capacity in [("memory", 14), ("peripheral", 4)]:
        widths = {actual[f"{bus}_{channel}id"][1] for channel in ["aw", "ar", "b", "r"]}
        if len(widths) != 1 or next(iter(widths)) > capacity:
            raise ValueError(f"{bus} ID widths {widths} exceed role capacity {capacity}")
        width = next(iter(widths))
        for channel in ["aw", "ar", "b", "r"]:
            name = f"{bus}_{channel}id"
            prefix, changes = re.subn(r"(\b(?:input|output)\s+)\[\d+:\d+\](\s+" + name + r"\b)",
                                     rf"\g<1>[{width - 1}:0]\g<2>", prefix)
            if changes != 1:
                raise ValueError(f"cannot set wrapper ID width for {name}")
            outer[name] = (outer[name][0], width)
    if count == 2:
        prefix += ("  wire [1:0] core_halt;\n  wire [1:0] core_critical_error;\n"
                   "  assign riscv_halt = &core_halt;\n"
                   "  assign riscv_critical_error = |core_critical_error;\n\n")
        mapping["io_riscv_halt_0"] = "core_halt[0]"
        mapping["io_riscv_critical_error_0"] = "core_critical_error[0]"
    for name, (direction, width) in actual.items():
        if name in mapping:
            bound = mapping[name]
            if bound in outer and outer[bound][1] != width:
                raise ValueError(f"port width mismatch: {name}={width}, {bound}={outer[bound][1]}")
            continue
        if re.fullmatch(r"nmi_[01]_[01]", name) and direction == "input":
            mapping[name] = "1'b0"
        elif name == "io_riscv_rst_vec_1" and direction == "input" and width == 48:
            mapping[name] = "rst_vec"
        elif re.fullmatch(r"io_traceCoreInterface_1_fromEncoder_(enable|stall)", name):
            mapping[name] = "1'b0"
        elif name == "io_riscv_halt_1":
            mapping[name] = "core_halt[1]"
        elif name == "io_riscv_critical_error_1":
            mapping[name] = "core_critical_error[1]"
        elif name.startswith("io_traceCoreInterface_1_toEncoder_") and direction == "output":
            mapping[name] = ""
        elif kind == "kunminghu" and name.startswith("dma_"):
            mapping[name] = name
        else:
            raise ValueError(f"unhandled generated port: {direction} {name}[{width}]")
    body = ",\n".join(f"    .{name}({mapping[name]})" for name in actual)
    result = prefix + "XSTop xstop (\n" + body + "\n  );" + template[match.end():]
    return result, actual


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--num-cores", type=int, choices=[1, 2], required=True)
    parser.add_argument("--config", default="FpgaDefaultConfig")
    parser.add_argument("--cpu-kind", choices=["kunminghu"], default="kunminghu")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    top = root / "kmh/hardware/sources/generated/XSTop.v"
    template = root / "tools/hardware/xstop_wrapper.template.v.in"
    wrapper = root / "kmh/fpga/sources/hdl/xstop_wrapper.v"
    metadata = root / "build/RTL_PROFILE.json"
    result, actual = render(top.read_text(), template.read_text(), args.num_cores, args.cpu_kind)
    if args.check:
        record = json.loads(metadata.read_text())
        if (record["num_cores"] != args.num_cores or record["config"] != args.config or
                record["cpu_kind"] != args.cpu_kind or
                record["top_sha256"] != digest(top) or wrapper.read_text() != result):
            raise ValueError("RTL/wrapper profile differs; regenerate the correct core configuration")
    else:
        wrapper.write_text(result)
        metadata.parent.mkdir(parents=True, exist_ok=True)
        metadata.write_text(json.dumps({
            "num_cores": args.num_cores, "config": args.config, "cpu_kind": args.cpu_kind,
            "top_sha256": digest(top), "wrapper_sha256": digest(wrapper),
            "memory_id_bits": actual["memory_awid"][1],
            "peripheral_id_bits": actual["peripheral_awid"][1],
            "coherent_dma_exported": True,
            "dma_address_bits": actual["dma_awaddr"][1],
            "dma_id_bits": actual["dma_awid"][1],
            "halt": "all cores halted", "critical_error": "any core error",
            "trace": "core 0; trace encoder disabled for both cores",
        }, indent=2) + "\n")
    print(f"Verified XSTop wrapper: {args.num_cores} core(s), complete reset/NMI/trace wiring")


if __name__ == "__main__":
    main()
