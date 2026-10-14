# DT building target

CPP_PARAMS :=

CPP_PARAMS += -DFPGA_$(shell echo $(FPGA_BD) | tr a-z A-Z)

DT_LOC := $(abspath $(NANHU_G_SW_LOC)/dt)

DT_TARGET ?= kunminghu-scope
dts := $(DT_TARGET).dts
dtb := $(DT_TARGET).dtb

DTS := $(DT_LOC)/$(dts)
DTB := $(INSTALL_LOC)/$(dtb)

#==========================================
# Device Tree Source and Blob compilation 
#==========================================
target_dt: $(DTB)

ifeq ($(DT_TARGET),kunminghu-scope)
$(DTS): FORCE
	python3 $(NANHU_G_SW_LOC)/../../tools/guest/prepare_profile_dt.py \
		--num-cores $(NUM_CORES) --output $@ \
		--source $(NANHU_G_SW_LOC)/../hardware/xs-gen/build/XSTop.dts
endif

$(DTB): $(DTS)
	@mkdir -p $(INSTALL_LOC)
	cpp $(CPP_PARAMS) -I $(DT_LOC) -E -P -x assembler-with-cpp $(DTS) | \
		dtc -I dts -O dtb -o $@ -

target_dt_clean:
	@rm -f $(DTB)

