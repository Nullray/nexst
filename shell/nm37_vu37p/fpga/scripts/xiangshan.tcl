#========================================================
# Vivado BD design auto run script for XiangShan wrapper 
# on Xilinx XCVU39P
# Based on Vivado 2020.2
# Author: Yisong Chang (changyisong@ict.ac.cn)
# Updated for SCOPE Active Proxy Architecture
#========================================================

namespace eval mpsoc_bd_val {
	set design_name xiangshan
	set bd_prefix ${mpsoc_bd_val::design_name}_
}

# If you do not already have an existing IP Integrator design open,
# you can create a design using the following command:
#    create_bd_design $design_name

# Creating design if needed
set errMsg ""
set nRet 0

set cur_design [current_bd_design -quiet]
set list_cells [get_bd_cells -quiet]

if { ${mpsoc_bd_val::design_name} eq "" } {
   # USE CASES:
   #    1) Design_name not set

   set errMsg "Please set the variable <design_name> to a non-empty value."
   set nRet 1

} elseif { ${cur_design} ne "" && ${list_cells} eq "" } {
   # USE CASES:
   #    2): Current design opened AND is empty AND names same.
   #    3): Current design opened AND is empty AND names diff; design_name NOT in project.
   #    4): Current design opened AND is empty AND names diff; design_name exists in project.

   if { $cur_design ne ${mpsoc_bd_val::design_name} } {
      common::send_msg_id "BD_TCL-001" "INFO" "Changing value of <design_name> from <${mpsoc_bd_val::design_name}> to <$cur_design> since current design is empty."
      set design_name [get_property NAME $cur_design]
   }
   common::send_msg_id "BD_TCL-002" "INFO" "Constructing design in IPI design <$cur_design>..."

} elseif { ${cur_design} ne "" && $list_cells ne "" && $cur_design eq ${mpsoc_bd_val::design_name} } {
   # USE CASES:
   #    5) Current design opened AND has components AND same names.

   set errMsg "Design <${mpsoc_bd_val::design_name}> already exists in your project, please set the variable <design_name> to another value."
   set nRet 1
} elseif { [get_files -quiet ${mpsoc_bd_val::design_name}.bd] ne "" } {
   # USE CASES: 
   #    6) Current opened design, has components, but diff names, design_name exists in project.
   #    7) No opened design, design_name exists in project.

   set errMsg "Design <${mpsoc_bd_val::design_name}> already exists in your project, please set the variable <design_name> to another value."
   set nRet 2

} else {
   # USE CASES:
   #    8) No opened design, design_name not in project.
   #    9) Current opened design, has components, but diff names, design_name not in project.

   common::send_msg_id "BD_TCL-003" "INFO" "Currently there is no design <${mpsoc_bd_val::design_name}> in project, so creating one..."

   create_bd_design ${mpsoc_bd_val::design_name}

   common::send_msg_id "BD_TCL-004" "INFO" "Making design <${mpsoc_bd_val::design_name}> as current_bd_design."
   current_bd_design ${mpsoc_bd_val::design_name}

}

common::send_msg_id "BD_TCL-005" "INFO" "Currently the variable <design_name> is equal to \"${mpsoc_bd_val::design_name}\"."

if { $nRet != 0 } {
   catch {common::send_msg_id "BD_TCL-114" "ERROR" $errMsg}
   return $nRet
}

##################################################################
# DESIGN PROCs
##################################################################

