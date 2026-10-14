#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: bash tools/build_vp1902.sh [--stage STAGE | --from-step STEP] [--dry-run]

默认编译 UVHS2 / VP1902：普通昆明湖 RTL → shell 综合 → role 综合 → system.pdi。
自动启用 SCOPE_HOST_PROXY=1；不下载到 FPGA，也不构建 Linux/QEMU。

环境变量：
  CONFIG              默认 FpgaDefaultConfig
  NUM_CORES           支持 1 或 2；双核须有匹配的 RTL_PROFILE.json
  VIVADO_VERSION      当前脚本使用 2025.1
  VIVADO_TOOL_BASE     默认 /opt/Xilinx_2025.1
  VIVADO_MAX_THREADS   Vivado 常规线程上限，默认 1
  VIVADO_SYNTH_THREADS 综合并行进程上限，默认 1；减少内存峰值
  VIVADO_MIN_AVAILABLE_GIB 构建前最低可用内存，默认 192 GiB
  VIVADO_SHARED_LOCK_FILE 默认仓库上级的 .vp1902-vivado.lock
  ROLE_SYNTH_DIRECTIVE 默认 RuntimeOptimized；可改为 AlternateRoutability
  ROLE_SYNTH_FLATTEN   默认 rebuilt
  JVM_XMX / JVM_XSS    可选，传给 普通昆明湖 构建

--dry-run 只打印命令，不创建目录、不移动旧 RTL、不执行编译。
--stage 可选 all、rtl、shell、role、pdi，或单个 shell-gen/shell-synth/role-gen/role-synth。
--from-step 从 rtl/shell-gen/shell-synth/role-gen/role-synth/pdi 续编至 PDI。
阶段模式不会跟踪源码变化；更换核配置或修改依赖后请运行完整 all 流程。
EOF
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    if [[ -v hw_logdir ]]; then
        printf 'ERROR: %s\n' "$*" >>"$hw_logdir/failure.log"
    fi
    exit 1
}

hw_stage=all
hw_stage_set=0
hw_from_step=
hw_dry_run=0
while (( $# )); do
    case "$1" in
        --stage)
            (( $# >= 2 )) || fail "--stage 需要一个参数"
            hw_stage=$2
            hw_stage_set=1
            shift 2
            ;;
        --from-step)
            (( $# >= 2 )) || fail "--from-step 需要一个参数"
            hw_from_step=$2
            [[ -n "$hw_from_step" ]] || fail "--from-step 不能为空"
            shift 2
            ;;
        --dry-run) hw_dry_run=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "未知参数：$1；使用 --help 查看用法" ;;
    esac
done
if [[ -n "$hw_from_step" ]]; then
    (( hw_stage_set == 0 )) || fail "--stage 和 --from-step 不能同时使用"
    case "$hw_from_step" in
        rtl) hw_selected_steps="rtl shell-gen shell-synth role-gen role-synth pdi" ;;
        shell-gen) hw_selected_steps="shell-gen shell-synth role-gen role-synth pdi" ;;
        shell-synth) hw_selected_steps="shell-synth role-gen role-synth pdi" ;;
        role-gen) hw_selected_steps="role-gen role-synth pdi" ;;
        role-synth) hw_selected_steps="role-synth pdi" ;;
        pdi) hw_selected_steps=pdi ;;
        *) fail "无效续编步骤：$hw_from_step" ;;
    esac
else
    case "$hw_stage" in
        all) hw_selected_steps="rtl shell-gen shell-synth role-gen role-synth pdi" ;;
        shell) hw_selected_steps="shell-gen shell-synth" ;;
        role) hw_selected_steps="role-gen role-synth" ;;
        rtl|shell-gen|shell-synth|role-gen|role-synth|pdi) hw_selected_steps=$hw_stage ;;
        *) fail "无效阶段：$hw_stage" ;;
    esac
fi

