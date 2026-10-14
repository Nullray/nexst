#!/usr/bin/env python3
"""Build the SCOPE DT from the actual ordinary Kunminghu generated DT."""
import argparse
import re
import subprocess
from pathlib import Path


def render(source, cores):
    if cores not in (1, 2):
        raise ValueError("only ordinary one/two-core profiles are supported")
    if "Kunminghu" not in source or "XS-AI" in source or "XSAI" in source:
        raise ValueError("input must come from ordinary Kunminghu")
    cpus = re.findall(r"\b([\w]+): cpu@([0-9a-f]+) \{", source)
    if sorted(int(hart, 16) for _, hart in cpus) != list(range(cores)):
        raise ValueError("generated CPU count does not match requested profile")
    plic = re.search(r"\b(\w+): interrupt-controller@3c000000 \{", source)
    if not plic:
        raise ValueError("native PLIC was not found")
    source, count = re.subn(
        r'(\w+: memory@80000000 \{.*?\breg = )<[^;]+>(;.*?\n\t\};)',
        r'\g<1><0x0 0x80000000 0x0 0x80000000>\2', source, flags=re.S)
    if count != 1:
        raise ValueError("expected exactly one native memory node")
    # Upstream emits a next-level-cache phandle to its memory node, not a
    # cache device. Omit this invalid topology hint, preserve ISA properties.
    source = re.sub(r'\s*next-level-cache = <[^;]+>;', '', source)
    source = source.replace('mmu-type = "riscv,sv50";', 'mmu-type = "riscv,sv48";')
    source = source.replace('clock-frequency = <0>;', 'clock-frequency = <50000000>;')
    source = source.replace('timebase-frequency;', 'timebase-frequency = <10000000>;')
    source = source.replace('timebase-frequency = <1000000>;', 'timebase-frequency = <10000000>;')
    source = source.replace('#interrupt-cells = <1>;', '#address-cells = <0>;\n\t\t\t#interrupt-cells = <1>;')
    plic_ref = plic.group(1)
    # The native dual-core bus-error node incorrectly emits two parents.
    source = source.replace(f'interrupt-parent = <&{plic_ref} &{plic_ref}>;',
                            f'interrupt-parent = <&{plic_ref}>;')
    source = source.replace('compatible = "xilinx,uartlite";',
                            'compatible = "xlnx,opb-uartlite-1.00.b";\n'
                            '            current-speed = <115200>;\n'
                            '            clock-frequency = <50000000>;\n'
                            f'            interrupt-parent = <&{plic_ref}>;\n'
                            '            interrupts = <4>;\n'
                            '            xlnx,data-bits = <8>;\n'
                            '            xlnx,use-parity = <0>;')
    source += f'''
/ {{
    chosen {{
        bootargs = "earlycon console=ttyUL0";
        stdout-path = "/soc/serial@40600000";
    }};
    soc {{
        pcie@60000000 {{
            compatible = "pci-host-ecam-generic";
            device_type = "pci";
            reg = <0x0 0x60000000 0x0 0x01000000>;
            #address-cells = <3>;
            #size-cells = <2>;
            #interrupt-cells = <1>;
            bus-range = <0 15>;
            ranges = <0x02000000 0x0 0x50000000 0x0 0x50000000 0x0 0x01000000>;
            dma-coherent;
            interrupt-parent = <&{plic_ref}>;
            interrupt-map-mask = <0 0 0 7>;
            interrupt-map = <0 0 0 1 &{plic_ref} 34>,
                            <0 0 0 2 &{plic_ref} 34>,
                            <0 0 0 3 &{plic_ref} 34>,
                            <0 0 0 4 &{plic_ref} 34>;
        }};
    }};
}};
'''
    return source


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--num-cores', required=True, type=int, choices=(1, 2))
    parser.add_argument('--source', type=Path, default=root / 'kmh/hardware/xs-gen/build/XSTop.dts')
    parser.add_argument('--output', type=Path, default=root / 'kmh/software/dt/kunminghu-scope.dts')
    parser.add_argument('--dtb', type=Path)
    args = parser.parse_args()
    result = render(args.source.read_text(), args.num_cores)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(result)
    if args.dtb:
        args.dtb.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['dtc', '-I', 'dts', '-O', 'dtb', '-o', str(args.dtb), str(args.output)], check=True)
    print(f'Ordinary Kunminghu {args.num_cores} core SCOPE DT: {args.output}')


if __name__ == '__main__':
    main()