# Procedure to create entire design; Provide argument to make
# procedure reusable. If parentCell is "", will use root.
proc create_root_design { parentCell } {

  variable script_folder

  if { $parentCell eq "" } {
     set parentCell [get_bd_cells /]
  }

  # Get object for parentCell
  set parentObj [get_bd_cells $parentCell]
  if { $parentObj == "" } {
     catch {common::send_msg_id "BD_TCL-100" "ERROR" "Unable to find parent cell <$parentCell>!"}
     return
  }

  # Make sure parentObj is hier blk
  set parentType [get_property TYPE $parentObj]
  if { $parentType ne "hier" } {
     catch {common::send_msg_id "BD_TCL-101" "ERROR" "Parent <$parentObj> has TYPE = <$parentType>. Expected to be <hier>."}
     return
  }

  # Save current instance; Restore later
  set oldCurInst [current_bd_instance .]

  # Set parent object as current
  current_bd_instance $parentObj

#=============================================
# Create IP blocks
#=============================================

  # [修改] 例化主动拦截网关 Proxy
  set block_name axilite_active_proxy 
  set block_cell_name axilite_active_proxy_0
  if { [catch {set u_role [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_msg_id "BD_TCL-105" "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
  } elseif { $u_role eq "" } {
     catch {common::send_msg_id "BD_TCL-106" "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
  }

  # Create instance: role_top
  set block_name role_top 
  set block_cell_name u_role
  if { [catch {set u_role [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_msg_id "BD_TCL-105" "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
  } elseif { $u_role eq "" } {
     catch {common::send_msg_id "BD_TCL-106" "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
  }

  # Create instance: DDR4 MIG 
    set ddr4_mig [ create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4:2.2 ddr4_mig ]
    set_property -dict [ list CONFIG.C0.DDR4_isCustom {false} \
        CONFIG.C0.DDR4_InputClockPeriod {10005} \
        CONFIG.C0.DDR4_TimePeriod {938} \
        CONFIG.C0.DDR4_MemoryType {SODIMMs} \
        CONFIG.C0.DDR4_MemoryPart {MTA16ATF2G64HZ-2G3} \
        CONFIG.C0.DDR4_AxiAddressWidth {34} \
        CONFIG.C0.DDR4_AxiDataWidth {512} \
        CONFIG.C0.DDR4_AxiIDWidth.VALUE_SRC {PROPAGATED} \
        CONFIG.C0.DDR4_DataWidth {64} \
        CONFIG.C0_DDR4_CasLatency {15} \
        CONFIG.System_Clock {Differential} \
    ] $ddr4_mig

  # Create instance: PCIe Endpoint
  set xdma_ep [ create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma_ep ]
  set_property -dict [list \
    CONFIG.functional_mode {DMA} \
    CONFIG.mode_selection {Advanced} \
    CONFIG.pcie_blk_locn {PCIE4C_X1Y0} \
    CONFIG.en_gt_selection {true} \
    CONFIG.select_quad {GTY_Quad_227} \
    CONFIG.pl_link_cap_max_link_width {X16} \
    CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
    CONFIG.xdma_axi_intf_mm {AXI_Stream} \
    CONFIG.axilite_master_en {true} \
      CONFIG.xdma_axilite_slave {true} \
    CONFIG.axilite_master_size {32} \
    CONFIG.axilite_master_scale {Megabytes} \
    CONFIG.pciebar2axibar_axil_master {0x10000000} \
    CONFIG.axist_bypass_en {true} \
      CONFIG.xdma_wnum_chnl {2} \
    CONFIG.axist_bypass_size {16} \
    CONFIG.axist_bypass_scale {Gigabytes} \
    CONFIG.axi_bypass_64bit_en {true} \
    CONFIG.axi_bypass_prefetchable {true} \
    CONFIG.cfg_mgmt_if {false} \
    CONFIG.pf0_base_class_menu {Processing_accelerators} \
    CONFIG.pf0_sub_class_interface_menu {Unknown} \
  ] $xdma_ep

  # Create instance: PCIe Root Port
  set xdma_rp [ create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma_rp ]
  set_property -dict [ list \
        CONFIG.mode_selection {Advanced} \
        CONFIG.device_port_type {Root_Port_of_PCI_Express_Root_Complex} \
        CONFIG.functional_mode {AXI Bridge} \
        CONFIG.dma_reset_source_sel {Phy_Ready} \
        CONFIG.en_gt_selection {true} \
        CONFIG.pl_link_cap_max_link_width {X4} \
        CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
        CONFIG.axi_addr_width {64} \
        CONFIG.pf0_class_code_sub {04} \
        CONFIG.pf0_bar0_enabled {false} \
        CONFIG.axibar2pciebar_0 {0x0000000050000000} \
        CONFIG.plltype {QPLL1} \
        CONFIG.msi_rx_pin_en {true} \
        CONFIG.select_quad {GTY_Quad_127} \
        CONFIG.pcie_blk_locn {PCIE4C_X0Y1} \
        CONFIG.BASEADDR {0x00000000} \
        CONFIG.HIGHADDR {0x007FFFFF} ] $xdma_rp

  set axi_dwidth_converter_0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dwidth_converter:2.1 axi_dwidth_converter_0 ]
  set_property -dict [list CONFIG.ADDR_WIDTH {64} \
                CONFIG.MI_DATA_WIDTH {128} \
                CONFIG.SI_DATA_WIDTH {64} ] $axi_dwidth_converter_0

  # Create instance: AXI interconnect for DDR4
  set axi_ic_ddr_mem [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_ddr_mem ]
  set_property -dict [ list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {2} \
  ] $axi_ic_ddr_mem

  set i 1
  while {$i < 1} {
        set axi_reg_slice_name axi_ic_ddr_mem_reg_slice_M0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util

        incr i
  }

  set i 1
  while {$i < 2} {
        set axi_reg_slice_name axi_ic_ddr_mem_reg_slice_S0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
                
        incr i
  }

  # [修改] 移除旧的 trace_bram AXI IC，新增供 QEMU 宿主机访问 VCONF 的 AXI IC
  set axi_ic_host_vconf [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_host_vconf ]
  set_property -dict [ list CONFIG.NUM_MI {3} \
                CONFIG.NUM_SI {1} \
  ] $axi_ic_host_vconf

  # Create instance: AXI interconnect for PCIe EP AXI-Lite BAR interface
  set axi_ic_ep_bar_axi_lite [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_ep_bar_axi_lite ]
  set_property -dict [ list CONFIG.NUM_MI {4} \
                CONFIG.NUM_SI {1} \
  ] $axi_ic_ep_bar_axi_lite

  set i 1
  while {$i < 2} {
        set axi_reg_slice_name axi_ic_ep_bar_axi_lite_reg_slice_M0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  set i 1
  while {$i < 1} {
        set axi_reg_slice_name axi_ic_ep_bar_axi_lite_reg_slice_S0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  # Create instance: AXI interconnect for Role MMIO
  set axi_ic_role_io [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_role_io ]
  set_property -dict [ list \
    CONFIG.NUM_MI {3} \
    CONFIG.NUM_SI {1} \
  ] $axi_ic_role_io

  set i 3
  while {$i < 3} {
        set axi_reg_slice_name axi_ic_role_io_reg_slice_M0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  set i 0
  while {$i < 1} {
        set axi_reg_slice_name axi_ic_role_io_reg_slice_S0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  # Create instance: AXI interconnect for Boot ROM
  set axi_ic_bootrom [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_bootrom ]
  set_property -dict [ list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {2} \
  ] $axi_ic_bootrom

  set i 1
  while {$i < 1} {
        set axi_reg_slice_name axi_ic_bootrom_reg_slice_M0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  set i 2
  while {$i < 2} {
        set axi_reg_slice_name axi_ic_bootrom_reg_slice_S0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  # Create instance: AXI interconnect for PCIe RP DMA 
  set axi_ic_pcie_rp_dma [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_pcie_rp_dma ]
  set_property -dict [ list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {1} \
    CONFIG.SI_DATA_WIDTH {128} \
    CONFIG.MI_DATA_WIDTH {64} \
  ] $axi_ic_pcie_rp_dma

  set i 0
  while {$i < 1} {
        set axi_reg_slice_name axi_ic_pcie_rp_dma_reg_slice_M0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  set i 1
  while {$i < 1} {
        set axi_reg_slice_name axi_ic_pcie_rp_dma_reg_slice_S0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  # Create instance: AXI interconnect for PCIe RP MMIO 
  set axi_ic_pcie_rp_mmio [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_pcie_rp_mmio ]
  set_property -dict [ list \
    CONFIG.NUM_MI {2} \
    CONFIG.NUM_SI {1} \
  ] $axi_ic_pcie_rp_mmio

  set i 2
  while {$i < 2} {
        set axi_reg_slice_name axi_ic_pcie_rp_mmio_reg_slice_M0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  set i 1
  while {$i < 1} {
        set axi_reg_slice_name axi_ic_pcie_rp_mmio_reg_slice_S0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  # Create instance: AXI UART Lite over PCIe for Host-side
  set host_uart [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 host_uart ]
  set_property -dict [ list CONFIG.C_BAUDRATE {115200} ] $host_uart

  # Create instance: AXI UART Lite for Role
  set role_uart [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 role_uart ]
  set_property -dict [ list CONFIG.C_BAUDRATE {115200} ] $role_uart

  # Create instance: Block memory generator for Boot ROM
  set bootrom_bram [ create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 bootrom_bram ]

  # Create instance: AXI BRAM controller for Boot ROM
  set bootrom_bram_ctrl [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 bootrom_bram_ctrl ]
  set_property -dict [ list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.PROTOCOL {AXI4LITE}] $bootrom_bram_ctrl

  # [修改] 实例化真双端口 VCONF BRAM 和对应的 BRAM Controllers
  set vconf_bram [ create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 vconf_bram ]
  set_property -dict [ list CONFIG.Memory_Type {True_Dual_Port_RAM} ] $vconf_bram

  set vconf_bram_ctrl_a [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 vconf_bram_ctrl_a ]
  set_property -dict [ list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.PROTOCOL {AXI4LITE}] $vconf_bram_ctrl_a

  set vconf_bram_ctrl_b [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 vconf_bram_ctrl_b ]
  set_property -dict [ list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.PROTOCOL {AXI4LITE}] $vconf_bram_ctrl_b

  # Create instance: IBUFDS_GTE for PCIe EP reference clock
  set pcie_ep_ref_clk_buf [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.1 pcie_ep_ref_clk_buf ]
  set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} $pcie_ep_ref_clk_buf

  # Create instance: IBUFDS_GTE for PCIe RP reference clock
  set pcie_rp_ref_clk_buf [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.1 pcie_rp_ref_clk_buf ]
  set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} $pcie_rp_ref_clk_buf

  catch {common::send_msg_id "BD_TCL-000" "INFO" "rp_clk ip read"}
  # constant for ready signal
  set const_vcc [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_vcc ]
  set_property -dict [list CONFIG.CONST_WIDTH {1} \
        CONFIG.CONST_VAL {0x1} ] $const_vcc

  set const_gnd [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_gnd ]
  set_property -dict [list CONFIG.CONST_WIDTH {1} \
        CONFIG.CONST_VAL {0x0} ] $const_gnd

#=============================================
# Clock ports
#=============================================

  # gt differential reference clock for pcie ep
  set pcie_ep_gt_ref_clk [ create_bd_intf_port -mode slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 pcie_ep_gt_ref_clk ]
  set_property -dict [ list config.freq_hz {100000000} ] $pcie_ep_gt_ref_clk

  # gt differential reference clock for pcie rp
  set pcie_rp_gt_ref_clk [ create_bd_intf_port -mode slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 pcie_rp_gt_ref_clk ]
  set_property -dict [ list config.freq_hz {100000000} ] $pcie_rp_gt_ref_clk

  # Differential system clock for DDR4 MIG
  set ddr4_mig_sys_clk [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 ddr4_mig_sys_clk ]
  set_property -dict [ list CONFIG.FREQ_HZ {100000000} ] $ddr4_mig_sys_clk

  
#=============================================
# Reset ports
#=============================================

  # PCIe EP perst
  create_bd_port -dir I -type rst pcie_ep_perstn

  # PCIe RP perst
  create_bd_port -dir O -type rst pcie_rp_perstn

  # Create instance: inverter of perstn from PCIe EP
  set ep_perst_gen [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 ep_perst_gen ]
  set_property -dict [ list CONFIG.C_OPERATION {not} \
      CONFIG.C_SIZE {1} ] $ep_perst_gen

  # Create instance: DDR MIG AXI sync. reset generation
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 ddr4_mig_sync_reset

  # Create instance: PCIe RP AXI sync. reset generation for the PERSTN signal
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 pcie_rp_sync_reset

  # Create instance: PCIe RP AXI sync. reset generation for the ROLE clock region
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 pcie_rp_role_sync_reset

#=============================================
# GT ports
#=============================================

  # PCIe EP Slot
  create_bd_port -dir I -from 15 -to 0 pcie_ep_rxn
  create_bd_port -dir I -from 15 -to 0 pcie_ep_rxp
  create_bd_port -dir O -from 15 -to 0 pcie_ep_txn
  create_bd_port -dir O -from 15 -to 0 pcie_ep_txp

  # PCIe RP Slot
  create_bd_port -dir I -from 3 -to 0 pcie_rp_rxn
  create_bd_port -dir I -from 3 -to 0 pcie_rp_rxp
  create_bd_port -dir O -from 3 -to 0 pcie_rp_txn
  create_bd_port -dir O -from 3 -to 0 pcie_rp_txp

#=============================================
# DDR4 pins
#=============================================
  
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddr4_rtl:1.0 c0_ddr4

#=============================================
# System clock connection
#=============================================

  # PCIe EP reference clock (100MHz)
  connect_bd_intf_net -intf_net pcie_ep_gt_ref_clk \
      [get_bd_intf_pins pcie_ep_gt_ref_clk] \
      [get_bd_intf_pins pcie_ep_ref_clk_buf/CLK_IN_D]

  connect_bd_net -net pcie_ep_sys_clk \
      [get_bd_pins pcie_ep_ref_clk_buf/IBUF_DS_ODIV2] \
      [get_bd_pins xdma_ep/sys_clk]

  connect_bd_net -net pcie_ep_sys_clk_gt \
      [get_bd_pins pcie_ep_ref_clk_buf/IBUF_OUT] \
      [get_bd_pins xdma_ep/sys_clk_gt]

  # PCIe RP reference clock (100MHz)
  connect_bd_intf_net -intf_net pcie_rp_gt_ref_clk \
      [get_bd_intf_pins pcie_rp_gt_ref_clk] \
      [get_bd_intf_pins pcie_rp_ref_clk_buf/CLK_IN_D]

  connect_bd_net -net pcie_rp_ref_clk \
      [get_bd_pins pcie_rp_ref_clk_buf/IBUF_DS_ODIV2] \
      [get_bd_pins xdma_rp/sys_clk]

  connect_bd_net -net pcie_rp_sys_clk \
      [get_bd_pins pcie_rp_ref_clk_buf/IBUF_OUT] \
      [get_bd_pins xdma_rp/sys_clk_gt]

  # DDR4 memory controller reference clock (100MHz)
  connect_bd_intf_net -intf_net ddr4_mig_sys_clk_in \
      [get_bd_intf_pins ddr4_mig_sys_clk] \
      [get_bd_intf_pins ddr4_mig/C0_SYS_CLK]

  # DDR4 controller ui clock (333.333MHz) for AXI IC and AXI interface
  connect_bd_net [get_bd_pins ddr4_mig/c0_ddr4_ui_clk] \
      [get_bd_pins axi_ic_ddr_mem/M00_ACLK] \
      [get_bd_pins ddr4_mig_sync_reset/slowest_sync_clk]

  # PCIe EP BAR interfaces (250MHz)
  connect_bd_net [get_bd_pins xdma_ep/axi_aclk] \
      [get_bd_pins axi_ic_ddr_mem/ACLK] \
      [get_bd_pins axi_ic_ddr_mem/S00_ACLK] \
      [get_bd_pins axi_ic_ddr_mem/S01_ACLK] \
      [get_bd_pins axi_ic_ddr_mem_reg_slice_S01/aclk] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/S00_ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M00_ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M01_ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite_reg_slice_M01/aclk] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M02_ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M03_ACLK] \
      [get_bd_pins axi_ic_host_vconf/ACLK] \
      [get_bd_pins axi_ic_host_vconf/S00_ACLK] \
      [get_bd_pins axi_ic_host_vconf/M00_ACLK] \
      [get_bd_pins axi_ic_host_vconf/M02_ACLK] \
      [get_bd_pins vconf_bram_ctrl_b/s_axi_aclk] \
      [get_bd_pins axi_ic_role_io/*ACLK] \
      [get_bd_pins axi_ic_role_io_reg_slice_S00/aclk] \
      [get_bd_pins axi_ic_pcie_rp_mmio/ACLK] \
      [get_bd_pins axi_ic_pcie_rp_mmio/S00_ACLK] \
      [get_bd_pins axi_ic_pcie_rp_dma/ACLK] \
      [get_bd_pins axi_ic_pcie_rp_dma/M00_ACLK] \
      [get_bd_pins axi_ic_pcie_rp_dma_reg_slice_M00/aclk] \
      [get_bd_pins axi_ic_bootrom/*ACLK] \
      [get_bd_pins bootrom_bram_ctrl/s_axi_aclk] \
      [get_bd_pins u_role/aclk] \
      [get_bd_pins pcie_rp_role_sync_reset/slowest_sync_clk] \
      [get_bd_pins role_uart/s_axi_aclk] \
      [get_bd_pins host_uart/s_axi_aclk] \
      [get_bd_pins axi_dwidth_converter_0/s_axi_aclk] 

  # PCIe RP AXI clock (250MHz)
  connect_bd_net [get_bd_pins xdma_rp/axi_aclk] \
      [get_bd_pins pcie_rp_sync_reset/slowest_sync_clk] \
      [get_bd_pins axi_ic_pcie_rp_dma/S00_ACLK] \
      [get_bd_pins axi_ic_pcie_rp_mmio/M*_ACLK] \
      [get_bd_pins axilite_active_proxy_0/clk] \
      [get_bd_pins vconf_bram_ctrl_a/s_axi_aclk] \
      [get_bd_pins axi_ic_host_vconf/M01_ACLK] 

#=============================================
# System reset connection
#=============================================

  # perstn input for AXI PCIe EP (used as system reset)
  connect_bd_net -net pcie_ep_perstn [get_bd_ports pcie_ep_perstn] \
      [get_bd_pins xdma_ep/sys_rst_n] \
      [get_bd_pins xdma_rp/sys_rst_n] \
      [get_bd_pins pcie_rp_sync_reset/ext_reset_in] \
      [get_bd_pins ddr4_mig_sync_reset/ext_reset_in]

  # System reset for PL DDR4 MIG (opposite polarity of PCIe EP perstn, active high)
  connect_bd_net -net pcie_ep_perstn [get_bd_pins ep_perst_gen/Op1]

  connect_bd_net -net pcie_ep_perst [get_bd_pins ep_perst_gen/Res] \
      [get_bd_pins ddr4_mig/sys_rst]

  # PCIe EP AXI interface reset
  connect_bd_net [get_bd_pins xdma_ep/axi_aresetn] \
      [get_bd_pins axi_ic_ddr_mem/ARESETN] \
      [get_bd_pins axi_ic_ddr_mem/S00_ARESETN] \
      [get_bd_pins axi_ic_ddr_mem/S01_ARESETN] \
      [get_bd_pins axi_ic_ddr_mem_reg_slice_S*/aresetn] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/S00_ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M00_ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M01_ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite_reg_slice_M01/aresetn] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M02_ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M03_ARESETN] \
      [get_bd_pins axi_ic_host_vconf/ARESETN] \
      [get_bd_pins axi_ic_host_vconf/S00_ARESETN] \
      [get_bd_pins axi_ic_host_vconf/M00_ARESETN] \
      [get_bd_pins axi_ic_host_vconf/M02_ARESETN] \
      [get_bd_pins vconf_bram_ctrl_b/s_axi_aresetn] \
      [get_bd_pins axi_ic_role_io/ARESETN] \
      [get_bd_pins axi_ic_role_io/S00_ARESETN] \
      [get_bd_pins axi_ic_role_io_reg_slice_S00/aresetn] \
      [get_bd_pins axi_ic_role_io/M00_ARESETN] \
      [get_bd_pins axi_ic_role_io/M01_ARESETN] \
      [get_bd_pins axi_ic_bootrom/*ARESETN] \
      [get_bd_pins bootrom_bram_ctrl/s_axi_aresetn] \
      [get_bd_pins u_role/aresetn] \
      [get_bd_pins role_uart/s_axi_aresetn] \
      [get_bd_pins host_uart/s_axi_aresetn] \
      [get_bd_pins axi_dwidth_converter_0/s_axi_aresetn] 

  connect_bd_net [get_bd_pins pcie_rp_role_sync_reset/peripheral_aresetn] \
      [get_bd_pins axi_ic_role_io/M02_ARESETN] \
      [get_bd_pins axi_ic_pcie_rp_mmio/S00_ARESETN] \
      [get_bd_pins axi_ic_pcie_rp_dma/M00_ARESETN] \
      [get_bd_pins axi_ic_pcie_rp_dma_reg_slice_M00/aresetn]

  connect_bd_net [get_bd_pins pcie_rp_sync_reset/peripheral_aresetn] \
      [get_bd_ports pcie_rp_perstn]

  connect_bd_net [get_bd_pins pcie_rp_role_sync_reset/interconnect_aresetn] \
      [get_bd_pins axi_ic_pcie_rp_mmio/ARESETN] \
      [get_bd_pins axi_ic_pcie_rp_dma/ARESETN]

  # Reset for AXI interface of PCIe RP 
  connect_bd_net [get_bd_pins xdma_rp/axi_aresetn] \
      [get_bd_pins axi_ic_pcie_rp_dma/S00_ARESETN] \
      [get_bd_pins axi_ic_pcie_rp_mmio/M00_ARESETN]

  connect_bd_net [get_bd_pins xdma_rp/axi_ctl_aresetn] \
      [get_bd_pins pcie_rp_sync_reset/dcm_locked] \
      [get_bd_pins pcie_rp_role_sync_reset/ext_reset_in] \
      [get_bd_pins axi_ic_pcie_rp_mmio/M01_ARESETN] \
      [get_bd_pins axilite_active_proxy_0/rst] \
      [get_bd_pins vconf_bram_ctrl_a/s_axi_aresetn] \
      [get_bd_pins axi_ic_host_vconf/M01_ARESETN] 

  # Reset signals for DDR4 MIG related AXI interfaces in MIG ui clock domain
  connect_bd_net -net mig_calib_done [get_bd_pins ddr4_mig/c0_init_calib_complete] \
      [get_bd_ports ddr4_mig_sync_reset/dcm_locked]

  connect_bd_net [get_bd_pins ddr4_mig_sync_reset/peripheral_aresetn] \
      [get_bd_pins ddr4_mig/c0_ddr4_aresetn] \
      [get_bd_pins axi_ic_ddr_mem/M00_ARESETN]


#=============================================
# AXI interface connection
#=============================================

  # AXI-IC of DDR4 MIG
  connect_bd_intf_net [get_bd_intf_pins ddr4_mig/C0_DDR4_S_AXI] \
        [get_bd_intf_pins axi_ic_ddr_mem/M00_AXI]

  # PCIe EP AXI Bridge to DDR4
  connect_bd_intf_net [get_bd_intf_pins xdma_ep/M_AXI_BYPASS] \
        [get_bd_intf_pins axi_ic_ddr_mem/S00_AXI]

  # Role to DDR4.  The SQE write-done monitor is a transparent AXI
  # pass-through inserted at the DDR-side register-slice output, so the
  # original path remains intact while the monitor observes real AW/B handshakes.
  set block_name sqe_write_done_monitor
  set block_cell_name sqe_write_done_monitor_0
  if { [catch {set u_sqe_write_done_monitor [create_bd_cell -type module -reference $block_name $block_cell_name] } errmsg] } {
     catch {common::send_msg_id "BD_TCL-105" "ERROR" "Unable to add referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
  } elseif { $u_sqe_write_done_monitor eq "" } {
     catch {common::send_msg_id "BD_TCL-106" "ERROR" "Unable to referenced block <$block_name>. Please add the files for ${block_name}'s definition into the project."}
     return 1
  }

  connect_bd_intf_net [get_bd_intf_pins u_role/m_axi_mem] \
        [get_bd_intf_pins axi_ic_ddr_mem_reg_slice_S01/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ddr_mem_reg_slice_S01/M_AXI] \
        [get_bd_intf_pins sqe_write_done_monitor_0/s_mon_axi]
  connect_bd_intf_net [get_bd_intf_pins sqe_write_done_monitor_0/m_mon_axi] \
        [get_bd_intf_pins axi_ic_ddr_mem/S01_AXI]

  # AXI-IC of PCIe EP AXI Lite
  connect_bd_intf_net [get_bd_intf_pins xdma_ep/M_AXI_LITE] \
        [get_bd_intf_pins axi_ic_ep_bar_axi_lite/S00_AXI]

  # PCIe EP to Host-side UART
  connect_bd_intf_net [get_bd_intf_pins host_uart/S_AXI] \
        [get_bd_intf_pins axi_ic_ep_bar_axi_lite/M00_AXI]

  # PCIe EP to Role ctrl
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ep_bar_axi_lite/M01_AXI] \
        [get_bd_intf_pins axi_ic_ep_bar_axi_lite_reg_slice_M01/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ep_bar_axi_lite_reg_slice_M01/M_AXI] \
        [get_bd_intf_pins u_role/s_axi_ctrl]

  # PCIe EP to Boot ROM IC
  connect_bd_intf_net [get_bd_intf_pins axi_ic_bootrom/S01_AXI] \
        [get_bd_intf_pins axi_ic_ep_bar_axi_lite/M02_AXI]

  # AXI-IC of Role MMIO
  connect_bd_intf_net [get_bd_intf_pins u_role/m_axi_io] \
        [get_bd_intf_pins axi_ic_role_io_reg_slice_S00/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_role_io_reg_slice_S00/M_AXI] \
        [get_bd_intf_pins axi_ic_role_io/S00_AXI]

  # Role to UART
  connect_bd_intf_net [get_bd_intf_pins role_uart/S_AXI] \
        [get_bd_intf_pins axi_ic_role_io/M00_AXI]

  # Role to Boot ROM IC
  connect_bd_intf_net [get_bd_intf_pins axi_ic_bootrom/S00_AXI] \
        [get_bd_intf_pins axi_ic_role_io/M01_AXI]

  # AXI-IC of Boot ROM
  connect_bd_intf_net [get_bd_intf_pins bootrom_bram_ctrl/S_AXI] \
        [get_bd_intf_pins axi_ic_bootrom/M00_AXI]

  # PCIe RP DMA port to ROLE DMA interface
  connect_bd_intf_net [get_bd_intf_pins xdma_rp/M_AXI_B] \
        [get_bd_intf_pins axi_ic_pcie_rp_dma/S00_AXI]

  connect_bd_intf_net [get_bd_intf_pins axi_ic_pcie_rp_dma/M00_AXI] \
        [get_bd_intf_pins axi_ic_pcie_rp_dma_reg_slice_M00/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_pcie_rp_dma_reg_slice_M00/M_AXI] \
        [get_bd_intf_pins axi_dwidth_converter_0/S_AXI]

  connect_bd_intf_net [get_bd_intf_pins u_role/s_axi_dma] \
        [get_bd_intf_pins axi_dwidth_converter_0/M_AXI]

  #PCIe RP ctrl/BAR port to ROLE MMIO interface
  connect_bd_intf_net [get_bd_intf_pins axi_ic_pcie_rp_mmio/S00_AXI] \
        [get_bd_intf_pins axi_ic_role_io/M02_AXI]

  # [修改] 代理网关 Proxy 到 RP 的连线
  connect_bd_intf_net [get_bd_intf_pins axilite_active_proxy_0/s_axi] \
        [get_bd_intf_pins axi_ic_pcie_rp_mmio/M01_AXI]

  # [修改] BAR 代理直接插在 XDMA RP S_AXI_B 前
  connect_bd_intf_net [get_bd_intf_pins axilite_active_proxy_0/s_bar_axi] \
        [get_bd_intf_pins axi_ic_pcie_rp_mmio/M00_AXI]

  connect_bd_intf_net [get_bd_intf_pins axilite_active_proxy_0/m_bar_axi] \
        [get_bd_intf_pins xdma_rp/S_AXI_B]
        
  connect_bd_intf_net [get_bd_intf_pins axilite_active_proxy_0/m_axi] \
        [get_bd_intf_pins xdma_rp/S_AXI_LITE]

  # [修改] 代理网关 Proxy 到 虚拟配置空间 BRAM (Port A)
  connect_bd_intf_net [get_bd_intf_pins axilite_active_proxy_0/m_vconf_axi] \
        [get_bd_intf_pins vconf_bram_ctrl_a/S_AXI]

  # [修改] QEMU 宿主机 (EP) 到 VCONF Interconnect 的连线
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ep_bar_axi_lite/M03_AXI] \
        [get_bd_intf_pins axi_ic_host_vconf/S00_AXI]

  # [修改] VCONF Interconnect 到 BRAM (Port B)
  connect_bd_intf_net [get_bd_intf_pins axi_ic_host_vconf/M00_AXI] \
        [get_bd_intf_pins vconf_bram_ctrl_b/S_AXI]

  # [修改] VCONF Interconnect 到 Proxy 内部的 Mailbox
  connect_bd_intf_net [get_bd_intf_pins axi_ic_host_vconf/M01_AXI] \
        [get_bd_intf_pins axilite_active_proxy_0/s_mbx_axi]

  # Flat DDR map for PCIe EP bypass: keep the raw XDMA bypass
  # address as the DDR address instead of windowing low 28 bits
  # through a separate window register.

#=============================================
# AXI stream interface connection
#=============================================

  connect_bd_intf_net [get_bd_intf_pins u_role/m_axis_trace] \
      [get_bd_intf_pins xdma_ep/S_AXIS_C2H_0]

  # AXIS CDC bridge for proxy notify packets
  set axis_cc_proxy_c2h1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_clock_converter:1.1 axis_cc_proxy_c2h1 ]

  set_property -dict [list CONFIG.HAS_TKEEP.VALUE_SRC USER CONFIG.HAS_TLAST.VALUE_SRC USER CONFIG.TDATA_NUM_BYTES.VALUE_SRC PROPAGATED] [get_bd_cells axis_cc_proxy_c2h1]
  set_property -dict [list CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1}] [get_bd_cells axis_cc_proxy_c2h1]

  # Short register slices around the proxy/SQE C2H merge reduce timing pressure
  # from the active proxy packet engine, monitor packet engine, and final XDMA sink.
  set axis_rs_active_proxy_c2h [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:1.1 axis_rs_active_proxy_c2h ]
  set_property -dict [list CONFIG.HAS_TKEEP.VALUE_SRC USER CONFIG.HAS_TLAST.VALUE_SRC USER CONFIG.TDATA_NUM_BYTES.VALUE_SRC USER] [get_bd_cells axis_rs_active_proxy_c2h]
  set_property -dict [list CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1} CONFIG.TDATA_NUM_BYTES {64}] [get_bd_cells axis_rs_active_proxy_c2h]

  set axis_rs_sqe_done_c2h [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:1.1 axis_rs_sqe_done_c2h ]
  set_property -dict [list CONFIG.HAS_TKEEP.VALUE_SRC USER CONFIG.HAS_TLAST.VALUE_SRC USER CONFIG.TDATA_NUM_BYTES.VALUE_SRC USER] [get_bd_cells axis_rs_sqe_done_c2h]
  set_property -dict [list CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1} CONFIG.TDATA_NUM_BYTES {64}] [get_bd_cells axis_rs_sqe_done_c2h]

  set axis_rs_proxy_c2h_out [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_register_slice:1.1 axis_rs_proxy_c2h_out ]
  set_property -dict [list CONFIG.HAS_TKEEP.VALUE_SRC USER CONFIG.HAS_TLAST.VALUE_SRC USER CONFIG.TDATA_NUM_BYTES.VALUE_SRC USER] [get_bd_cells axis_rs_proxy_c2h_out]
  set_property -dict [list CONFIG.HAS_TKEEP {1} CONFIG.HAS_TLAST {1} CONFIG.TDATA_NUM_BYTES {64}] [get_bd_cells axis_rs_proxy_c2h_out]

  # Merge active-proxy packets with SQE write-complete packets before XDMA C2H_1.
  set axis_ic_proxy_c2h1 [ create_bd_cell -type ip -vlnv xilinx.com:ip:axis_interconnect:2.1 axis_ic_proxy_c2h1 ]
  set_property -dict [ list CONFIG.NUM_SI {2} \
        CONFIG.NUM_MI {1} \
        CONFIG.ENABLE_ADVANCED_OPTIONS {1} \
        CONFIG.XBAR_TDATA_NUM_BYTES.VALUE_SRC {USER} \
        CONFIG.XBAR_TDATA_NUM_BYTES {64} \
        CONFIG.ARB_ON_TLAST {1} \
        CONFIG.ARB_ON_MAX_XFERS {0} \
        CONFIG.S00_FIFO_MODE {1} \
        CONFIG.S00_FIFO_DEPTH {64} \
        CONFIG.S01_FIFO_MODE {1} \
        CONFIG.S01_FIFO_DEPTH {64} \
        CONFIG.M00_FIFO_MODE {1} \
        CONFIG.M00_FIFO_DEPTH {64} ] $axis_ic_proxy_c2h1

  # [新增] QEMU 直接配置 SQE write-done monitor，配置口和 DDR monitor
  # 位于同一个 xdma_ep/axi_aclk 时钟域，避免 queue-window CDC。
  connect_bd_intf_net [get_bd_intf_pins axi_ic_host_vconf/M02_AXI] \
        [get_bd_intf_pins sqe_write_done_monitor_0/s_cfg_axi]
  
  connect_bd_net [get_bd_pins xdma_rp/axi_aclk] \
      [get_bd_pins axis_rs_active_proxy_c2h/aclk] \
      [get_bd_pins axis_cc_proxy_c2h1/s_axis_aclk]
  connect_bd_net [get_bd_pins xdma_rp/axi_aresetn] \
      [get_bd_pins axis_rs_active_proxy_c2h/aresetn] \
      [get_bd_pins axis_cc_proxy_c2h1/s_axis_aresetn]
  connect_bd_net [get_bd_pins xdma_ep/axi_aclk] [get_bd_pins axis_cc_proxy_c2h1/m_axis_aclk]
  connect_bd_net [get_bd_pins xdma_ep/axi_aresetn] [get_bd_pins axis_cc_proxy_c2h1/m_axis_aresetn]
  connect_bd_net [get_bd_pins xdma_ep/axi_aclk] \
      [get_bd_pins axis_ic_proxy_c2h1/ACLK] \
      [get_bd_pins axis_ic_proxy_c2h1/S00_AXIS_ACLK] \
      [get_bd_pins axis_ic_proxy_c2h1/S01_AXIS_ACLK] \
      [get_bd_pins axis_ic_proxy_c2h1/M00_AXIS_ACLK] \
      [get_bd_pins axis_rs_sqe_done_c2h/aclk] \
      [get_bd_pins axis_rs_proxy_c2h_out/aclk] \
      [get_bd_pins sqe_write_done_monitor_0/clk]
  connect_bd_net [get_bd_pins xdma_ep/axi_aresetn] \
      [get_bd_pins axis_ic_proxy_c2h1/ARESETN] \
      [get_bd_pins axis_ic_proxy_c2h1/S00_AXIS_ARESETN] \
      [get_bd_pins axis_ic_proxy_c2h1/S01_AXIS_ARESETN] \
      [get_bd_pins axis_ic_proxy_c2h1/M00_AXIS_ARESETN] \
      [get_bd_pins axis_rs_sqe_done_c2h/aresetn] \
      [get_bd_pins axis_rs_proxy_c2h_out/aresetn] \
      [get_bd_pins sqe_write_done_monitor_0/rstn]

  connect_bd_intf_net [get_bd_intf_pins axilite_active_proxy_0/m_axis_c2h] [get_bd_intf_pins axis_rs_active_proxy_c2h/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins axis_rs_active_proxy_c2h/M_AXIS] [get_bd_intf_pins axis_cc_proxy_c2h1/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins axis_cc_proxy_c2h1/M_AXIS] [get_bd_intf_pins axis_ic_proxy_c2h1/S00_AXIS]
  connect_bd_intf_net [get_bd_intf_pins sqe_write_done_monitor_0/m_axis_c2h] [get_bd_intf_pins axis_rs_sqe_done_c2h/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins axis_rs_sqe_done_c2h/M_AXIS] [get_bd_intf_pins axis_ic_proxy_c2h1/S01_AXIS]
  connect_bd_intf_net [get_bd_intf_pins axis_ic_proxy_c2h1/M00_AXIS] [get_bd_intf_pins axis_rs_proxy_c2h_out/S_AXIS]
  connect_bd_intf_net [get_bd_intf_pins axis_rs_proxy_c2h_out/M_AXIS] [get_bd_intf_pins xdma_ep/S_AXIS_C2H_1]

  set const_vcc_sinks [list]
  foreach pin_name {
      xdma_ep/m_axis_h2c_tready_0
      xdma_ep/m_axis_h2c_tready_1
      pcie_rp_role_sync_reset/dcm_locked
  } {
      set pin [get_bd_pins -quiet $pin_name]
      if {$pin ne ""} {
          lappend const_vcc_sinks $pin
      }
  }
  if {[llength $const_vcc_sinks] > 0} {
      connect_bd_net [get_bd_pins const_vcc/dout] {*}$const_vcc_sinks
  }

#==============================================
# GT Port connection
#==============================================

  # PCIe EP slot
  connect_bd_net [get_bd_ports pcie_ep_rxn] [get_bd_pins xdma_ep/pci_exp_rxn]
  connect_bd_net [get_bd_ports pcie_ep_rxp] [get_bd_pins xdma_ep/pci_exp_rxp]
  connect_bd_net [get_bd_ports pcie_ep_txn] [get_bd_pins xdma_ep/pci_exp_txn]
  connect_bd_net [get_bd_ports pcie_ep_txp] [get_bd_pins xdma_ep/pci_exp_txp]

  # PCIe RP slot
  connect_bd_net [get_bd_ports pcie_rp_rxn] [get_bd_pins xdma_rp/pci_exp_rxn]
  connect_bd_net [get_bd_ports pcie_rp_rxp] [get_bd_pins xdma_rp/pci_exp_rxp]
  connect_bd_net [get_bd_ports pcie_rp_txn] [get_bd_pins xdma_rp/pci_exp_txn]
  connect_bd_net [get_bd_ports pcie_rp_txp] [get_bd_pins xdma_rp/pci_exp_txp]

#==============================================
# DDR4 memory connection
#==============================================

  connect_bd_intf_net [get_bd_intf_pins ddr4_mig/C0_DDR4] [get_bd_intf_ports c0_ddr4]

#==============================================
# MISC signals connection
#==============================================

  connect_bd_net [get_bd_pins host_uart/rx] \
      [get_bd_pins role_uart/tx]

  connect_bd_net [get_bd_pins host_uart/tx] \
      [get_bd_pins role_uart/rx]

  connect_bd_intf_net [get_bd_intf_pins bootrom_bram_ctrl/BRAM_PORTA] \
      [get_bd_intf_pins bootrom_bram/BRAM_PORTA]

  # [修改] 虚拟配置空间 BRAM 的双端连接
  connect_bd_intf_net [get_bd_intf_pins vconf_bram_ctrl_a/BRAM_PORTA] \
      [get_bd_intf_pins vconf_bram/BRAM_PORTA]

  connect_bd_intf_net [get_bd_intf_pins vconf_bram_ctrl_b/BRAM_PORTA] \
      [get_bd_intf_pins vconf_bram/BRAM_PORTB]

#=============================================
# Interrupt signal connection
#=============================================

  set role_intr_concat [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 role_intr_concat ]
    set_property -dict [list CONFIG.NUM_PORTS {16}] $role_intr_concat

  connect_bd_net [get_bd_pins role_uart/interrupt] [get_bd_pins role_intr_concat/In0]
  connect_bd_net [get_bd_pins host_uart/interrupt] [get_bd_pins xdma_ep/usr_irq_req]

  connect_bd_net -net proxy_interrupt_out [get_bd_pins axilite_active_proxy_0/interrupt_out] [get_bd_pins role_intr_concat/In1]
  connect_bd_net -net xdma_rp_interrupt_out_msi_vec0to31 [get_bd_pins xdma_rp/interrupt_out_msi_vec0to31] [get_bd_pins role_intr_concat/In2]
  connect_bd_net -net xdma_rp_interrupt_out_msi_vec32to63 [get_bd_pins xdma_rp/interrupt_out_msi_vec32to63] [get_bd_pins role_intr_concat/In3]
  
  connect_bd_net [get_bd_pins const_gnd/dout] \
    [get_bd_pins role_intr_concat/In4] \
    [get_bd_pins role_intr_concat/In5] \
    [get_bd_pins role_intr_concat/In6] \
    [get_bd_pins role_intr_concat/In7] \
    [get_bd_pins role_intr_concat/In8] \
    [get_bd_pins role_intr_concat/In9] \
    [get_bd_pins role_intr_concat/In10] \
    [get_bd_pins role_intr_concat/In11] \
    [get_bd_pins role_intr_concat/In12] \
    [get_bd_pins role_intr_concat/In13] \
    [get_bd_pins role_intr_concat/In14] \
    [get_bd_pins role_intr_concat/In15]

  connect_bd_net [get_bd_pins role_intr_concat/dout] [get_bd_pins u_role/s2r_intr]

#=============================================
# ILA
#=============================================

  # [新增] 抓取 FPGA XDMA EP bypass BAR 到 DDR 的 AXI-MM P2P 访问，
  # 同时抓取 guest/role 写 DDR 的 m_axi_mem 路径。两个 slot 在同一个
  # xdma_ep/axi_aclk 时钟域内，便于对齐 SQE 写入和 QEMU/真实 NVMe bypass 读取。
  set system_ila_4 [ create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 system_ila_4 ]
  set_property -dict [ list \
    CONFIG.C_NUM_MONITOR_SLOTS {2} \
    CONFIG.C_BRAM_CNT {192} \
    CONFIG.C_DATA_DEPTH {4096}
   ] $system_ila_4

  connect_bd_net [get_bd_pins xdma_ep/axi_aclk] [get_bd_pins system_ila_4/clk]
  connect_bd_net [get_bd_pins xdma_ep/axi_aresetn] [get_bd_pins system_ila_4/resetn]
  # SLOT_0_AXI: x86/QEMU/真实 NVMe 通过 XDMA EP bypass BAR 访问 DDR。
  connect_bd_intf_net [get_bd_intf_pins system_ila_4/SLOT_0_AXI] [get_bd_intf_pins xdma_ep/M_AXI_BYPASS]
  # SLOT_1_AXI: monitor 看到并用于生成 SQE_WRITE_DONE 的 DDR-side AXI 事务。
  connect_bd_intf_net [get_bd_intf_pins system_ila_4/SLOT_1_AXI] [get_bd_intf_pins sqe_write_done_monitor_0/m_mon_axi]

  # SQE write-done packet stream visibility. SLOT_0 catches the raw monitor
  # event; SLOT_1 catches the merged C2H stream after active-proxy arbitration.
  set system_ila_5 [ create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 system_ila_5 ]
  set_property -dict [ list \
    CONFIG.C_NUM_MONITOR_SLOTS {2} \
    CONFIG.C_MON_TYPE {INTERFACE} \
    CONFIG.C_SLOT_0_INTF_TYPE {xilinx.com:interface:axis_rtl:1.0} \
    CONFIG.C_SLOT_1_INTF_TYPE {xilinx.com:interface:axis_rtl:1.0} \
    CONFIG.C_DATA_DEPTH {2048}
   ] $system_ila_5

  connect_bd_net [get_bd_pins xdma_ep/axi_aclk] [get_bd_pins system_ila_5/clk]
  connect_bd_net [get_bd_pins xdma_ep/axi_aresetn] [get_bd_pins system_ila_5/resetn]
  connect_bd_intf_net [get_bd_intf_pins system_ila_5/SLOT_0_AXIS] [get_bd_intf_pins sqe_write_done_monitor_0/m_axis_c2h]
  connect_bd_intf_net [get_bd_intf_pins system_ila_5/SLOT_1_AXIS] [get_bd_intf_pins axis_rs_proxy_c2h_out/M_AXIS]



#=============================================
# Address segments
#=============================================

  ## PCIe EP address space
  create_bd_addr_seg -range 0x10000 -offset 0x10000000 [get_bd_addr_spaces xdma_ep/M_AXI_LITE] [get_bd_addr_segs bootrom_bram_ctrl/S_AXI/Mem0] PCIE_EP_BAR_BOOTROM
  create_bd_addr_seg -range 0x1000 -offset 0x10011000 [get_bd_addr_spaces xdma_ep/M_AXI_LITE] [get_bd_addr_segs host_uart/S_AXI/Reg] PCIE_EP_BAR_HOST_UART
  create_bd_addr_seg -range 0x100000 -offset 0x10100000 [get_bd_addr_spaces xdma_ep/M_AXI_LITE] [get_bd_addr_segs u_role/s_axi_ctrl/reg0] PCIE_EP_BAR_ROLE_CTRL
  
  # [新增] QEMU 宿主机访问的 Mailbox 和 VCONF BRAM 地址映射
  create_bd_addr_seg -range 0x1000 -offset 0x11000000 [get_bd_addr_spaces xdma_ep/M_AXI_LITE] [get_bd_addr_segs axilite_active_proxy_0/s_mbx_axi/reg0] HOST_MBX_REG
  create_bd_addr_seg -range 0x1000 -offset 0x11001000 [get_bd_addr_spaces xdma_ep/M_AXI_LITE] [get_bd_addr_segs sqe_write_done_monitor_0/s_cfg_axi/reg0] HOST_SQE_MONITOR_CFG
  create_bd_addr_seg -range 0x1000 -offset 0x11010000 [get_bd_addr_spaces xdma_ep/M_AXI_LITE] [get_bd_addr_segs vconf_bram_ctrl_b/S_AXI/Mem0] HOST_VCONF_BRAM
  
  create_bd_addr_seg -range 0x100000000 -offset 0x0 [get_bd_addr_spaces xdma_ep/M_AXI_BYPASS] [get_bd_addr_segs ddr4_mig/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK] PCIE_EP_BAR_DDR

  ## Role address space
  create_bd_addr_seg -range 0x10000 -offset 0x10000000 [get_bd_addr_spaces u_role/m_axi_io] [get_bd_addr_segs bootrom_bram_ctrl/S_AXI/Mem0] ROLE_BOOTROM
  create_bd_addr_seg -range 0x00100000 -offset 0x50000000 [get_bd_addr_spaces u_role/m_axi_io] [get_bd_addr_segs axilite_active_proxy_0/s_bar_axi/reg0] PCIE_RP_S_BAR
  
  # [修改] 香山 DUT 经由 Proxy 访问的透传段和虚拟配置空间段
  create_bd_addr_seg -range 0x00800000 -offset 0x60000000 [get_bd_addr_spaces u_role/m_axi_io] [get_bd_addr_segs axilite_active_proxy_0/s_axi/reg0] TRACE_RP_REG
  create_bd_addr_seg -range 0x00800000 -offset 0x60000000 [get_bd_addr_spaces axilite_active_proxy_0/m_axi] [get_bd_addr_segs xdma_rp/S_AXI_LITE/CTL0] PCIE_RP_S_LITE
  create_bd_addr_seg -range 0x00100000 -offset 0x50000000 [get_bd_addr_spaces axilite_active_proxy_0/m_bar_axi] [get_bd_addr_segs xdma_rp/S_AXI_B/BAR0] PROXY_RP_S_BAR
  create_bd_addr_seg -range 0x1000 -offset 0x0 [get_bd_addr_spaces axilite_active_proxy_0/m_vconf_axi] [get_bd_addr_segs vconf_bram_ctrl_a/S_AXI/Mem0] DUT_VCONF_BRAM
  
  create_bd_addr_seg -range 0x000080000000 -offset 0x80000000 [get_bd_addr_spaces xdma_rp/M_AXI_B] [get_bd_addr_segs u_role/s_axi_dma/reg0] PCIE_RP_DMA
  create_bd_addr_seg -range 0x10000 -offset 0x30000000 [get_bd_addr_spaces u_role/m_axi_io] [get_bd_addr_segs role_uart/S_AXI/Reg] ROLE_UART
  # The SQE monitor is an RTL pass-through, not a BD address-transparent interconnect.
  # Model the role DDR path as two address segments: role -> monitor slave, then
  # monitor master -> DDR.  This keeps Address Editor paths valid after insertion.
  set sqe_mon_s_seg [get_bd_addr_segs -quiet sqe_write_done_monitor_0/s_mon_axi/reg0]
  if {$sqe_mon_s_seg eq ""} {
      set sqe_mon_s_seg [lindex [get_bd_addr_segs -quiet sqe_write_done_monitor_0/s_mon_axi/*] 0]
  }
  if {$sqe_mon_s_seg eq ""} {
      catch {common::send_msg_id "BD_TCL-107" "ERROR" "Unable to find address segment for sqe_write_done_monitor_0/s_mon_axi"}
      return 1
  }
  create_bd_addr_seg -range 0x100000000 -offset 0x0 [get_bd_addr_spaces u_role/m_axi_mem] $sqe_mon_s_seg ROLE_DDR_MONITOR
  create_bd_addr_seg -range 0x100000000 -offset 0x0 [get_bd_addr_spaces sqe_write_done_monitor_0/m_mon_axi] [get_bd_addr_segs ddr4_mig/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK] ROLE_DDR

#=============================================
# Finish BD creation 
#=============================================

  # Restore current instance
  current_bd_instance $oldCurInst

  save_bd_design
}
# End of create_root_design()


##################################################################
# MAIN FLOW
##################################################################

create_root_design ""
