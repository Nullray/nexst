.PHONY: qdma_drv opensbi target_dt zsbl

NANHU_G_SW_LOC := target/kmh/software
SCOPE_PROFILE_TOOL := $(realpath $(NANHU_G_SW_LOC)/../../tools/hardware/profile.py)
NUM_CORES ?= $(if $(SCOPE_PROFILE_TOOL),$(shell python3 $(SCOPE_PROFILE_TOOL) --field num_cores),1)

EXPORT_CC_PATH := export PATH=$(LINUX_GCC_PATH):$$PATH

EXPORT_DTC_PATH := export PATH=$(DTC_LOC):$$PATH

include $(NANHU_G_SW_LOC)/../scripts/sw_target/opensbi.mk

include $(NANHU_G_SW_LOC)/../scripts/sw_target/kernel.mk

include $(NANHU_G_SW_LOC)/../scripts/sw_target/dt.mk

include $(NANHU_G_SW_LOC)/../scripts/sw_target/zsbl.mk

