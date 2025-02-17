#========================================================
# Vivado BD design auto run script for XiangShan wrapper 
# on Xilinx XCVU19P
# Based on Vivado 2020.2
# Author: Yisong Chang (changyisong@ict.ac.cn)
# Date: 10/01/2023
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

    # Create instance: DDR4 MIG (use CLKOUT1 as the DUT core clk)
    ## (located in SLR2)
    set ddr4_mig [ create_bd_cell -type ip -vlnv xilinx.com:ip:ddr4:2.2 ddr4_mig ]
    set_property -dict [ list \
        CONFIG.C0.BANK_GROUP_WIDTH {1} \
        CONFIG.C0.CS_WIDTH {1} \
        CONFIG.C0.DDR4_AxiAddressWidth {33} \
        CONFIG.C0.DDR4_AxiDataWidth {512} \
        CONFIG.C0.DDR4_AxiIDWidth.VALUE_SRC {PROPAGATED} \
        CONFIG.C0.DDR4_Clamshell {false} \
        CONFIG.C0.DDR4_DataMask {DM_NO_DBI} \
        CONFIG.C0.DDR4_DataWidth {64} \
        CONFIG.C0.DDR4_Ecc {false} \
        CONFIG.C0.DDR4_InputClockPeriod {4000} \
        CONFIG.C0.DDR4_TimePeriod {833} \
        CONFIG.C0.DDR4_MemoryPart {MT40A1G16RC-062E} \
        CONFIG.System_Clock {Differential} \
        CONFIG.ADDN_UI_CLKOUT1_FREQ_HZ {30} \
    ] $ddr4_mig


   # Create instance: PCIe Endpoint
   ## (located in SLR0)
   set xdma_ep [ create_bd_cell -type ip -vlnv xilinx.com:ip:xdma:4.1 xdma_ep ]
   set_property -dict [list \
        CONFIG.functional_mode {DMA} \
        CONFIG.mode_selection {Advanced} \
        CONFIG.pcie_blk_locn {PCIE4C_X0Y1} \
        CONFIG.en_gt_selection {true} \
        CONFIG.select_quad {GTY_Quad_222} \
        CONFIG.pl_link_cap_max_link_width {X8} \
        CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
        CONFIG.xdma_axi_intf_mm {AXI_Memory_Mapped} \
        CONFIG.axilite_master_en {true} \
        CONFIG.axilite_master_size {32} \
        CONFIG.axilite_master_scale {Megabytes} \
        CONFIG.pciebar2axibar_axil_master {0x10000000} \
        CONFIG.axist_bypass_en {true} \
        CONFIG.axist_bypass_size {256} \
        CONFIG.axist_bypass_scale {Megabytes} \
        CONFIG.cfg_mgmt_if {false} \
        CONFIG.pf0_base_class_menu {Processing_accelerators} \
        CONFIG.pf0_sub_class_interface_menu {Unknown} \
    ] $xdma_ep
    
    # Create instance: AXI interconnect for DDR4 (located in SLR2)
    set axi_ic_ddr_mem [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_ddr_mem ]
    set_property -dict [ list \
        CONFIG.NUM_MI {1} \
        CONFIG.NUM_SI {2} \
    ] $axi_ic_ddr_mem

    set axi_ic_ddr_mem_S00_cc [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 axi_ic_ddr_mem_S00_cc]
    set_property -dict [ list \
	CONFIG.ACLK_ASYNC.VALUE_SRC {USER}
    ] $axi_ic_ddr_mem_S00_cc

    set axi_ic_ddr_mem_S01_cc [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_clock_converter:2.1 axi_ic_ddr_mem_S01_cc]
    set_property -dict [ list \
	CONFIG.ACLK_ASYNC.VALUE_SRC {USER}
    ] $axi_ic_ddr_mem_S01_cc

  ## AXI IC of DDR4 MIG in PCIe clock domain (located in SLR0)
  ### (driven by slow clock generated by PCIe ui clock)
  set axi_ic_ddr_mem_pcie [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_ddr_mem_pcie ]
  set_property -dict [ list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {2} \
  ] $axi_ic_ddr_mem_pcie

  ## clock converter of DDR4 MIG between PCIe clock domain and DDR4 ui clock (located in SLR1) 
  set axi_ic_ddr_mem_cross_domain [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_ddr_mem_cross_domain ]
  set_property -dict [ list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {1} \
  ] $axi_ic_ddr_mem_cross_domain

  ## AXI register slice w/ autopipelining
  ### between SLR0 and SLR1
  ### (driven by PCIe-ui-clk-generated slow clock)
  set axi_ic_ddr_mem_pcie_reg_slice \
  [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 axi_ic_ddr_mem_pcie_reg_slice ]
  set_property -dict [ list \
    CONFIG.USE_AUTOPIPELINING {1} \
    CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} \
  ] $axi_ic_ddr_mem_pcie_reg_slice

  ## AXI register slice w/ autopipelining
  ### between SLR2 and SLR1
  ### (driven by DUT clock)
  set axi_ic_ddr_mem_reg_slice \
  [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 axi_ic_ddr_mem_reg_slice ]
  set_property -dict [ list \
    CONFIG.USE_AUTOPIPELINING {1} \
    CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} \
  ] $axi_ic_ddr_mem_reg_slice

  # Create instance: AXI interconnect for PCIe AXI-Lite BAR interface
  ## (located in SLR0)
  set axi_ic_ep_bar_axi_lite [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_ep_bar_axi_lite ]
  set_property -dict [ list \
    CONFIG.NUM_MI {4} \
    CONFIG.NUM_SI {1} \
  ] $axi_ic_ep_bar_axi_lite

  # Create instance: AXI interconnect for PCIe AXI-Lite BAR interface in DUT clock domain
  ## (located in SLR1)
  set axi_ic_ep_bar_axi_lite_cross_domain [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_ep_bar_axi_lite_cross_domain ]
  set_property -dict [ list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {1} \
  ] $axi_ic_ep_bar_axi_lite_cross_domain

  ## AXI register slice w/ autopipelining
  ### between SLR0 and SLR1
  ### (driven by PCIe slow clock)
  set i 0
  while {$i < 1} {
        set axi_reg_slice_name axi_ic_ep_bar_axi_lite_cross_domain_reg_slice_S0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  # Create instance: AXI interconnect for Role MMIO
  ## (located in SLR1)
  set axi_ic_role_io [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_role_io ]
  set_property -dict [ list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {1} \
  ] $axi_ic_role_io

  ## AXI register slice w/ autopipelining
  ### between SLR0 and SLR1
  ### (driven by DUT clock)
  set i 0
  while {$i < 1} {
        set axi_reg_slice_name axi_ic_role_io_reg_slice_M0$i
        set axi_reg_slice_util [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_register_slice:2.1 $axi_reg_slice_name ]
        set_property -dict [ list CONFIG.USE_AUTOPIPELINING {1} \
		CONFIG.PROTOCOL {AXI4LITE} \
		CONFIG.DATA_WIDTH {32} \
                CONFIG.REG_AW {15} CONFIG.REG_AR {15} CONFIG.REG_W {15} CONFIG.REG_R {15} CONFIG.REG_B {15} ] $axi_reg_slice_util
        incr i
  }

  # Create instance: AXI interconnect for Role MMIO in PCIe clock domain
  ## (located in SLR0)
  set axi_ic_role_io_cross_domain [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_role_io_cross_domain ]
  set_property -dict [ list \
    CONFIG.NUM_MI {2} \
    CONFIG.NUM_SI {1} \
  ] $axi_ic_role_io_cross_domain

  # Create instance: AXI interconnect for Boot ROM
  ## (located in SLR0)
  set axi_ic_bootrom [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_bootrom ]
  set_property -dict [ list \
    CONFIG.NUM_MI {1} \
    CONFIG.NUM_SI {2} \
  ] $axi_ic_bootrom

  # Create instance: AXI UART Lite over PCIe for Host-side
  ## (located in SLR0)
  set host_uart [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 host_uart ]
  set_property -dict [ list CONFIG.C_BAUDRATE {115200} ] $host_uart

  # Create instance: AXI UART Lite for Role
  ## (located in SLR0)
  set role_uart [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_uartlite:2.0 role_uart ]
  set_property -dict [ list CONFIG.C_BAUDRATE {115200} ] $role_uart

  # Create instance: Block memory generator for Boot ROM
  ## (located in SLR0)
  set bootrom_bram [ create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 bootrom_bram ]

  # Create instance: AXI BRAM controller for Boot ROM
  ## (located in SLR0)
  set bootrom_bram_ctrl [ create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 bootrom_bram_ctrl ]
  set_property -dict [ list CONFIG.SINGLE_PORT_BRAM {1} CONFIG.PROTOCOL {AXI4LITE}] $bootrom_bram_ctrl

  # Create GPIO register to control QDMA AXI MM base address
  ## This reg controls AxADDR[35:28]
  ## (located in SLR0)
  set axi_mm_base_reg [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_mm_base_reg]
  set_property -dict [list \
    CONFIG.C_GPIO_WIDTH {8} \
    CONFIG.C_DOUT_DEFAULT {0x00000000} \
    CONFIG.C_ALL_OUTPUTS {1} \
  ] $axi_mm_base_reg

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

  # Create instance: IBUFDS_GTE for PCIe EP reference clock
  set pcie_ep_ref_clk_buf [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 pcie_ep_ref_clk_buf ]
  set_property CONFIG.C_BUF_TYPE {IBUFDSGTE} $pcie_ep_ref_clk_buf

  # Create instance: slow clock generation from PCIe ui clock
  ## (located in SLR0)
  set pcie_slow_clk_gen [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 pcie_slow_clk_gen]
  set_property -dict [list \
        CONFIG.RESET_TYPE {ACTIVE_LOW} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50} \
  ] $pcie_slow_clk_gen
    
  # Differential system clock for DDR4 MIG
  set ddr4_mig_sys_clk [ create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 ddr4_mig_sys_clk ]
  set_property -dict [ list CONFIG.FREQ_HZ {250000000} ] $ddr4_mig_sys_clk

  # Referecen clock attached to the DUT's RTC clock
  set dut_rtc_ref_clk [ create_bd_intf_port -mode slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 dut_rtc_ref_clk ]
  set_property -dict [ list config.freq_hz {10000000} ] $dut_rtc_ref_clk

  # Create instance: IBUF and BUFG for RTC reference clock
  set dut_rtc_ref_clk_buf [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 dut_rtc_ref_clk_buf ]
  set_property CONFIG.C_BUF_TYPE {IBUFDS} $dut_rtc_ref_clk_buf

  set dut_rtc_ref_clk_bufg [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf:2.2 dut_rtc_ref_clk_bufg ]
  set_property CONFIG.C_BUF_TYPE {BUFG} $dut_rtc_ref_clk_bufg

  # Create instance: RTC clock generation