hw_repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
hw_profile_cores=1
if [[ -f "$hw_repo/config/kunminghu-profile.json" ]]; then
    hw_profile_cores=$(python3 "$hw_repo/tools/hardware/profile.py" --field num_cores) || fail "无法读取版本核数配置"
fi
[[ -v CPU_KIND ]] || CPU_KIND=kunminghu
case "$CPU_KIND" in kunminghu) ;; *) fail "此架构必须使用 CPU_KIND=kunminghu" ;; esac
if [[ ! -v CONFIG ]]; then
    CONFIG=FpgaDefaultConfig
fi
[[ -v NUM_CORES ]] || NUM_CORES=$hw_profile_cores
[[ -v VIVADO_VERSION ]] || VIVADO_VERSION=2025.1
[[ -v VIVADO_TOOL_BASE ]] || VIVADO_TOOL_BASE="/opt/Xilinx_$VIVADO_VERSION"
[[ -v VIVADO_MAX_THREADS ]] || VIVADO_MAX_THREADS=1
[[ -v VIVADO_SYNTH_THREADS ]] || VIVADO_SYNTH_THREADS=1
[[ -v VIVADO_MIN_AVAILABLE_GIB ]] || VIVADO_MIN_AVAILABLE_GIB=192
[[ -v ROLE_SYNTH_DIRECTIVE ]] || ROLE_SYNTH_DIRECTIVE=RuntimeOptimized
[[ -v ROLE_SYNTH_FLATTEN ]] || ROLE_SYNTH_FLATTEN=rebuilt
[[ "$VIVADO_MIN_AVAILABLE_GIB" =~ ^(0|[1-9][0-9]{0,2})$ ]] || fail "VIVADO_MIN_AVAILABLE_GIB 必须为 0..999 的整数"
case "$ROLE_SYNTH_DIRECTIVE" in RuntimeOptimized|AlternateRoutability|Default) ;; *) fail "不支持的 ROLE_SYNTH_DIRECTIVE" ;; esac
case "$ROLE_SYNTH_FLATTEN" in none|rebuilt|full) ;; *) fail "不支持的 ROLE_SYNTH_FLATTEN" ;; esac
[[ "$CONFIG" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || fail "CONFIG 必须为配置类名称"
[[ "$NUM_CORES" == 1 || "$NUM_CORES" == 2 ]] || fail "NUM_CORES 必须为 1 或 2"
[[ "$VIVADO_VERSION" == 2025.1 ]] || fail "当前 VP1902 流程使用 VIVADO_VERSION=2025.1"
[[ "$VIVADO_MAX_THREADS" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] ||
    fail "VIVADO_MAX_THREADS 必须为 1..32 的整数"
[[ "$VIVADO_SYNTH_THREADS" =~ ^[1-8]$ ]] || fail "VIVADO_SYNTH_THREADS 必须为 1..8 的整数"

hw_repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
hw_farm="$hw_repo/work_farm"
hw_xs="$hw_repo/kmh/hardware/xs-gen"
hw_generated="$hw_repo/kmh/hardware/sources/generated"
hw_vivado_bin="$VIVADO_TOOL_BASE/Vivado/$VIVADO_VERSION/Vivado/bin"
hw_shell_id=shell_uvhs2_uvhs2
hw_role_id=target_kmh_proto_uvhs2
hw_shell_project="$hw_farm/fpga/vivado_prj/$hw_shell_id/$hw_shell_id.xpr"
hw_shell_bd="$hw_farm/fpga/vivado_prj/$hw_shell_id/$hw_shell_id.srcs/sources_1/bd/xiangshan/xiangshan.bd"
hw_role_project="$hw_farm/fpga/vivado_prj/$hw_role_id/$hw_role_id.xpr"
hw_shell_dcp="$hw_farm/fpga/vivado_out/$hw_shell_id/dcp/synth.dcp"
hw_role_dcp="$hw_farm/fpga/vivado_out/$hw_role_id/dcp/synth.dcp"
hw_pdi="$hw_farm/hw_plat/$hw_role_id/system.pdi"

# Keep the board and shell consistent with the role checkpoint import script.
export CPU_KIND CONFIG NUM_CORES VIVADO_VERSION VIVADO_TOOL_BASE
export VIVADO_MAX_THREADS VIVADO_SYNTH_THREADS VIVADO_MIN_AVAILABLE_GIB
export ROLE_SYNTH_DIRECTIVE ROLE_SYNTH_FLATTEN
export FPGA_BD=uvhs2 SCOPE_HOST_PROXY=1
[[ "$hw_repo" != *[[:space:]]* && "$VIVADO_TOOL_BASE" != *[[:space:]]* ]] ||
    fail "上游 Makefile 尚不支持包含空白的仓库或 Vivado 路径"
[[ -f "$hw_farm/Makefile" && -f "$hw_xs/Makefile" ]] ||
    fail "缺少 work_farm 或 普通昆明湖 源码；请先初始化子模块"

require_file() {
    (( hw_dry_run )) && return 0
    [[ -s "$1" ]] || fail "缺少前置产物：$1；请先编译对应阶段"
}

verify_core_profile() {
    (( hw_dry_run )) && return 0
    if [[ "$NUM_CORES" == 2 || -f "$hw_repo/build/RTL_PROFILE.json" ]]; then
        require_file "$hw_repo/build/RTL_PROFILE.json"
        python3 "$hw_repo/tools/hardware/prepare_xstop_wrapper.py" \
            --num-cores "$NUM_CORES" --config "$CONFIG" --cpu-kind "$CPU_KIND" --check ||
            fail "RTL 与 wrapper 的核数或接口不匹配"
    fi
}

require_proxy_project() {
    require_file "$hw_shell_project"
    (( hw_dry_run )) && return 0
    require_file "$hw_shell_bd"
    python3 "$hw_repo/tools/hardware/check_frontend.py" --shell-only ||
        fail "shell 缺少 coherent DMA 或 slave bridge 通知通路；请重新生成 shell"
}

run_step() {
    local step=$1 artifact=$2
    shift 2
    # Propagate pipefail into work_farm's recursive Vivado | tee recipe.
    set -- "$@" SHELL=/bin/bash ".SHELLFLAGS=-o pipefail -c"
    printf '\n[%s] ' "$step"
    printf '%q ' "$@"
    printf '\n'
    (( hw_dry_run )) && return 0
    local logfile="$hw_logdir/$step.log" marker="$hw_logdir/$step.started"
    touch "$marker"
    if ! "$@" 2>&1 | tee "$logfile"; then
        fail "$step 命令失败，日志：$logfile"
    fi
    # work_farm's inner tee can hide the Vivado exit status.
    if grep -nEi '^[[:space:]]*(ERROR:|FATAL:|make(\[[0-9]+\])?: \*\*\*)|(^|[[:space:]])Killed([[:space:]]|$)|Segmentation fault|Parent process.*has died' "$logfile"; then
        fail "$step 日志包含错误，日志：$logfile"
    fi
    [[ -s "$artifact" && "$artifact" -nt "$marker" ]] ||
        fail "$step 未生成新的非空产物：$artifact；日志：$logfile"
    if grep -q 'CRITICAL WARNING:' "$logfile"; then
        printf '请检查 %s 中的 CRITICAL WARNING。\n' "$logfile" >&2
    fi
}

ensure_link() {
    local destination=$1 target=$2
    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ "$(readlink -f "$destination")" == "$(readlink -f "$target")" ]] ||
            fail "工作目录指向其他源码：$destination"
    else
        ln -s "$target" "$destination"
    fi
}

if (( ! hw_dry_run )); then
    command -v make >/dev/null || fail "找不到 make"
    command -v flock >/dev/null || fail "找不到 flock（util-linux）"
    if [[ " $hw_selected_steps " == *" rtl "* ]]; then
        command -v java >/dev/null || fail "找不到 Java"
        command -v mill >/dev/null || fail "找不到 Mill"
        [[ -x /usr/bin/time ]] || fail "找不到 /usr/bin/time（GNU time），RTL 生成需要该程序"
        hw_modules=$(git -C "$hw_xs" submodule status --recursive) ||
            fail "无法检查 普通昆明湖 子模块"
        if grep -qE '^[-+U]' <<<"$hw_modules"; then
            fail "普通昆明湖 子模块尚未初始化或不匹配 gitlink，请先检查子模块"
        fi
    fi
    if [[ "$hw_selected_steps" != rtl ]]; then
        [[ -x "$hw_vivado_bin/vivado" ]] ||
            fail "找不到 $hw_vivado_bin/vivado；请设置 VIVADO_TOOL_BASE"
    fi
    mkdir -p "$hw_repo/build"
    exec 9>"$hw_repo/build/vp1902-build.lock"
    flock -n 9 || fail "已有另一个本脚本的硬件构建正在运行"
    # A shared lock prevents two copies from synthesizing simultaneously.
    hw_shared_lock=${VIVADO_SHARED_LOCK_FILE:-"$hw_repo/../.vp1902-vivado.lock"}
    [[ "$hw_shared_lock" != *[[:space:]]* ]] || fail "共享构建锁路径不支持空白"
    exec 8>"$hw_shared_lock"
    flock -n 8 || fail "另一个 VP1902 构建正在占用共享构建锁"
    if [[ "$hw_selected_steps" != rtl ]]; then
        hw_available_kib=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)
        [[ "$hw_available_kib" =~ ^[0-9]+$ ]] || fail "无法读取主机可用内存"
        (( hw_available_kib >= VIVADO_MIN_AVAILABLE_GIB * 1048576 )) ||
            fail "可用内存不足 $VIVADO_MIN_AVAILABLE_GIB GiB；请等其他任务结束后启动"
    fi
    hw_logdir="$hw_repo/build/hardware-logs/$(date +%Y%m%d_%H%M%S)_$$"
    export VIVADO_NATIVE_LOG_DIR="$hw_logdir/vivado-native"
    mkdir -p "$hw_logdir" "$VIVADO_NATIVE_LOG_DIR" "$hw_farm/target"
    printf 'CONFIG=%s\nNUM_CORES=%s\nVIVADO_VERSION=%s\nVIVADO_MAX_THREADS=%s\nVIVADO_SYNTH_THREADS=%s\nSTEPS=%s\n' \
        "$CONFIG" "$NUM_CORES" "$VIVADO_VERSION" "$VIVADO_MAX_THREADS" "$VIVADO_SYNTH_THREADS" \
        "$hw_selected_steps" >"$hw_logdir/build-settings.txt"
    printf 'ROLE_SYNTH_DIRECTIVE=%s\nROLE_SYNTH_FLATTEN=%s\nVIVADO_MIN_AVAILABLE_GIB=%s\n' \
        "$ROLE_SYNTH_DIRECTIVE" "$ROLE_SYNTH_FLATTEN" "$VIVADO_MIN_AVAILABLE_GIB" >>"$hw_logdir/build-settings.txt"
    printf 'VIVADO_NATIVE_LOG_DIR=%s\n' "$VIVADO_NATIVE_LOG_DIR" >>"$hw_logdir/build-settings.txt"
    printf 'VIVADO_SHARED_LOCK_FILE=%s\n' "$hw_shared_lock" >>"$hw_logdir/build-settings.txt"
    printf 'CPU_KIND=%s\n' "$CPU_KIND" >>"$hw_logdir/build-settings.txt"
    cp /proc/meminfo "$hw_logdir/memory-at-start.txt"
    ensure_link "$hw_farm/target/kmh" "$hw_repo/kmh"
    ensure_link "$hw_farm/shell" "$hw_repo/shell"
    ensure_link "$hw_farm/tools" "$hw_repo/tools"
    printf '日志目录：%s\n' "$hw_logdir"
    printf 'Vivado 原生日志目录：%s\n' "$VIVADO_NATIVE_LOG_DIR"
