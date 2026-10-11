现在我给你安排3个连续的长任务。请按顺序逐项完成，不要询问我问题，也不要在任务之间等待确认。遇到不确定项时，优先通过阅读仓库代码、现有文档、Git历史、脚本和必要的网络资料自行判断；如果存在多种方案，请自行比较后选择最符合当前SCOPE架构、风险最低、修改最小的方案。

如果支持调用子agent，可以用于架构分析、Linux PCIe/MSI/MSI-X、GPU/SSD/GIDS/SCADA、代码审查等复杂问题；**所有子agent使用当前可用的最高思考/推理档次**。主agent负责最终整合和判断。

总体要求：

* 先理解当前真实代码，再设计，再实现，再检查和修正；
* 遵循最小修改原则，不做与目标无关的大规模重构；
* 保持现有local-p2p、remote-rdma、NVMe、IXGBE、Vortex等已工作路径兼容；
* 新设计必须和当前代码一致，不能只根据旧文档推测；
* 修改后尽量执行编译、`git diff --check`、现有测试、静态检查和关键状态机人工审查；
* 需要真实FPGA、SSD、RNIC或网络才能完成的测试，可以保留为硬件验证项，但不能因此停止其他工作；
* 对第2、3项，设计文档和代码都要自行审查并修正，直到你认为在当前仓库和硬件约束下已经形成可实现、逻辑闭环的方案。

---

# 任务1：整理当前RDMA/IXGBE修改并提交Git

我近期又修改了一些RDMA相关内容，重点代码包括：

```text
/home/yanjiarun/nexst_proxy_16/qemu-mount/hw/misc/scope_fpga_vswitch_ixgbe_backend.c
```

以及部分相关硬件代码。

当前更新后的总体设计文档：

```text
/home/yanjiarun/nexst_proxy_16/doc/RDMA_REMOTE_DEVICE_INTEGRATION_ARCHITECTURE.md
```

请完成：

1. 检查当前工作区：

   ```bash
   git status
   git diff
   git diff --stat
   ```

   判断哪些修改属于本次RDMA/远端82599工作，不要提交日志、构建产物、临时文件或明显无关修改。

2. 重点确认最近的实现，包括但不限于：

   * remote-rdma 82599 packet-mediated backend；
   * 标准Linux `ixgbe`兼容；
   * BAR/NVM/FWSM/I2C/reset最小语义；
   * TDT/RDT和descriptor处理；
   * `IXGBE_TX` / `IXGBE_TX_COMPLETE`；
   * TX DD writeback和legacy INTx；
   * link状态和无网线测试支持；
   * 对应FPGA/QEMU接口变化。

3. 检查：

   ```text
   doc/RDMA_REMOTE_DEVICE_INTEGRATION_ARCHITECTURE.md
   ```

   是否与当前代码一致。只做必要更新，不要重写整个文档。

4. 为本次RDMA修改创建一个独立、清晰的commit。commit message需要准确说明：

   * 做了什么；
   * 为什么需要；
   * 对现有local路径是否有影响；
   * 当前remote 82599实现边界。

5. commit成功后尝试push到当前分支对应远端。

   * 如果push成功，记录branch、commit hash和remote；
   * 如果push失败，保留本地commit并记录原因，不要破坏现有Git配置；
   * 无论push是否成功，都继续任务2和任务3。

**只有任务1需要commit和push。任务2和任务3不要commit，也不要push。**

---

# 任务2：设计并实现SCOPE的MSI/MSI-X支持

当前SCOPE主要依赖legacy INTx。现在需要分析并实现完整的MSI/MSI-X支持，并覆盖当前可接入的设备类型，包括remote-rdma外设。

目标不是只让Linux看到MSI capability，而是建立正确、统一、可扩展的虚拟中断架构。

## 2.1 分析当前实现

先完整阅读：

* FPGA virtual PCIe switch/proxy；
* config space shadow；
* DMA32协议；
* QEMU `scope_fpga_vswitch*`；
* NVMe、IGB、IXGBE、Vortex backend；
* 当前aggregate INTx路径；
* XiangShan Linux PCI host和中断实现。

明确：

* 当前设备事件如何变成guest中断；
* config capability如何构造；
* 当前是否已有MSI/MSI-X相关基础代码；
* 香山平台实际使用PLIC还是已有其他MSI接收机制；
* 标准Linux `nvme`、`ixgbe`等驱动对MSI/MSI-X的实际要求。

必要时查Linux 5.16源码和权威网络资料。

## 2.2 形成MSI/MSI-X架构设计

新增详细文档，例如：

```text
doc/MSI_MSIX_SUPPORT_ARCHITECTURE.md
```

文档至少明确：

* 当前INTx架构及其限制；
* MSI capability需要维护的enable、address、data、mask、pending等状态；
* MSI-X capability、table、PBA、BIR、vector control、function mask；
* guest对MSI-X table BAR访问的处理方式；
* 多vector如何映射到香山中断体系；
* FPGA/QEMU之间需要新增或扩展什么中断ABI；
* 中断消息需要传semantic vector还是完整MSI address/data，以及理由；
* reset、disable、mask、pending、device removal的语义；
* INTx、MSI、MSI-X如何切换和fallback；
* local设备和remote-rdma设备如何复用同一套虚拟中断接口；
* 为什么remote Host B物理设备的MSI不应直接转发给香山，而应由SCOPE重新生成guest-visible interrupt。

