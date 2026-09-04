CC ?= cc
PKG_CONFIG ?= pkg-config
CFLAGS ?= -O2 -g
RDMA_CFLAGS := $(shell command -v $(PKG_CONFIG) >/dev/null 2>&1 && \
	$(PKG_CONFIG) --cflags libibverbs librdmacm 2>/dev/null)
RDMA_LIBS := $(shell command -v $(PKG_CONFIG) >/dev/null 2>&1 && \
	$(PKG_CONFIG) --libs libibverbs librdmacm 2>/dev/null)
ifeq ($(strip $(RDMA_LIBS)),)
RDMA_LIBS := -lrdmacm -libverbs
endif
CFLAGS += -std=gnu11 -Wall -Wextra -Werror $(RDMA_CFLAGS)
LDLIBS += $(RDMA_LIBS)

.PHONY: all clean

all: scope-remote-agent scope-remote-nic-agent \
	scope-remote-ixgbe-shadow-agent scope-peer-mr-probe

scope-remote-agent: scope_remote_agent.c scope_remote_proto.h
	$(CC) $(CFLAGS) -o $@ scope_remote_agent.c $(LDLIBS)

scope-remote-nic-agent: scope_remote_nic_agent.c scope_remote_proto.h
	$(CC) $(CFLAGS) -o $@ scope_remote_nic_agent.c $(LDLIBS)

scope-remote-ixgbe-shadow-agent: scope_remote_ixgbe_shadow_agent.c scope_remote_proto.h
	$(CC) $(CFLAGS) -o $@ scope_remote_ixgbe_shadow_agent.c $(LDLIBS)

scope-peer-mr-probe: scope_peer_mr_probe.c scope_xdma_peer_uapi.h
	$(CC) $(CFLAGS) -o $@ scope_peer_mr_probe.c $(LDLIBS)

clean:
	rm -f scope-remote-agent scope-remote-nic-agent \
		scope-remote-ixgbe-shadow-agent scope-peer-mr-probe
