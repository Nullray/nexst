#!/usr/bin/env python3
"""Check real shell/role BD connectivity and ordinary CPU DMA exports."""
import argparse
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = '527a959fd056da2c1e15b262602aa7c413a6fd34c3fc06cb43eaaddd749f7efa'


def connected(design, pairs, scalar=False):
    table, field = ('nets','ports') if scalar else ('interface_nets','interface_ports')
    nets = [{v.lower() for v in n[field]} for n in design[table].values()]
    for a,b in pairs:
        if not any({a.lower(),b.lower()} <= n for n in nets):
            raise RuntimeError(f'missing connection: {a} -> {b}')


def bd(name, design):
    return json.loads((ROOT / f'work_farm/fpga/vivado_prj/{name}/{name}.srcs/sources_1/bd/{design}/{design}.bd').read_text())['design']


def mapped(design, cell, space, target, offset, size):
    segments=design['addressing']['/'+cell]['address_spaces'][space]['segments'].values()
    for segment in segments:
        if segment['address_block'].lower()==target.lower():
            assert int(segment['offset'],16)==offset,segment
            raw=segment['range']
            actual=int(raw[:-1])*(1 << (10*('KMGTPE'.index(raw[-1])+1))) if raw[-1] in 'KMGTPE' else int(raw,0)
            assert actual==size,segment
            return
    raise RuntimeError(f'missing address route: {cell}/{space} -> {target}')


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--shell-only',action='store_true');args=p.parse_args()
    assert hashlib.sha256((ROOT/'shell/common/fpga/virtual_pcie_switch_proxy.v').read_bytes()).hexdigest()==EXPECTED
    shell=bd('shell_uvhs2_uvhs2','xiangshan');cells=shell['components']
    for n,ref in [('scope_proxy','virtual_pcie_switch_proxy'),('scope_notify','scope_qdma_bridge_ring'),('scope_dma_alias','axi_alias_attr_bridge')]:
        assert cells[n]['reference_info']['ref_name']==ref,n
    params=cells['qdma_ep']['parameters'];assert params['functional_mode']['value']=='QDMA'
    for n in ['en_bridge_slv','axibar_notranslate','csr_axilite_slave']:
        assert str(params[n]['value']).lower() in {'true','1'},n
    connected(shell,[('u_role/m_axi_io','axi_ic_role_io/S00_AXI'),
        ('axi_ic_role_io/M01_AXI','scope_proxy/s_mmio_axi'),('axi_ic_role_io/M02_AXI','scope_proxy/s_ecam_axi'),
        ('scope_host_ctrl/M01_AXI','scope_proxy/s_mbx_axi'),('scope_host_ctrl/M03_AXI','scope_notify/s_axi'),
        ('scope_host_ctrl/M04_AXI','qdma_ep/S_AXI_LITE_CSR'),
        ('scope_proxy/m_axis_c2h','scope_notify_cdc/S_AXIS'),('scope_notify_cdc/M_AXIS','scope_notify/s_axis'),
        ('scope_notify/m_axi','qdma_ep/S_AXI_BRIDGE'),('qdma_ep/M_AXI_BRIDGE','scope_dma_route/S00_AXI'),
        ('scope_dma_route/M01_AXI','scope_dma_alias/S_AXI'),('scope_dma_alias/M_AXI','scope_dma_to_role/S00_AXI'),
        ('scope_dma_to_role/M00_AXI','u_role/s_axi_dma')])
    xci=ROOT/'work_farm/fpga/vivado_prj/shell_uvhs2_uvhs2/shell_uvhs2_uvhs2.srcs/sources_1/bd/xiangshan/ip/xiangshan_pcie_0/xiangshan_pcie_0.xci'
    pcie=json.loads(xci.read_text())['ip_inst']['parameters']['component_parameters']
    assert str(pcie['pf0_pasid_cap_enabled'][0]['value']).lower() in {'false','0'}
    assert str(pcie['TL_PF_ENABLE_REG'][0]['value'])=='1'
    connected(shell,[('scope_proxy/interrupt_out','scope_irq/In1'),('scope_irq/dout','u_role/s2r_intr')],scalar=True)
    mapped(shell,'qdma_ep','M_AXI_BRIDGE','/ddr4_mig/DDR4_MEMORY_MAP/DDR4_ADDRESS_BLOCK',0,1<<32)
    mapped(shell,'qdma_ep','M_AXI_BRIDGE','/scope_dma_alias/s_axi/reg0',1<<32,1<<32)
    mapped(shell,'scope_dma_alias','m_axi','/u_role/s_axi_dma/reg0',1<<31,1<<31)
    mapped(shell,'scope_notify','m_axi','/qdma_ep/S_AXI_BRIDGE/BAR0',0,1<<64)
    report={'dual_bar_frontend_unchanged':True,'slave_bridge_no_translation':True,'host_notification_ring':'SCB1','shell_dma_ingress_connected':True}
    if not args.shell_only:
        role=bd('target_kmh_proto_uvhs2','role')
        connected(role,[('s_axi_dma','scope_cpu_dma_ic/S00_AXI'),('scope_cpu_dma_ic/M00_AXI','xs_top/dma')])
        mapped(role,'','s_axi_dma','/xs_top/dma/reg0',1<<31,1<<31)
        wrapper=(ROOT/'kmh/fpga/sources/hdl/xstop_wrapper.v').read_text()
        names=re.findall(r'\.(dma_\w+)\(([^)]*)\)',wrapper)
        assert len(names)==37 and all(a==b for a,b in names)
        outer=(ROOT/'kmh/fpga/sources/wrapper/role_top_proto.v').read_text()
        assert len(re.findall(r'\.s_axi_dma_',outer))==37
        assert not re.search(r'assign\s+s_axi_dma_',outer)
        report['cpu_dma_exported_and_role_connected']=True
    (ROOT/'build').mkdir(exist_ok=True)
    report_name = 'FRONTEND_SHELL_CHECK.json' if args.shell_only else 'FRONTEND_CHECK.json'
    (ROOT/'build'/report_name).write_text(json.dumps(report,indent=2)+'\n')
    print('PASS: original dual-BAR vSwitch, coherent DMA ingress, No Address Translation host ring'+(' (shell only)' if args.shell_only else ' and CPU DMA'))


if __name__=='__main__':main()