#  set dut_rtc_clk_gen [create_bd_cell -type ip -vlnv xilinx.com:ip:clk_wiz:6.0 dut_rtc_clk_gen]
#  set_property -dict [list \
#        CONFIG.RESET_TYPE {ACTIVE_LOW} \
#        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {1} \
#  ] $dut_rtc_clk_gen

#=============================================
# Reset ports
#=============================================

  # PCIe EP perst
  create_bd_port -dir I -type rst pcie_ep_perstn

  # Create instance: inverter of perstn from PCIe EP
  set ep_perst_gen [ create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 ep_perst_gen ]
  set_property -dict [ list CONFIG.C_OPERATION {not} \
	CONFIG.C_SIZE {1} ] $ep_perst_gen

  # Create instance: pcie_slow_clk_rst_gen
  ## (located in SLR0)
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 pcie_slow_clk_rst_gen

  # Create instance: DDR MIG AXI sync. reset generation
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 ddr4_mig_sync_reset
   
  # Create instance: sync. rst_gen of DUT clock
  ## (located in SLR2)
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 dut_rst_gen

#=============================================
# GT ports
#=============================================

  # PCIe EP Slot
  create_bd_port -dir I -from 7 -to 0 pcie_ep_rxn
  create_bd_port -dir I -from 7 -to 0 pcie_ep_rxp
  create_bd_port -dir O -from 7 -to 0 pcie_ep_txn
  create_bd_port -dir O -from 7 -to 0 pcie_ep_txp

