# Linux kernel (i.e., Physical machine and Virtual machine)
OS_KERN := phy_os virt

obj-os-y := $(foreach obj,$(OS_KERN),$(obj).os)
obj-os-clean-y := $(foreach obj,$(OS_KERN),$(obj).os.clean)
obj-os-dist-y := $(foreach obj,$(OS_KERN),$(obj).os.dist)

%.os: FORCE
	@echo "Compiling $@..."
	$(MAKE) $(kernel-flag) OS=$(patsubst %.os,%,$@) \
		MODULES=$($(patsubst %.os,obj-%-modules-y,$@)) linux

%.os.clean:
	$(MAKE) $(kernel-flag) \
		OS=$(patsubst %.os.clean,%,$@) \
		MODULES=$($(patsubst %.os.clean,obj-%-modules-y,$@)) linux_clean

%.os.dist:
	$(MAKE) $(kernel-flag) \
		OS=$(patsubst %.os.dist,%,$@) \
		MODULES=$($(patsubst %.os.dist,obj-%-modules-y,$@)) linux_distclean

#================================================
#================================================

# Linux kernel source and installation
KERN_SRC := software/linux
KERN_LOC := $(abspath ./software/$(ARCH)-linux)

# TODO: set your Linux kernel compilation flags and targets
KERN_PLAT := $(ARCH)
KERN_COMPILE_FLAGS := ARCH=$(KERN_PLAT) \
    O=$(KERN_LOC)/$(OS) \
    CROSS_COMPILE=$(LINUX_GCC_PREFIX)
KERN_TARGET := all

# TODO: Change to your own Linux kernel configuration file name for physical os
phy_os-kern-config:= riscv_serve_defconfig
virt-kern-config:= defconfig

KERN_CONFIG_LOC := $(KERN_SRC)/arch/$(KERN_PLAT)/configs

KERN_IMAGE_GEN := $(KERN_LOC)/$(OS)/arch/$(KERN_PLAT)/boot/Image

# kernel installation
KERN_IMAGE := $(INSTALL_LOC)/Image

ROOTFS_SRC := $(NANHU_G_SW_LOC)/rootfs
INITRAMFS_TXT := $(abspath $(ROOTFS_SRC)/initramfs.txt)
SCOPE_MMIO_LAT_USER_SRC := $(abspath ../tools/proto/scope_mmio_lat_user.c)
SCOPE_MMIO_LAT_USER_ROOTFS_MK := $(ROOTFS_SRC)/apps/scripts/scope-mmio-lat-user/Makefile
PCIUTILS_ROOTFS_MK := $(ROOTFS_SRC)/apps/scripts/pciutils/Makefile
PCIUTILS_SRC_MK := $(ROOTFS_SRC)/apps/pciutils/Makefile

KERN_COMPILE_FLAGS += CONFIG_INITRAMFS_SOURCE=$(INITRAMFS_TXT)

#==================================
# Linux kernel compilation
#==================================
linux: $(KERN_IMAGE_GEN) FORCE
	@mkdir -p $(INSTALL_LOC)
	@cp $(KERN_IMAGE_GEN) $(KERN_IMAGE)

$(KERN_IMAGE_GEN): $(KERN_LOC)/$(OS)/.config FORCE
	$(EXPORT_CC_PATH) && $(MAKE) -C $(KERN_SRC) \
		$(KERN_COMPILE_FLAGS) $(KERN_TARGET) -j 10

$(KERN_LOC)/%/.config: $(KERN_CONFIG_LOC)/$($(OS)-kern-config) $(INITRAMFS_TXT)
	$(EXPORT_CC_PATH) && $(MAKE) -C $(KERN_SRC) \
		$(KERN_COMPILE_FLAGS) $($(OS)-kern-config) olddefconfig

linux_clean: $(obj-modules-clean-y)
	$(MAKE) -C $(KERN_SRC) O=$(KERN_LOC)/$(OS) clean 
	@rm -f $(KERN_IMAGE)

linux_distclean: $(obj-modules-clean-y)
	@rm -rf $(KERN_LOC)/$(OS) $(KERN_INSTALL_LOC)

rootfs: $(INITRAMFS_TXT)

$(INITRAMFS_TXT): $(ROOTFS_SRC)/Makefile \
		  $(ROOTFS_SRC)/scripts/gen-initramfs-list.sh \
		  $(SCOPE_MMIO_LAT_USER_ROOTFS_MK) \
		  $(SCOPE_MMIO_LAT_USER_SRC) \
		  $(PCIUTILS_ROOTFS_MK) \
		  $(PCIUTILS_SRC_MK)
	$(EXPORT_CC_PATH) && $(MAKE) -C $(ROOTFS_SRC) RISCV=$(abspath $(riscv_LINUX_GCC_PATH)/..) CROSS_COMPILE=$(riscv_LINUX_GCC_PREFIX)

rootfs_clean:
	$(MAKE) -C $(ROOTFS_SRC) clean