fi

for hw_step in $hw_selected_steps; do
case "$hw_step" in
rtl)
    if (( ! hw_dry_run )); then
        # Preserve previous generated files, then regenerate for this configuration.
        mkdir -p "$hw_logdir/previous-rtl"
        for directory in "$hw_xs/build/rtl" "$hw_generated"; do
            [[ ! -L "$directory" ]] || fail "生成目录不能是符号链接：$directory"
        done
        if [[ -d "$hw_xs/build/rtl" ]]; then
            mv "$hw_xs/build/rtl" "$hw_logdir/previous-rtl/xs-gen"
        fi
        if [[ -d "$hw_generated" ]]; then
            mv "$hw_generated" "$hw_logdir/previous-rtl/generated"
        fi
    fi
    run_step rtl "$hw_generated/XSTop.v" \
        make -C "$hw_farm" -B PRJ=target:kmh \
        "CONFIG=$CONFIG" "NUM_CORES=$NUM_CORES" xs_gen
    if (( ! hw_dry_run )); then
        python3 "$hw_repo/tools/hardware/prepare_xstop_wrapper.py" --num-cores "$NUM_CORES" \
            --config "$CONFIG" --cpu-kind "$CPU_KIND" || fail "CPU wrapper 生成失败"
    fi
    ;;

