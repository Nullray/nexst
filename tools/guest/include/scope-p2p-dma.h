/* SPDX-License-Identifier: GPL-2.0 */
/* Firmware DMA description for a SCOPE physical xHCI endpoint. */
#ifndef _PCI_SCOPE_P2P_DMA_H
#define _PCI_SCOPE_P2P_DMA_H

#include <linux/dma-direct.h>

#define SCOPE_P2P_CAP_LEN   40
#define SCOPE_P2P_SIGNATURE 0x53435045U
#define SCOPE_P2P_READY     0x444d4150U

struct scope_p2p_dma_state {
	struct pci_dev *pdev;
	const struct bus_dma_region *old_map;
	u64 old_limit;
	int cap;
	struct bus_dma_region map[2];
};

static void scope_p2p_dma_release(void *data)
{
	struct scope_p2p_dma_state *state = data;

	/* Driver remove has already stopped xHC and freed its DMA allocations. */
	pci_write_config_dword(state->pdev, state->cap + 12, 0);
	state->pdev->dev.dma_range_map = state->old_map;
	state->pdev->dev.bus_dma_limit = state->old_limit;
}

static int scope_p2p_read64(struct pci_dev *pdev, int where, u64 *value)
{
	u32 lo, hi;

	if (pci_read_config_dword(pdev, where, &lo) ||
	    pci_read_config_dword(pdev, where + 4, &hi))
		return -EIO;
	*value = lo | ((u64)hi << 32);
	return 0;
}

static int scope_p2p_dma_configure(struct pci_dev *pdev)
{
	struct device *dev = &pdev->dev;
	struct scope_p2p_dma_state *state;
	u64 cpu, bus, size;
	u32 signature, flags, ready;
	u8 len, version;
	int cap, ret, count = 0;

	cap = pci_find_capability(pdev, PCI_CAP_ID_VNDR);
	while (cap && count++ < 48) {
		if (pci_read_config_dword(pdev, cap + 4, &signature))
			return -EIO;
		if (signature == SCOPE_P2P_SIGNATURE)
			break;
		cap = pci_find_next_capability(pdev, cap, PCI_CAP_ID_VNDR);
	}
	if (count > 48)
		return -EINVAL;
	if (!cap)
		return 0;
	if (!IS_ENABLED(CONFIG_SCOPE_PCIE_P2P_DMA)) {
		dev_err(dev, "SCOPE xHCI requires CONFIG_SCOPE_PCIE_P2P_DMA\n");
		return -EOPNOTSUPP;
	}
	if (pdev->class != PCI_CLASS_SERIAL_USB_XHCI ||
	    pci_read_config_byte(pdev, cap + 2, &len) ||
	    pci_read_config_byte(pdev, cap + 3, &version) ||
	    pci_read_config_dword(pdev, cap + 8, &flags) ||
	    len != SCOPE_P2P_CAP_LEN || version != 1 || flags != 3 ||
	    cap + len > PCI_CFG_SPACE_SIZE || get_dma_ops(dev)) {
		dev_err(dev, "invalid SCOPE capability or non-direct DMA ops\n");
		return -EINVAL;
	}
	if (scope_p2p_read64(pdev, cap + 16, &cpu) ||
	    scope_p2p_read64(pdev, cap + 24, &bus) ||
	    scope_p2p_read64(pdev, cap + 32, &size))
		return -EIO;
	if (!size || cpu > U64_MAX - size || bus > U64_MAX - size ||
	    ((cpu | bus | size) & (PAGE_SIZE - 1)) ||
	    cpu > PFN_PHYS(min_low_pfn) || cpu + size < PFN_PHYS(max_pfn)) {
		dev_err(dev, "SCOPE DMA aperture does not cover guest RAM\n");
		return -EINVAL;
	}
	state = devm_kzalloc(dev, sizeof(*state), GFP_KERNEL);
	if (!state)
		return -ENOMEM;
	state->pdev = pdev;
	state->old_map = dev->dma_range_map;
	state->old_limit = dev->bus_dma_limit;
	state->cap = cap;
	state->map[0].cpu_start = cpu;
	state->map[0].dma_start = bus;
	state->map[0].size = size;
	state->map[0].offset = cpu - bus;
	dev->dma_range_map = state->map;
	dev->bus_dma_limit = bus + size - 1;
	ret = devm_add_action_or_reset(dev, scope_p2p_dma_release, state);
	if (ret)
		return ret;
	/* The host refuses bus mastering/RUN until it sees this acknowledgement. */
	if (pci_write_config_dword(pdev, cap + 12, SCOPE_P2P_READY) ||
	    pci_read_config_dword(pdev, cap + 12, &ready) ||
	    ready != SCOPE_P2P_READY)
		return -EIO;
	dev_info(dev, "SCOPE coherent P2P DMA: CPU %#llx -> bus %#llx, size %#llx\n",
		 cpu, bus, size);
	return 0;
}

#endif