统一设计backend接口，避免NVMe、IXGBE各自维护一套MSI实现。backend应只表达“哪个事件/vector需要被raise”，由统一中断层决定实际使用INTx、MSI还是MSI-X。

## 2.3 编写实现计划

新增：

```text
doc/MSI_MSIX_IMPLEMENTATION_PLAN.md
```

逐文件说明实际修改：

* FPGA RTL；
* DMA32/控制协议；
* QEMU主vSwitch代码；
* config-space代码；
* NVMe backend；
* IXGBE/IGB backend；
* Vortex或其他需要适配的backend；
* Linux/DT部分（如果确实需要）；
* 测试代码。

对每项明确新增状态、接口、函数、状态机和兼容策略。

## 2.4 自审并修改设计

设计完成后重点检查：

* 标准Linux driver是否真的能够成功启用MSI/MSI-X；
* MSI-X table/PBA语义是否正确；
* mask/pending是否正确；
* 多vector是否可靠；
* reset/error path是否完整；
* remote-rdma backend是否能使用同一套接口；
* INTx fallback是否仍可工作；
* FPGA/QEMU之间是否存在丢中断、重复中断或ordering问题。

发现问题直接修改文档，直到认为方案可以实施。

## 2.5 按文档修改代码

按照最终设计实际修改RTL、QEMU以及确实需要的其他部分。

要求：

* 保留INTx fallback；
* local和remote backend共用统一guest interrupt API；
* 不为不同设备复制MSI/MSI-X实现；
* 默认旧配置尽量保持原行为；
* 对旧bitstream或旧ABI兼容能力做明确处理。

修改完成后执行可行的编译和检查，包括：

```bash
git diff --check
```

并检查capability chain、vector allocation、mask/pending、reset、remote disconnect、bounds、endianness和并发问题。

如果发现设计或实现问题，继续修改，直到认为达到目标。

**任务2完成后不要commit，也不要push。保留工作区修改。**

---

# 任务3：将现有GDS扩展为GPU主动发起SSD访问的GIDS/SCADA模式

当前已有Vortex/GDS相关实现。现在需要研究并实现另一种GPU-storage交互方式：

* GPU主动发起storage request；
* GPU尽可能管理SQ/CQ；
* CPU不再作为每个I/O的request scheduler；
* payload仍避免经过CPU memory。

这里暂时称为GIDS/SCADA，但必须先通过资料确认相关工作的真实定义，不能仅根据名称推测。

## 3.1 分析当前GDS实现

完整阅读：

* Vortex；
* 当前GDS代码和测试；
* `scope-vortex-bridge`；
* `libvortex-xrt.so`；
* P2P remapper；
* HBM；
* NVMe/SCOPE backend；
* 当前runbook和脚本。

明确当前实现中：

* 谁创建和管理SQ/CQ；
* 谁构造SQE；
* 谁写NVMe doorbell；
* 谁poll CQ；
* 谁判断GPU kernel完成；
* 谁决定发起storage I/O；
* payload实际经过哪些位置。

## 3.2 网络调研

搜索并阅读权威资料，重点包括：

* NVIDIA SCADA；
* GIDS；
* BaM；
* GPUfs；
* GPUDirect Storage；
* GPU-initiated I/O；
* GPU-managed NVMe queue；
* GPU直接提交SQE/doorbell和poll CQ的相关论文、项目和实现。

优先使用论文、厂商官方资料和真实源码。

明确区分：

* 普通CPU storage I/O；
* GDS；
* GPU-initiated storage；
* GPU-managed queue；
* GPU直接doorbell/CQ；
* 仅仅“SSD DMA到GPU显存”的方案。

## 3.3 编写GIDS架构设计

新增：

```text
doc/VORTEX_GIDS_SCADA_ARCHITECTURE.md
```

至少写清：

### 三种模式

1. 普通CPU memory路径；
2. 当前项目GDS路径；
3. 目标GIDS/SCADA路径。

对每种模式分别说明：

* request initiator；
* queue owner；
* doorbell owner；
* completion consumer；
* payload path；
* CPU involvement。

### GPU侧接口

设计GPU侧最小API，例如：

```c
gids_submit()
gids_read()
gids_write()
gids_poll()
gids_wait()
```

名称可根据项目风格调整。

明确LBA、GPU buffer、length、CID、queue depth、completion和memory ordering。

### Queue ownership

重点比较：

* GPU直接管理真实/虚拟NVMe SQ/CQ；
* GPU管理逻辑SQ/CQ，由SCOPE转换成physical queue。

根据当前Vortex/SCOPE能力选择真正可实现、改动合理的方案。

明确：

