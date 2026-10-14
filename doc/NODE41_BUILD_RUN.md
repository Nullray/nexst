# 41 服务器：单核、双核普通昆明湖 + SCOPE

服务器：`yanjiarun@10.30.19.41:2222`，Vivado 2025.1。
两版均使用普通 `kunminghu` 分支和 `FpgaDefaultConfig`，不使用 XSAI。

| 项目 | 单核 | 双核 |
| --- | --- | --- |
| 工程目录 | `/home/yanjiarun/nexst_kunminghu_single` | `/home/yanjiarun/nexst_kunminghu_dual` |
| 开发分支 | `feature/vp1902-kunminghu-1core-scope-bridge` | `feature/vp1902-kunminghu-2core-scope-bridge` |
| 后台构建 PID（启动时） | `3081741` | `3081742` |
| 总日志 | `build/scope-console-20261014_190940.log` | `build/scope-console-20261014_190940.log` |
| 状态文件 | `build/PROFILE_BUILD.json` | `build/PROFILE_BUILD.json` |
| 目标产物 | `work_farm/hw_plat/target_kmh_proto_uvhs2/system.pdi` | 同左，各自目录内 |

2026-10-14 19:09:40 启动；两版实际 BD 前端检查、shell 综合已通过，CPU role 综合正在进行。
此处是启动记录，后续结果以各目录的 `PROFILE_BUILD.json`、阶段返回码和 PDI 哈希为准。
管理进程使用 `nohup`、独立会话、关闭标准输入，并直接把 stdout/stderr 写入总日志，退出 SSH 不会停止。
单核调度已等待并验证真正的普通单核 RTL，没有复用双核 RTL 冒充单核。

总日志绝对路径：

```text
/home/yanjiarun/nexst_kunminghu_single/build/scope-console-20261014_190940.log
/home/yanjiarun/nexst_kunminghu_dual/build/scope-console-20261014_190940.log
```

按需查看，不需要持续监控：

```bash
cat /home/yanjiarun/nexst_kunminghu_single/build/PROFILE_BUILD.json
cat /home/yanjiarun/nexst_kunminghu_dual/build/PROFILE_BUILD.json
```

每阶段日志在各自 `build/hardware-logs/<时间_PID>/`，Vivado 原生日志、journal 和综合子进程日志保留。
`FRONTEND_CHECK.json` 记录实际 BD 连线检查，`HARDWARE_INPUTS.json` 记录启动综合时的硬件源码哈希。

## 源码与迁移边界

- 主仓库：`NEXST-TOOL/nexst:kunminghu`，`8137ac2a299a354ba10acc89c731af90b6d8c8cb`。
- CPU：`OpenXiangShan/XiangShan`，`4bbdccbb077840af5e1b65c7138d31af3966f625`。
- work_farm：公开 VP1902 版本 `42d3d45e76d8331d5a89ace8355f7abdfb348fe5`。
- 本地维护目录：`/home/yanjiarun/nexst_proxy_17/nexst_kunminghu_scope`，分支 `feature/vp1902-kunminghu-scope-bridge`。
- 原完整迁移目录 `nexst_kunminghu_qdma_hostbuf` 与旧 XSAI 工程保留，不是这两版的 CPU 来源。
- 两版各自重新生成 shell/role 工程和综合检查点；没有复用旧 XSAI shell DCP。

## 后续重编

当前任务仍在运行时不要重复启动。两版需要从头重编时，在 41 执行：

```bash
cd /home/yanjiarun/nexst_kunminghu_dual
python3 tools/hardware/launch_scope_profiles.py \
  --tool-cache /home/yanjiarun/nexst_kunminghu_qdma_hostbuf/build/tool-cache \
  --from-stage full
```

启动器为两版建立独立日志，输出实际 PID、总日志和状态文件，并拒绝重复启动已有任务。
已有 RTL、BD、检查点均匹配当前源码时，可以使用 `wrapper`、`shell-synth`、`role-synth` 或 `pdi`。
修改硬件后需要重新生成工程并综合；不要从旧检查点跳过修改过的阶段。

软件构建和运行见 [KUNMINGHU_SCOPE_BRIDGE_IMPLEMENTATION.md](KUNMINGHU_SCOPE_BRIDGE_IMPLEMENTATION.md)。
