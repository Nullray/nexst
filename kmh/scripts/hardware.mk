NANHU_G_LOC := target/kmh/hardware
XS_SRC := $(abspath $(NANHU_G_LOC)/xs-gen)
GEN_DIR := $(NANHU_G_LOC)/sources/generated
PATCH_DIR := $(NANHU_G_LOC)/sources/patch

CONFIG ?= FpgaDefaultConfig
#CONFIG ?= DefaultMatrixConfig
L2_CACHE_SIZE ?= 256
L3_CACHE_SIZE ?= 768
SCOPE_PROFILE_TOOL := $(realpath $(NANHU_G_LOC)/../../tools/hardware/profile.py)
NUM_CORES ?= $(if $(SCOPE_PROFILE_TOOL),$(shell python3 $(SCOPE_PROFILE_TOOL) --field num_cores),1)
CPU_KIND ?= kunminghu
ifneq ($(CPU_KIND),kunminghu)
$(error This architecture requires CPU_KIND=kunminghu)
endif
SCOPE_LLC_ARGS :=

.PHONY: xs_gen
xs_gen:
	$(MAKE) -C "$(XS_SRC)" \
		NOOP_HOME="$(XS_SRC)" \
		TIME_CMD="/usr/bin/time -avp -o ./build/time.log" \
		CONFIG=$(CONFIG) \
		$(SCOPE_LLC_ARGS) WITH_CHISELDB=0 WITH_CONSTANTIN=0 FPGA=1 RELEASE=1 MFC=1 \
		NUM_CORES=$(NUM_CORES) verilog
	@set -e; \
	test -s "$(XS_SRC)/build/rtl/XSTop.sv"; \
	mkdir -p "$(GEN_DIR)"; \
	for source in "$(XS_SRC)"/build/rtl/*.v "$(XS_SRC)"/build/rtl/*.sv "$(PATCH_DIR)"/*.sv; do \
		test -f "$$source" || continue; \
		cp "$$source" "$(GEN_DIR)/"; \
	done; \
	mv "$(GEN_DIR)/XSTop.sv" "$(GEN_DIR)/XSTop.v"
# 	$(PATCH_DIR)/XSTop_patch.py $(XS_SRC)/build/rtl/SoCMisc.sv > $(GEN_DIR)/SoCMisc.sv

.PHONY: xs_clean
xs_clean:
	rm -rf $(GEN_DIR)
	rm -rf $(XS_SRC)/build
