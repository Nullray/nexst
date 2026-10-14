# SD 卡只读挂载后的 ext4 元数据错误

2026-10-13，香山 guest 使用 B650 的 `05e3:0751` 读卡器。分区 `/dev/sda1` 为 ext4，UUID `063c7ad1-b8d1-4874-a7d5-c348d08fc0ea`。

用户已经成功列出 SD 根目录、读取 Ubuntu 18.04.6 的 `etc/os-release`，并得到与主机先前读取相同的 README 哈希：

```text
73e05a180ff9544d76d06594fb266f6b4becdb1049231709037d667bec1d936e
```

这证明本次文件读取路径已工作。与此同时，ext4 报出元数据不一致；文件可读及单个文件哈希匹配，不能证明整张卡的文件系统一致性或所有 USB 读取都正确。

## 哪些提示正常，哪些需要检查

| 日志 | 判断 |
|---|---|
| `write access unavailable, skipping orphan cleanup` | 设备报告写保护，内核跳过需要写入的孤儿 inode 清理 |
| `mounted filesystem without journal. Opts: noload` | 与指定的 `ro,noload` 一致；没有加载或回放日志 |
| `ext4_mb_generate_buddy ... bitmap and bg descriptor inconsistent` | 检查检测到空闲空间元数据不一致，不能当作正常成功提示 |

第三类错误来自当前 [内核 mballoc.c](../work_farm/software/linux/fs/ext4/mballoc.c) 的 `ext4_mb_generate_buddy()`：它统计块位图中的空闲 cluster 数量，与 block-group descriptor 导入的计数比较。本轮分别发现：

| block group | 位图统计 | descriptor 计数 |
|---|---:|---:|
| 263 | 2222 | 1830 |
| 262 | 668 | 490 |
| 261 | 652 | 460 |

这些数值是文件系统的空闲空间计数，不是 USB 设备数量、传输长度或 xHCI slot 数量。

## `noload` 为什么可能让它显现

`ro,noload` 防止 ext4 回放 journal，从而保证本轮不写 SD。若上一次未正常卸载，某些已经提交的元数据更新可能仍在 journal 中；不回放时，磁盘上的 bitmap 和 group descriptor 可能处于未恢复的一致性状态。[Linux 5.16 ext4 文档](https://docs.kernel.org/5.16/admin-guide/ext4.html#options) 明确说明，跳过未正常卸载文件系统的日志恢复会留下不一致。

**已经确认这张卡置有 `needs_recovery` 和文件系统错误标志。** 后续 direct-read 的 superblock 实测值为 `s_state=0x0003`、`s_feature_incompat=0x00000246`，详见下面解码。这进一步支持跳过所需 journal 恢复、保留未恢复元数据状态的解释；尚未对未挂载分区执行检查或在副本上验证恢复，所以不能断言回放能消除全部错误。其他文件系统损坏、读取链路或内核问题仍需用更多证据区分。

主机早先在同一 UUID 上也打印过 `write access unavailable, skipping orphan cleanup` 和只读、不加载日志的挂载信息；这些日志证明此前同样跳过恢复，不证明该卡的位图计数已经一致或存在相同的三处错误。

## 当前 guest 中的只读检查

下面命令读取分区起点后 1024 字节处的 ext4 superblock，写入 guest initramfs 的 RAM 临时文件：

```bash
dd if=/dev/sda1 of=/tmp/sd-superblock.bin bs=1024 skip=1 count=1 iflag=direct
od -An -tx2 -j58 -N2 /tmp/sd-superblock.bin
od -An -tx4 -j96 -N4 /tmp/sd-superblock.bin
```

两行分别是小端字段 `s_state` 和 `s_feature_incompat`。当前 BusyBox 已启用 `od` 和 `dd` 的 direct-read 支持。

- `s_state` 的 `0x0001` 位表示 clean，`0x0002` 位表示记录过文件系统错误。
- `s_feature_incompat` 的 `0x00000004` 位表示 `needs_recovery`。不能只比较整个值等于 4，其他 feature 位可能同时存在。
- 存在 `needs_recovery` 会支持“尚未回放日志”的解释，但不能证明回放一定能修复全部错误；不存在该位也不能证明介质或链路没有其他问题。

字段和位定义见当前 [ext4.h](../work_farm/software/linux/fs/ext4/ext4.h)。用户随后提供了实际输出：

```text
s_state            = 0003
s_feature_incompat = 00000246
```

| 字段或位 | 解码 | 结论 |
|---|---|---|
| `0x0003 & 0x0002` | 非零，`EXT4_ERROR_FS` | superblock 记录着文件系统错误 |
| `0x0003 & 0x0001` | 非零，`EXT4_VALID_FS` | clean 位同时存在，但不能覆盖错误位或独立的日志恢复要求 |
| `0x00000246 & 0x00000004` | 非零，`EXT4_FEATURE_INCOMPAT_RECOVER` | 文件系统标记需要 journal 恢复 |
| 其余 `0x2 / 0x40 / 0x200` | filetype / extents / flex_bg | 文件系统功能位，与本次恢复判断分开解释 |

因此这些错误不能作为“正常提示”忽略。当前 `ro,noload` 保留了未恢复状态；现有证据支持该状态与 bitmap/descriptor 不一致有关，但尚未证明它是唯一原因。

本卡报告块设备写保护。当前 [super.c](../work_farm/software/linux/fs/ext4/super.c) 的错误处理路径在 `bdev_read_only()` 为真时跳过写盘错误记录，且本次读的是 direct-read 的盘上 superblock。基于这些条件，可推断盘上的错误标志不是本轮只读挂载之后新写入的标志；仍不能仅凭此定位错误最初产生的时间或原因。

## 离线检查与修复边界

若需要进一步检查，先按 [Runbook 第 7 步](USB_EXPERIMENT_RUNBOOK_ZH.md) 在 guest 卸载分区、停止物理 USB DMA 和 QEMU、把 B650 归还主机。主机识别后核对 UUID、容量和 B650 路径，并确保分区没有挂载，然后才能执行只读检查：

```bash
SD_PART=/dev/disk/by-uuid/063c7ad1-b8d1-4874-a7d5-c348d08fc0ea
sudo dumpe2fs -h "$SD_PART"
sudo e2fsck -fn "$SD_PART"
```

当前 guest 镜像没有提供 e2fsck；这些是归还主机后使用主机 e2fsprogs 的命令，不能在 guest 仍接管 B650 时直接执行。`-n` 只读并拒绝修改，`-f` 强制检查；结果需要与 journal 状态一起解释。只读检查无法通过向原卡回放 journal 验证恢复后的状态。[e2fsck 官方手册源码](https://github.com/tytso/e2fsprogs/blob/master/e2fsck/e2fsck.8.in) 也说明挂载期间的检查结果不可靠。

本轮只做读取和诊断，没有执行修复。若以后需要修复，应先保存数据/镜像，再对副本验证 journal 回放或修复的效果。保持本轮只读挂载；在原卡上回放 journal 或自动修复会改变当前证据和文件内容。