#=============================================
# DDR4 pins
#=============================================
  
  create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddr4_rtl:1.0 c0_ddr4

#=============================================
# MISC ports
#=============================================
  ## DRAM calibration done
  #create_bd_port -dir O ddr4_mig_calib_done

  ## PCIe EP PHY ready and link up signals
  #create_bd_port -dir O pcie_ep_phy_ready
  #create_bd_port -dir O pcie_ep_lnk_up

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

  # DDR4 memory controller reference clock (250MHz)
  connect_bd_intf_net -intf_net ddr4_mig_sys_clk_in \
      [get_bd_intf_pins ddr4_mig_sys_clk] \
      [get_bd_intf_pins ddr4_mig/C0_SYS_CLK]

  # DDR4 controller ui clock (300MHz) for AXI IC and AXI interface
  connect_bd_net [get_bd_pins ddr4_mig/c0_ddr4_ui_clk] \
      [get_bd_pins ddr4_mig_sync_reset/slowest_sync_clk] \
      [get_bd_pins axi_ic_ddr_mem_S00_cc/m_axi_aclk] \
      [get_bd_pins axi_ic_ddr_mem_S01_cc/m_axi_aclk] \
      [get_bd_pins axi_ic_ddr_mem/ACLK] \
      [get_bd_pins axi_ic_ddr_mem/S00_ACLK] \
      [get_bd_pins axi_ic_ddr_mem/S01_ACLK] \
      [get_bd_pins axi_ic_ddr_mem/M00_ACLK]

  # DUT clock (slow clock generated from MIG)
  connect_bd_net -net dut_clk [get_bd_pins ddr4_mig/addn_ui_clkout1] \
      [get_bd_pins u_role/aclk] \
      [get_bd_pins dut_rst_gen/slowest_sync_clk] \
      [get_bd_pins axi_ic_ddr_mem_S00_cc/s_axi_aclk] \
      [get_bd_pins axi_ic_ddr_mem_S01_cc/s_axi_aclk] \
      [get_bd_pins axi_ic_ddr_mem_reg_slice/aclk] \
      [get_bd_pins axi_ic_ddr_mem_cross_domain/ACLK] \
      [get_bd_pins axi_ic_ddr_mem_cross_domain/M00_ACLK] \
      [get_bd_pins axi_ic_role_io/ACLK] \
      [get_bd_pins axi_ic_role_io/S00_ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite_cross_domain/ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite_cross_domain/M00_ACLK]

  # PCIe EP BAR interfaces (250MHz)
  connect_bd_net -net pcie_clk [get_bd_pins xdma_ep/axi_aclk] \
      [get_bd_pins axi_ic_ddr_mem_pcie/ACLK] \
      [get_bd_pins axi_ic_ddr_mem_pcie/S00_ACLK] \
      [get_bd_pins axi_ic_ddr_mem_pcie/S01_ACLK] \
      [get_bd_pins axi_ic_role_io_cross_domain/ACLK] \
      [get_bd_pins axi_ic_role_io_cross_domain/M00_ACLK] \
      [get_bd_pins axi_ic_role_io_cross_domain/M01_ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/S00_ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M00_ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M01_ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M02_ACLK] \
      [get_bd_pins axi_ic_bootrom/*ACLK] \
      [get_bd_pins pcie_slow_clk_gen/clk_in1] \
      [get_bd_pins axi_mm_base_reg/s_axi_aclk] \
      [get_bd_pins bootrom_bram_ctrl/s_axi_aclk] \
      [get_bd_pins role_uart/s_axi_aclk] \
      [get_bd_pins host_uart/s_axi_aclk]

  # slow clock (50MHz) generated from PCIe EP ui clock
  connect_bd_net -net pcie_slow_clk [get_bd_pins pcie_slow_clk_gen/clk_out1] \
      [get_bd_pins pcie_slow_clk_rst_gen/slowest_sync_clk] \
      [get_bd_pins axi_ic_ddr_mem_pcie/M00_ACLK] \
      [get_bd_pins axi_ic_ddr_mem_pcie_reg_slice/aclk] \
      [get_bd_pins axi_ic_ddr_mem_cross_domain/S00_ACLK] \
      [get_bd_pins axi_ic_role_io/M00_ACLK] \
      [get_bd_pins axi_ic_role_io_reg_slice_M00/aclk] \
      [get_bd_pins axi_ic_role_io_cross_domain/S00_ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M03_ACLK] \
      [get_bd_pins axi_ic_ep_bar_axi_lite_cross_domain_reg_slice_S00/aclk] \
      [get_bd_pins axi_ic_ep_bar_axi_lite_cross_domain/S00_ACLK]

  # DUT's RTC reference clock (10MHz)
  connect_bd_intf_net [get_bd_intf_pins dut_rtc_ref_clk] \
      [get_bd_intf_pins dut_rtc_ref_clk_buf/CLK_IN_D]

  connect_bd_net [get_bd_pins dut_rtc_ref_clk_buf/IBUF_OUT] \
      [get_bd_pins dut_rtc_ref_clk_bufg/BUFG_I]

  connect_bd_net [get_bd_pins dut_rtc_ref_clk_bufg/BUFG_O] \
      [get_bd_pins u_role/rtc_clock]

#=============================================
# System reset connection
#=============================================

  # perstn for AXI PCIe EP
  connect_bd_net -net pcie_ep_perstn [get_bd_ports pcie_ep_perstn] \
      [get_bd_pins xdma_ep/sys_rst_n] \
      [get_bd_pins ddr4_mig_sync_reset/ext_reset_in] \
      [get_bd_pins dut_rst_gen/ext_reset_in] \
      [get_bd_pins pcie_slow_clk_gen/resetn] \
      [get_bd_pins pcie_slow_clk_rst_gen/ext_reset_in]

  # dcm_locked signal for MIG-related sync reset infra.
  connect_bd_net -net mig_calib_done [get_bd_pins ddr4_mig/c0_init_calib_complete] \
      [get_bd_pins ddr4_mig_sync_reset/dcm_locked] \
      [get_bd_pins dut_rst_gen/dcm_locked]

  connect_bd_net [get_bd_pins pcie_slow_clk_gen/locked] \
      [get_bd_pins pcie_slow_clk_rst_gen/dcm_locked]

  # System reset for PL DDR4 MIG (opposite polarity of PCIe EP perstn, active high)
  connect_bd_net -net pcie_ep_perstn [get_bd_pins ep_perst_gen/Op1]

  connect_bd_net -net pcie_ep_perst [get_bd_pins ep_perst_gen/Res] \
      [get_bd_pins ddr4_mig/sys_rst]

  # Reset signals for DDR4 MIG related AXI infra. in MIG ui clock domain
  connect_bd_net [get_bd_pins ddr4_mig_sync_reset/peripheral_aresetn] \
      [get_bd_pins ddr4_mig/c0_ddr4_aresetn] \
      [get_bd_pins axi_ic_ddr_mem_S00_cc/m_axi_aresetn] \
      [get_bd_pins axi_ic_ddr_mem_S01_cc/m_axi_aresetn] \
      [get_bd_pins axi_ic_ddr_mem/S00_ARESETN] \
      [get_bd_pins axi_ic_ddr_mem/S01_ARESETN] \
      [get_bd_pins axi_ic_ddr_mem/M00_ARESETN]

  connect_bd_net [get_bd_pins ddr4_mig_sync_reset/interconnect_aresetn] \
      [get_bd_pins axi_ic_ddr_mem/ARESETN]

  # Reset signals of the DUT clock domain
  connect_bd_net [get_bd_pins dut_rst_gen/peripheral_aresetn] \
      [get_bd_pins u_role/aresetn] \
      [get_bd_pins axi_ic_ddr_mem_S00_cc/s_axi_aresetn] \
      [get_bd_pins axi_ic_ddr_mem_S01_cc/s_axi_aresetn] \
      [get_bd_pins axi_ic_ddr_mem_reg_slice/aresetn] \
      [get_bd_pins axi_ic_ddr_mem_cross_domain/M00_ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite_cross_domain/M00_ARESETN] \
      [get_bd_pins axi_ic_role_io/S00_ARESETN]

  connect_bd_net [get_bd_pins dut_rst_gen/interconnect_aresetn] \
      [get_bd_pins axi_ic_ddr_mem_cross_domain/ARESETN] \
      [get_bd_pins axi_ic_role_io/ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite_cross_domain/ARESETN]

  # Reset signals of the slow PCIe clock domain
  connect_bd_net [get_bd_pins pcie_slow_clk_rst_gen/peripheral_aresetn] \
      [get_bd_pins axi_ic_ddr_mem_pcie/M00_ARESETN] \
      [get_bd_pins axi_ic_ddr_mem_pcie_reg_slice/aresetn] \
      [get_bd_pins axi_ic_ddr_mem_cross_domain/S00_ARESETN] \
      [get_bd_pins axi_ic_role_io/M00_ARESETN] \
      [get_bd_pins axi_ic_role_io_reg_slice_M00/aresetn] \
      [get_bd_pins axi_ic_role_io_cross_domain/S00_ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M03_ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite_cross_domain_reg_slice_S00/aresetn] \
      [get_bd_pins axi_ic_ep_bar_axi_lite_cross_domain/S00_ARESETN]

  # PCIe EP AXI interface reset
  connect_bd_net [get_bd_pins xdma_ep/axi_aresetn] \
      [get_bd_pins axi_ic_ddr_mem_pcie/ARESETN] \
      [get_bd_pins axi_ic_ddr_mem_pcie/S00_ARESETN] \
      [get_bd_pins axi_ic_ddr_mem_pcie/S01_ARESETN] \
      [get_bd_pins axi_ic_role_io_cross_domain/ARESETN] \
      [get_bd_pins axi_ic_role_io_cross_domain/M00_ARESETN] \
      [get_bd_pins axi_ic_role_io_cross_domain/M01_ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/S00_ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M00_ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M01_ARESETN] \
      [get_bd_pins axi_ic_ep_bar_axi_lite/M02_ARESETN] \
      [get_bd_pins axi_ic_bootrom/*ARESETN] \
      [get_bd_pins axi_mm_base_reg/s_axi_aresetn] \
      [get_bd_pins bootrom_bram_ctrl/s_axi_aresetn] \
      [get_bd_pins role_uart/s_axi_aresetn] \
      [get_bd_pins host_uart/s_axi_aresetn]

#=============================================
# AXI interface connection
#=============================================

  # AXI-IC of DDR4 MIG
  ## Slave port of the MIG (300MHz)
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ddr_mem/M00_AXI] \
        [get_bd_intf_pins ddr4_mig/C0_DDR4_S_AXI]
  
  ## DUT clock domain
  ### Master port of the DUT core
  connect_bd_intf_net [get_bd_intf_pins u_role/m_axi_mem] \
	[get_bd_intf_pins axi_ic_ddr_mem_S00_cc/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ddr_mem_S00_cc/M_AXI] \
        [get_bd_intf_pins axi_ic_ddr_mem/S00_AXI]

  ## DUT clock domain vs. PCIe slow clock domain
  ### crossing SLR  (SLR2 <-> SLR1)
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ddr_mem_reg_slice/M_AXI] \
	[get_bd_intf_pins axi_ic_ddr_mem_S01_cc/S_AXI]
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ddr_mem_S01_cc/M_AXI] \
        [get_bd_intf_pins axi_ic_ddr_mem/S01_AXI]

  connect_bd_intf_net [get_bd_intf_pins axi_ic_ddr_mem_reg_slice/S_AXI] \
        [get_bd_intf_pins axi_ic_ddr_mem_cross_domain/M00_AXI]

  ## PCIe slow clock domain vs. DUT clock domain
  ### crossing SLR (SLR1 <-> SLR0)
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ddr_mem_pcie_reg_slice/M_AXI] \
        [get_bd_intf_pins axi_ic_ddr_mem_cross_domain/S00_AXI]

  connect_bd_intf_net [get_bd_intf_pins axi_ic_ddr_mem_pcie_reg_slice/S_AXI] \
        [get_bd_intf_pins axi_ic_ddr_mem_pcie/M00_AXI]

  ## PCIe clock domain
  ### Master ports of the PCIe EP
  connect_bd_intf_net [get_bd_intf_pins xdma_ep/M_AXI_BYPASS] \
        [get_bd_intf_pins axi_ic_ddr_mem_pcie/S00_AXI]

  connect_bd_intf_net [get_bd_intf_pins xdma_ep/M_AXI] \
        [get_bd_intf_pins axi_ic_ddr_mem_pcie/S01_AXI]


  # AXI-IC of PCIe EP AXI Lite
  ## Slave and Master ports in the PCIe clock domain
  ### Master port of the PCIe EP
  connect_bd_intf_net [get_bd_intf_pins xdma_ep/M_AXI_LITE] \
        [get_bd_intf_pins axi_ic_ep_bar_axi_lite/S00_AXI]

  ### Slave port of the Host-side UART
  connect_bd_intf_net [get_bd_intf_pins host_uart/S_AXI] \
        [get_bd_intf_pins axi_ic_ep_bar_axi_lite/M00_AXI]

  ### Slave port of the Boot ROM IC
  connect_bd_intf_net [get_bd_intf_pins axi_ic_bootrom/S01_AXI] \
        [get_bd_intf_pins axi_ic_ep_bar_axi_lite/M01_AXI]

  ### Slave port of the AXI MM base reg
  connect_bd_intf_net [get_bd_intf_pins axi_mm_base_reg/S_AXI] \
        [get_bd_intf_pins axi_ic_ep_bar_axi_lite/M02_AXI]

  ## PCIe clock domain vs. PCIe slow clock domain
  ### M03 port of the axi_ic_ep_bar_axi_lite
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ep_bar_axi_lite/M03_AXI] \
        [get_bd_intf_pins axi_ic_ep_bar_axi_lite_cross_domain_reg_slice_S00/S_AXI]

  ### PCIe slow clock domain crossing SLR (SLR1 <-> SLR0) 
  connect_bd_intf_net [get_bd_intf_pins axi_ic_ep_bar_axi_lite_cross_domain_reg_slice_S00/M_AXI] \
	[get_bd_intf_pins axi_ic_ep_bar_axi_lite_cross_domain/S00_AXI]

  ## PCIe slow clock domain vs. DUT clock domain
  connect_bd_intf_net [get_bd_intf_pins u_role/s_axi_ctrl] \
	[get_bd_intf_pins axi_ic_ep_bar_axi_lite_cross_domain/M00_AXI]


  # AXI-IC of Role MMIO
  ## Master ports in the DUT clock domain
  connect_bd_intf_net [get_bd_intf_pins u_role/m_axi_io] \
        [get_bd_intf_pins axi_ic_role_io/S00_AXI]

  ## DUT clock domain vs. PCIe slow clock domain
  ### PCIe slow clock domain crossing SLR (SLR1 <-> SLR0) 
  connect_bd_intf_net [get_bd_intf_pins axi_ic_role_io/M00_AXI] \
	[get_bd_intf_pins axi_ic_role_io_reg_slice_M00/S_AXI]

  connect_bd_intf_net [get_bd_intf_pins axi_ic_role_io_reg_slice_M00/M_AXI] \
        [get_bd_intf_pins axi_ic_role_io_cross_domain/S00_AXI]

  ## PCIe slow clock domain vs. PCIe clock domain
  ### Slave port of the role UART
  connect_bd_intf_net [get_bd_intf_pins role_uart/S_AXI] \
        [get_bd_intf_pins axi_ic_role_io_cross_domain/M00_AXI]

  ### Role to Boot ROM IC
  connect_bd_intf_net [get_bd_intf_pins axi_ic_bootrom/S00_AXI] \
        [get_bd_intf_pins axi_ic_role_io_cross_domain/M01_AXI]


  # AXI-IC of Boot ROM
  connect_bd_intf_net [get_bd_intf_pins bootrom_bram_ctrl/S_AXI] \
        [get_bd_intf_pins axi_ic_bootrom/M00_AXI]

  # TODO: Use Role's DMA port

  # Address mapper for XDMA AXI MM
  # out_addr = {28'd0, base_reg[7:0], in_addr[27:0]}

  set const_28b0 [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const_28b0 ]
  set_property -dict [list CONFIG.CONST_WIDTH {28} CONFIG.CONST_VAL {0x0} ] $const_28b0

  set pair_list [list \
    {xdma_ep m_axib_araddr axi_ic_ddr_mem_pcie S00_AXI_araddr} \
    {xdma_ep m_axib_awaddr axi_ic_ddr_mem_pcie S00_AXI_awaddr} \
  ]

  foreach pair ${pair_list} {
    set src_blk   [lindex ${pair} 0]
    set src_port  [lindex ${pair} 1]
    set dst_blk   [lindex ${pair} 2]
    set dst_port  [lindex ${pair} 3]

    set slice [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlslice:1.0 slice_${src_blk}_${src_port} ]
    set_property -dict [list CONFIG.DIN_WIDTH {64} CONFIG.DIN_FROM {27} CONFIG.DIN_TO {0}] $slice

    set concat [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 concat_${dst_blk}_${dst_port} ]
    set_property -dict [list CONFIG.NUM_PORTS {3}] $concat

    connect_bd_net [get_bd_pins ${src_blk}/${src_port}] [get_bd_pins ${slice}/Din]
    connect_bd_net [get_bd_pins ${slice}/Dout] [get_bd_pins ${concat}/In0]
    connect_bd_net [get_bd_pins axi_mm_base_reg/gpio_io_o] [get_bd_pins ${concat}/In1]
    connect_bd_net [get_bd_pins const_28b0/dout] [get_bd_pins ${concat}/In2]
    connect_bd_net [get_bd_pins ${concat}/dout] [get_bd_pins ${dst_blk}/${dst_port}]
  }

#=============================================
# AXI stream interface connection
#=============================================

  # connect_bd_intf_net [get_bd_intf_pins u_role/m_axis_trace] \
  #     [get_bd_intf_pins role_decoupler/rp_axis_trace]

  # connect_bd_intf_net [get_bd_intf_pins role_decoupler/s_axis_trace] \
  #     [get_bd_intf_pins xdma_ep/S_AXIS_C2H_0]

  # connect_bd_net [get_bd_pins const_vcc/dout] \
  #     [get_bd_pins xdma_ep/m_axis_h2c_tready_0]

#==============================================
# GT Port connection
#==============================================

  # PCIe EP slot
  connect_bd_net [get_bd_ports pcie_ep_rxn] [get_bd_pins xdma_ep/pci_exp_rxn]
  connect_bd_net [get_bd_ports pcie_ep_rxp] [get_bd_pins xdma_ep/pci_exp_rxp]
  connect_bd_net [get_bd_ports pcie_ep_txn] [get_bd_pins xdma_ep/pci_exp_txn]
  connect_bd_net [get_bd_ports pcie_ep_txp] [get_bd_pins xdma_ep/pci_exp_txp]

#==============================================
# DDR4 memory connection
#==============================================

  connect_bd_intf_net [get_bd_intf_pins ddr4_mig/C0_DDR4] [get_bd_intf_ports c0_ddr4]

#==============================================
# MISC signals connection
#==============================================1

  # connect_bd_net [get_bd_pins xdma_ep/user_lnk_up] \
  #     [get_bd_pins pcie_ep_lnk_up]

  connect_bd_net [get_bd_pins host_uart/rx] \
      [get_bd_pins role_uart/tx]

  connect_bd_net [get_bd_pins host_uart/tx] \
      [get_bd_pins role_uart/rx]

  connect_bd_intf_net [get_bd_intf_pins bootrom_bram_ctrl/BRAM_PORTA] \
      [get_bd_intf_pins bootrom_bram/BRAM_PORTA]

#=============================================
# Interrupt signal connection
#=============================================

    # Create intr_sync
    set intr_sync_pcie_slow [create_bd_cell -type module -reference f2s_rising_intr_sync intr_sync_pcie_slow]
    set_property -dict [list \
        CONFIG.INTR_WIDTH {16} \
        CONFIG.SYNC_STAGE {2} \
    ] $intr_sync_pcie_slow

    set intr_sync_dut [create_bd_cell -type module -reference f2s_rising_intr_sync intr_sync_dut]
    set_property -dict [list \
        CONFIG.INTR_WIDTH {16} \
        CONFIG.SYNC_STAGE {2} \
    ] $intr_sync_dut

  set role_intr_concat [ create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 role_intr_concat ]
    set_property -dict [list CONFIG.NUM_PORTS {16}] $role_intr_concat

  connect_bd_net [get_bd_pins role_uart/interrupt] [get_bd_pins role_intr_concat/In0]

  connect_bd_net [get_bd_pins const_gnd/dout] \
    [get_bd_pins role_intr_concat/In1] \
    [get_bd_pins role_intr_concat/In2] \
    [get_bd_pins role_intr_concat/In3] \
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
  
  connect_bd_net -net pcie_clk [get_bd_pins intr_sync_pcie_slow/fast_clk]

  connect_bd_net -net pcie_slow_clk [get_bd_pins intr_sync_pcie_slow/slow_clk] \
    [get_bd_pins intr_sync_dut/fast_clk]

  connect_bd_net -net dut_clk [get_bd_pins intr_sync_dut/slow_clk]
  
  connect_bd_net [get_bd_pins role_intr_concat/dout] [get_bd_pins intr_sync_pcie_slow/fast_intr]
  connect_bd_net [get_bd_pins intr_sync_pcie_slow/slow_intr] [get_bd_pins intr_sync_dut/fast_intr]
  connect_bd_net [get_bd_pins intr_sync_dut/slow_intr] [get_bd_pins u_role/s2r_intr]

#=============================================
# ILA
#=============================================

  # Create instance: system_ila, and set properties
#  set system_ila [ create_bd_cell -type ip -vlnv xilinx.com:ip:system_ila:1.1 system_ila ]
#  set_property -dict [ list \
#    CONFIG.C_NUM_MONITOR_SLOTS {3} \
#  ] $system_ila
#
#  connect_bd_net [get_bd_pins xdma_ep/axi_aclk] [get_bd_pins system_ila/clk]
#  connect_bd_net [get_bd_pins xdma_ep/axi_aresetn] [get_bd_pins system_ila/resetn]
#
#  connect_bd_intf_net [get_bd_intf_pins system_ila/SLOT_0_AXI] [get_bd_intf_pins role_decoupler/s_axi_mem]
#  connect_bd_intf_net [get_bd_intf_pins system_ila/SLOT_1_AXI] [get_bd_intf_pins role_decoupler/s_axi_io]
#  connect_bd_intf_net [get_bd_intf_pins system_ila/SLOT_2_AXI] [get_bd_intf_pins role_decoupler/s_axi_ctrl]

#=============================================
# Address segments
#=============================================

  ## PCIe EP address space
  create_bd_addr_seg -range 0x10000 -offset 0x10000000 [get_bd_addr_spaces xdma_ep/M_AXI_LITE] [get_bd_addr_segs bootrom_bram_ctrl/S_AXI/Mem0] PCIE_EP_BAR_BOOTROM
  create_bd_addr_seg -range 0x1000 -offset 0x10010000 [get_bd_addr_spaces xdma_ep/M_AXI_LITE] [get_bd_addr_segs axi_mm_base_reg/S_AXI/Reg] PCIE_EP_BAR_AXI_MM_BASE_REG
  create_bd_addr_seg -range 0x1000 -offset 0x10011000 [get_bd_addr_spaces xdma_ep/M_AXI_LITE] [get_bd_addr_segs host_uart/S_AXI/Reg] PCIE_EP_BAR_HOST_UART
#  create_bd_addr_seg -range 0x1000 -offset 0x10012000 [get_bd_addr_spaces xdma_ep/M_AXI_LITE] [get_bd_addr_segs role_decoupler/s_axi_reg/Reg] PCIE_EP_BAR_ROLE_DECOUPLER
  create_bd_addr_seg -range 0x100000 -offset 0x10100000 [get_bd_addr_spaces xdma_ep/M_AXI_LITE] [get_bd_addr_segs u_role/s_axi_ctrl/reg0] PCIE_EP_BAR_ROLE_CTRL
  create_bd_addr_seg -range 0x200000000 -offset 0x0 [get_bd_addr_spaces xdma_ep/M_AXI_BYPASS] [get_bd_addr_segs ddr4_mig/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK] PCIE_EP_BAR_DDR
  create_bd_addr_seg -range 0x200000000 -offset 0x0 [get_bd_addr_spaces xdma_ep/M_AXI] [get_bd_addr_segs ddr4_mig/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK] PCIE_EP_DMA_DDR

  ## Role address space
  create_bd_addr_seg -range 0x10000 -offset 0x10000000 [get_bd_addr_spaces u_role/m_axi_io] [get_bd_addr_segs bootrom_bram_ctrl/S_AXI/Mem0] ROLE_BOOTROM
  create_bd_addr_seg -range 0x10000 -offset 0x30000000 [get_bd_addr_spaces u_role/m_axi_io] [get_bd_addr_segs role_uart/S_AXI/Reg] ROLE_UART
  create_bd_addr_seg -range 0x200000000 -offset 0x0 [get_bd_addr_spaces u_role/m_axi_mem] [get_bd_addr_segs ddr4_mig/C0_DDR4_MEMORY_MAP/C0_DDR4_ADDRESS_BLOCK] ROLE_DDR

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

