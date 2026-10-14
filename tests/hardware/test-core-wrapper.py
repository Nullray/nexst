#!/usr/bin/env python3
"""Check native one/two-core port adapters, including complete live AXI DMA."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('scope_wrapper', ROOT / 'tools/hardware/prepare_xstop_wrapper.py')
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)
template = (ROOT / 'tools/hardware/xstop_wrapper.template.v.in').read_text()

for count in (1, 2):
    fixture = (ROOT / f'tests/hardware/fixtures/kunminghu-{count}core-ports.v').read_text()
    wrapped, actual = adapter.render(fixture, template, count)
    dma = {n: p for n, p in actual.items() if n.startswith('dma_')}
    assert len(dma) == 37
    # Nonzero high address/ID/data bits catch truncation and old tie-offs.
    values = {name: ((1 << (width - 1)) | 0x5a) & ((1 << width) - 1)
              for name, (_, width) in dma.items()}
    body = ['reg [%d:0] halt_status = 0;' % (count - 1),
            'reg [%d:0] error_status = 0;' % (count - 1)]
    for name, (direction, width) in actual.items():
        if direction != 'output':
            continue
        value = "'0"
        if name in dma:
            value = f"{width}'h{values[name]:x}"
        elif name.startswith('io_riscv_halt_'):
            value = f"halt_status[{name.rsplit('_', 1)[1]}]"
        elif name.startswith('io_riscv_critical_error_'):
            value = f"error_status[{name.rsplit('_', 1)[1]}]"
        body.append(f'assign {name} = {value};')
    body.append('initial begin #1;')
    for core in range(count):
        body.append(f"if (io_riscv_rst_vec_{core} !== 48'h123456789abc) $fatal(1, \"boot vector lost\");")
        body.append(f"if ({{nmi_{core}_0,nmi_{core}_1}} !== 2'b0) $fatal(1, \"NMI floats\");")
        body.append(f"if ({{io_traceCoreInterface_{core}_fromEncoder_enable,io_traceCoreInterface_{core}_fromEncoder_stall}} !== 2'b0) $fatal(1, \"trace stalls CPU\");")
    for name, (direction, width) in dma.items():
        if direction == 'input':
            body.append(f"if ({name} !== {width}'h{values[name]:x}) $fatal(1, \"DMA input {name} lost\");")
    body.append('end')
    stub = fixture.replace('endmodule', '\n'.join(body) + '\nendmodule', 1)
    connections = [".clk(1'b0)", ".rst(1'b0)", ".rtc_clk(1'b0)",
                   ".rst_vec(48'h123456789abc)", ".ext_intrs(64'b0)",
                   '.riscv_halt(halted)', '.riscv_critical_error(error)']
    bench = ['module tb;', 'wire halted, error;']
    for name, (direction, width) in dma.items():
        if direction == 'input':
            connections.append(f".{name}({width}'h{values[name]:x})")
        else:
            bench.append(f'wire [{width-1}:0] {name};')
            connections.append(f'.{name}({name})')
    bench.append('xstop_wrapper dut(' + ','.join(connections) + ');')
    bench.append('initial begin #2;')
    for name, (direction, width) in dma.items():
        if direction == 'output':
            bench.append(f"if ({name} !== {width}'h{values[name]:x}) $fatal(1, \"DMA response {name} lost\");")
    bench.extend(["if (halted !== 0 || error !== 0) $fatal(1, \"initial status wrong\");",
                  "dut.xstop.halt_status = '1; #1;",
                  "if (halted !== 1) $fatal(1, \"halt must mean all cores\");",
                  "dut.xstop.error_status = 1; #1;",
                  "if (error !== 1) $fatal(1, \"any core error must propagate\");",
                  "if (dut.trace_mstatus !== 64'b0 || dut.trace_valid !== 3'b0) $fatal(1, \"extra trace fields float\");",
                  '$finish;', 'end', 'endmodule'])
    with tempfile.TemporaryDirectory() as d:
        p = Path(d)
        (p / 'test.v').write_text(stub + wrapped + '\n'.join(bench))
        subprocess.run(['iverilog', '-g2012', '-s', 'tb', '-o', str(p / 'test'), str(p / 'test.v')], check=True)
        subprocess.run(['vvp', str(p / 'test')], check=True)
    print(f'PASS: native {count}-core wrapper, live 37-signal DMA, reset/NMI/trace and status')
