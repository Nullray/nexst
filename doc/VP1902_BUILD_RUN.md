# VP1902 普通昆明湖 + SCOPE 编译

当前构建为普通单核、双核昆明湖，均包含原 Nanhu 双 BAR 前端和 QDMA slave bridge 主机 buffer。
两份 41 工程的后台启动记录、总日志、重编命令见 [NODE41_BUILD_RUN.md](NODE41_BUILD_RUN.md)。
软件适配、构建和上板运行见 [KUNMINGHU_SCOPE_BRIDGE_IMPLEMENTATION.md](KUNMINGHU_SCOPE_BRIDGE_IMPLEMENTATION.md)。

低层脚本 `tools/build_vp1902.sh` 会记录总阶段日志、原生 Vivado log/journal、内存与设置，并在失败时返回非零。
CPU 核数和 config 必须匹配实际 RTL；修改硬件后重建 shell/role，不沿用旧 XSAI 检查点。
推荐使用 `tools/hardware/run_profile.py` 或双工程 launcher：它们在综合前校验完整 CPU DMA 接线。
已有两份后台进程时不需要再次启动。

单独恢复一份已核对源码的 role 综合，示例双核：

```bash
cd /home/yanjiarun/nexst_kunminghu_dual
scope_resume_log="build/scope-console-$(date +%Y%m%d_%H%M%S)-resume.log"
nohup python3 -u tools/hardware/run_profile.py --num-cores 2 --cpu-kind kunminghu \
  --from-stage role-synth > "$scope_resume_log" 2>&1 < /dev/null &
echo "PID=$! LOG=$scope_resume_log"
```

launcher 使用独立会话；上述直接 nohup 也能在退出终端后继续。
Role 必须生成新的 DCP 后才能生成 PDI。目标 `work_farm/hw_plat/target_kmh_proto_uvhs2/system.pdi`。
`PROFILE_BUILD.json` 的 `complete` 和匹配 PDI 哈希表示整个流程完成，仅有 shell DCP 不代表成功。