shell-gen)
    run_step shell-gen "$hw_farm/hw_plat/$hw_shell_id/system.hdf" \
        make -C "$hw_farm" PRJ=shell:uvhs2 FPGA_ACT=prj_gen vivado_prj
    require_proxy_project
    ;;
shell-synth)
    require_proxy_project
    run_step shell-synth "$hw_shell_dcp" \
        make -C "$hw_farm" PRJ=shell:uvhs2 FPGA_ACT=run_syn vivado_prj
    ;;

role-gen)
    require_file "$hw_generated/XSTop.v"
    verify_core_profile
    run_step role-gen "$hw_farm/hw_plat/$hw_role_id/system.hdf" \
        make -C "$hw_farm" PRJ=target:kmh:proto FPGA_ACT=prj_gen vivado_prj
    require_file "$hw_role_project"
    ;;
role-synth)
    require_file "$hw_generated/XSTop.v"
    verify_core_profile
    require_file "$hw_role_project"
    run_step role-synth "$hw_role_dcp" \
        make -C "$hw_farm" PRJ=target:kmh:proto FPGA_ACT=run_syn vivado_prj
    ;;

pdi)
    require_proxy_project
    require_file "$hw_shell_dcp"
    require_file "$hw_role_dcp"
    run_step pdi "$hw_pdi" \
        make -C "$hw_farm" PRJ=target:kmh:proto FPGA_ACT=bit_gen vivado_prj
    if (( ! hw_dry_run )); then
        hw_timing="$hw_farm/fpga/vivado_out/$hw_role_id/impl_rpt/post_route_timing.rpt"
        require_file "$hw_timing"
        [[ "$hw_timing" -nt "$hw_logdir/pdi.started" ]] ||
            fail "布局布线时序报告未更新：$hw_timing"
        if ! grep -qi 'All user specified timing constraints are met' "$hw_timing"; then
            fail "时序报告没有确认约束已满足，请检查：$hw_timing"
        fi
        printf '\nPDI：%s\n时序报告：%s\n' "$hw_pdi" "$hw_timing"
    fi
    ;;
esac
done
if (( hw_dry_run )); then
    printf '\n预览完成，未执行编译。完整构建的预期 PDI：%s\n' "$hw_pdi"
else
    printf '\n步骤 %s 完成。日志：%s\n' "$hw_selected_steps" "$hw_logdir"
fi
printf '普通昆明湖 SCOPE：BAR2 coherent alias → CPU DMA/L3；通知 → No Address Translation slave bridge。上板验收仍需执行。\n'