* GPU能否直接访问NVMe BAR；
* GPU如何写doorbell；
* HBM地址如何映射为NVMe payload；
* CQ由谁读取；
* CPU是否参与每个request；
* reset、timeout、CID、phase tag、queue wrap如何处理。

如果GPU当前不能直接写NVMe BAR，可以采用最薄的semantic doorbell代理，但GPU必须仍然是request initiator并管理逻辑queue，CPU不能重新成为逐I/O调度者。

## 3.4 编写实现计划

新增：

```text
doc/VORTEX_GIDS_IMPLEMENTATION_PLAN.md
```

列出需要修改的：

* Vortex RTL；
* runtime；
* XRT bridge；
* SCOPE；
* NVMe backend；
* queue管理；
* test kernel；
* scripts；
* runbook。

明确哪些复用现有GDS，哪些必须新增。

## 3.5 自审设计

重点回答：

* I/O request是否真的由GPU产生；
* SQ由谁管理；
* CQ由谁消费；
* doorbell由谁写；
* CPU是否仍处于逐request关键路径；
* payload是否经过CPU memory；
* READ/WRITE是否都可实现；
* 与现有GDS是否可以共存；
* 与SCADA/GIDS等工作的差异是什么。

如果最终只是“CPU替GPU提交I/O”，则不能算完成，需要继续修正方案。

## 3.6 实际实现GIDS

按最终设计修改代码。

优先实现最小真实闭环：

* GPU主动产生READ请求；
* GPU管理逻辑queue；
* SCOPE/NVMe执行；
* SSD数据进入GPU HBM；
* completion最终由GPU侧发现。

然后支持WRITE。

不要为了方便把GIDS重新退化成CPU逐请求调用GDS API。

## 3.7 编写测试runbook

新增：

```text
doc/VORTEX_GIDS_RUNBOOK.md
```

从服务器重启后的环境准备开始，包含：

* FPGA；
* BDF；
* XRT；
* Vortex；
* HBM/P2P；
* NVMe；
* bridge；
* QEMU/SCOPE；
* GIDS模式；
* 测试程序；
* 常见错误。

每一步给出命令、预期结果和失败判断。

## 3.8 实现三种方式的对比实验

必须提供真实实验程序或脚本，对比：

### A. 普通CPU memory方式

SSD与GPU之间经过CPU memory。

### B. 当前GDS方式

CPU发起storage I/O，但payload通过P2P进入GPU HBM。

### C. GIDS方式

GPU主动发起I/O并管理queue/request，SSD直接与GPU HBM交换payload。

尽量保证三种模式使用相同：

* 数据范围；
* I/O size；
* request数量；
* queue depth；
* READ/WRITE；
* 数据校验。

至少采集能够真实获得的：

* bytes；
* IOPS；
* bandwidth；
* average latency；
* P50/P95/P99；
* CPU utilization；
* GPU侧cycles/overhead；
* errors；
* 数据校验结果。

无法准确获得的指标明确标记，不允许伪造。

增加一个统一运行脚本，例如：

```text
tools/run_storage_path_comparison.sh
```

输出CSV或其他机器可读结果。

并把实验方法写入`VORTEX_GIDS_RUNBOOK.md`，包括warm-up、cache影响、测试次数、CPU占用采集、P2P确认、如何证明GIDS中CPU没有逐request参与等。

## 3.9 实现后再次审查

最终重新检查：

1. request由谁产生；
2. SQ由谁管理；
3. CQ由谁消费；
4. doorbell由谁发；
5. 每个I/O是否需要CPU参与；
6. payload是否经过CPU memory；
7. 相比GDS真正增加了什么能力；
8. 与GIDS/SCADA相关工作的差异；
9. 当前硬件限制；
10. 三种实验是否公平。

发现实现与目标不一致时继续修正。

**任务3完成后不要commit，也不要push。保留工作区修改。**

---

# 最终汇报

三个任务全部完成后统一汇报。

## 任务1 Git结果

给出：

```text
branch
commit hash
commit title
remote
push success/failure
```

如果push失败，给出具体原因。

## MSI/MSI-X

说明：

* 新增/修改文档；
* 最终架构；
* FPGA改动；
* QEMU改动；
* backend接口；
* 支持设备；
* INTx fallback；
* 编译和测试结果；
* 仍需真实硬件验证的部分。

## GIDS

说明：

* 调研结论；
* GDS/GIDS/SCADA关系；
* 设计和实现文档；
* 修改代码；
* request initiator；
* SQ/CQ owner；
* doorbell owner；
* control path；
* payload path；
* READ/WRITE支持；
* runbook；
* 三种模式实验；
* 编译/测试结果；
* 仍需真实硬件验证的部分。

最后列出所有实际修改文件，例如：

```text
M path/to/file
A path/to/file
```

并再次执行：

```bash
git status
git diff --check
```

注意：**任务1的RDMA修改单独commit并尝试push；任务2和任务3产生的所有修改均不得commit、不得push。**

不要因为任务时间长或代码量大而停留在分析或计划阶段。持续完成能够完成的实现、检查和文档，只有遇到明确无法通过当前软件环境解决的硬件、权限或外部依赖阻塞时，才在最终结果中说明。
