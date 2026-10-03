#!/usr/bin/env bash
#
# ============================================================================
#  通用内核构建脚本 —— 小米 / 红米（以及任何标准内核树）
# ============================================================================
#
# 为什么单独一个脚本，而不是复用「Build Kernel OnePlus.yml」：
#   一加那套是**清单驱动**的（AOSP repo 工具 + OnePlusOSS kernel_manifest），
#   并且全程依赖 `vendor/oplus/*` 的补丁与 CONFIG_OPLUS_* 配置。
#   小米官方 OSS 仓库（MiCode/Xiaomi_Kernel_OpenSource）**每个机型一个普通内核树**：
#     · 没有清单，直接 clone 分支
#     · 没有 vendor/oplus，OnePlus 那些补丁在小米树上根本不存在
#     · **源码在仓库根目录**（实测 mondrian-s-oss / rubens-s-oss / socrates-t-oss
#       都是根目录有 Makefile + drivers/ + arch/，没有 common/ 子目录）
#   所以两者只能各走各的路。本脚本负责小米这一路。
#
# ── 它是怎么做到「任何机型都能编」的 ──────────────────────────────────────────
#   从内核自己的 Makefile 读出 VERSION / PATCHLEVEL / SUBLEVEL，据此自动选：
#
#     ┌────────────┬──────────────┬─────────────────────┬────────────────────┐
#     │ 内核       │ 工具链       │ make 目标            │ 典型机型           │
#     ├────────────┼──────────────┼─────────────────────┼────────────────────┤
#     │ 4.4–4.19   │ GCC          │ Image.gz-dtb         │ K20/K30/K40、Note  │
#     │ 5.4        │ Clang        │ Image                │ 少量               │
#     │ 5.10–5.15  │ Clang(LLVM=1)│ Image                │ K50/K60/K60Pro 等  │
#     │ 6.1–6.12   │ Clang(LLVM=1)│ Image                │ K70/K80 等         │
#     └────────────┴──────────────┴─────────────────────┴────────────────────┘
#
#   实测过的真实版本（用 git ls-tree / git show 读的，不是猜的）：
#     mondrian-s-oss  红米 K60     5.10.81   有 gki_defconfig
#     rubens-s-oss    红米 K50     5.10.66   有 gki_defconfig
#     socrates-t-oss  红米 K60 Pro 5.15.41   厂商 defconfig
#     corot-t-oss     红米 K60 Ultra 5.15.78 厂商 defconfig
#
# ── 用法 ─────────────────────────────────────────────────────────────────────
#   先看这台机型有哪些 defconfig（小米树里有几百个，先查再选）：
#     ./build-kernel-generic.sh --kernel-dir kernel --list-defconfigs
#
#   编一个 5.10 的红米（骁龙，有 gki_defconfig）：
#     ./build-kernel-generic.sh \
#       --kernel-dir kernel --defconfig gki_defconfig \
#       --clang-dir toolchain/clang --kmi redmi-k60 --ak3
#
#   编一个 4.14 的老红米（GCC）：
#     ./build-kernel-generic.sh \
#       --kernel-dir kernel --defconfig <机型>_defconfig \
#       --toolchain gcc --gcc-dir gcc-aarch64
#
#   带 paperSU / KernelSU 内置模式：
#     ./build-kernel-generic.sh --kernel-dir kernel --defconfig gki_defconfig \
#       --clang-dir toolchain/clang \
#       --ksu-src /path/to/PaperSU \
#       --ksu-package top.becuy.eric.papersu \
#       --ksu-size2 0x036d \
#       --ksu-hash2 14ea1b98c9f693f282a05022b8cf02dcbd2dd8e28c9d6b97bd6acfda1352f82f \
#       --ak3
#
#   只看它打算干什么（不需要本机有工具链）：
#     ./build-kernel-generic.sh --kernel-dir kernel --defconfig x --dry-run
#
# ── 参数 ─────────────────────────────────────────────────────────────────────
#   --kernel-dir <dir>       内核源码目录（必填）
#   --defconfig <name>       配置名（与 --list-defconfigs / --config-from-device 二选一）
#   --list-defconfigs        列出可用的 defconfig 后退出
#   --config-from-device     从已 root 的设备抓 /proc/config.gz 当基线
#   --arch <arch>            默认 arm64
#   --out <dir>              输出目录（默认 <kernel-dir>/../out-generic）
#   --jobs <n>               并行度
#   --toolchain <auto|gcc|clang|llvm>
#   --gcc-dir <dir>          GCC 工具链根（4.x 用）
#   --clang-dir <dir>        Clang 工具链根（5.x/6.x 用）
#   --cross-compile <pfx>    覆盖 CROSS_COMPILE
#   --target <name>          覆盖 make 目标
#   --kmi <label>            产物命名用（如 redmi-k60）
#   --sublevel <n>           伪装 SUBLEVEL（改 Makefile，会记录原始值）
#   --thinlto-cache <dir>    6.x thin LTO 缓存
#   --ksu-src <dir>          paperSU/KernelSU 仓库根（含 kernel/）→ 内置模式
#   --ksu-package/size2/hash2 管理器身份（make 变量，不是配置项）
#   --extra-config <a,b>     额外打开的内核配置
#   --extra-make <a,b>       额外 make 参数
#   --ak3                    编完自动打 AnyKernel3 zip
#   --ak3-repo <url>         AK3 模板来源（默认 Numbersf/AnyKernel3）
#   --ak3-string <text>      改写 AK3 的 kernel.string（默认 OnePlus 文案，小米应改）
#   --clean                  先 make clean
#   --dry-run                只打印命令
#
# Windows 上请在 Git Bash / WSL / CI 里跑（本脚本不跑 Windows）。
#
set -eu

say()  { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n=== %s ===\n' "$*"; }
run()  { if [ "$DRY_RUN" -eq 1 ]; then printf '  [dry-run] %s\n' "$*"; else "$@"; fi; }

# ── 默认值 ───────────────────────────────────────────────────────────────────
KDIR="" ; DEFCONFIG="" ; OUT="" ; ARCH=arm64 ; JOBS=""
TOOLCHAIN=auto ; GCC_DIR="" ; CLANG_DIR="" ; CROSS_COMPILE="" ; TARGET="" ; KMI=""
SUBLEVEL_OVERRIDE="" ; THINLTO_CACHE=""
KSU_SRC="" ; KSU_PACKAGE="" ; KSU_SIZE2="" ; KSU_HASH2=""
EXTRA_CONFIG="" ; EXTRA_MAKE=""
AK3=0 ; AK3_REPO="https://github.com/Numbersf/AnyKernel3" ; AK3_STRING=""
DO_CLEAN=0 ; DRY_RUN=0 ; CONFIG_FROM_DEVICE=0 ; LIST_DEFCONFIGS=0

need_val() { [ "$2" -ge 2 ] || die "$1 需要一个值"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --kernel-dir) need_val "$1" $#; KDIR=$2; shift 2;;
    --defconfig) need_val "$1" $#; DEFCONFIG=$2; shift 2;;
    --list-defconfigs) LIST_DEFCONFIGS=1; shift;;
    --config-from-device) CONFIG_FROM_DEVICE=1; shift;;
    --arch) need_val "$1" $#; ARCH=$2; shift 2;;
    --out) need_val "$1" $#; OUT=$2; shift 2;;
    --jobs) need_val "$1" $#; JOBS=$2; shift 2;;
    --toolchain) need_val "$1" $#; TOOLCHAIN=$2; shift 2;;
    --gcc-dir) need_val "$1" $#; GCC_DIR=$2; shift 2;;
    --clang-dir) need_val "$1" $#; CLANG_DIR=$2; shift 2;;
    --cross-compile) need_val "$1" $#; CROSS_COMPILE=$2; shift 2;;
    --target) need_val "$1" $#; TARGET=$2; shift 2;;
    --kmi) need_val "$1" $#; KMI=$2; shift 2;;
    --sublevel) need_val "$1" $#; SUBLEVEL_OVERRIDE=$2; shift 2;;
    --thinlto-cache) need_val "$1" $#; THINLTO_CACHE=$2; shift 2;;
    --ksu-src) need_val "$1" $#; KSU_SRC=$2; shift 2;;
    --ksu-package) need_val "$1" $#; KSU_PACKAGE=$2; shift 2;;
    --ksu-size2) need_val "$1" $#; KSU_SIZE2=$2; shift 2;;
    --ksu-hash2) need_val "$1" $#; KSU_HASH2=$2; shift 2;;
    --extra-config) need_val "$1" $#; EXTRA_CONFIG=$2; shift 2;;
    --extra-make) need_val "$1" $#; EXTRA_MAKE=$2; shift 2;;
    --ak3) AK3=1; shift;;
    --ak3-repo) need_val "$1" $#; AK3_REPO=$2; shift 2;;
    --ak3-string) need_val "$1" $#; AK3_STRING=$2; shift 2;;
    --clean) DO_CLEAN=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) sed -n '2,86p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) die "未知参数：$1（用 --help 看用法）";;
  esac
done

# ── 前置检查 ─────────────────────────────────────────────────────────────────
# `--dry-run` 与 `--list-defconfigs` 都是**纯查看**操作：Windows 的 Git Bash 里
# 没有 make，但用户恰恰会先用这两个命令做规划/查配置，所以不要求 make。
[ -n "$KDIR" ] || die "必须给 --kernel-dir"
[ -d "$KDIR" ] || die "内核目录不存在：$KDIR"
for c in sed awk; do command -v "$c" >/dev/null 2>&1 || die "缺少 $c"; done
if [ "$DRY_RUN" -eq 0 ] && [ "$LIST_DEFCONFIGS" -eq 0 ]; then
  command -v make >/dev/null 2>&1 || die "缺少 make（--dry-run / --list-defconfigs 不需要它）"
fi
KDIR=$(cd "$KDIR" && pwd)

# ── 定位源码根：兼容两种布局 ─────────────────────────────────────────────────
# 小米官方 OSS：源码在仓库根（实测 mondrian/rubens/socrates 都是）
# GKI / 一加那种：内核源码在 common/，顶层是 platform 根
if [ -f "$KDIR/common/Makefile" ]; then
  SRCROOT="$KDIR/common"
  LAYOUT="GKI（源码在 common/）"
else
  SRCROOT="$KDIR"
  LAYOUT="标准（源码在仓库根）"
fi
[ -f "$SRCROOT/Makefile" ] || die "$KDIR 里找不到 Makefile（既不是仓库根也没有 common/）"

if [ "$LIST_DEFCONFIGS" -eq 1 ]; then
  step "可用的 defconfig（$SRCROOT/arch/$ARCH/configs/）"
  CFGDIR="$SRCROOT/arch/$ARCH/configs"
  if [ -d "$CFGDIR" ]; then
    # 必须**递归**列：老机型（4.x 高通树）把机型配置放在 configs/vendor/ 下。
    # 实测 alioth-r-oss（红米 K40，4.19）25 个里 17 个在 vendor/；
    #      sweet-r-oss（红米 Note 10 Pro，4.14）36 个里 31 个在 vendor/。
    # 新机型（5.10/5.15）则全在顶层。只列顶层会让 4.x 用户看到空列表。
    ( cd "$CFGDIR" && find . -name '*defconfig' | sed 's|^\./||' | sort | sed 's/^/  /' )
    say ""
    say "  共 $( cd "$CFGDIR" && find . -name '*defconfig' | wc -l | tr -d ' ' ) 个"
  else
    die "没有 $CFGDIR 目录"
  fi
  say ""
  say "  用 --defconfig <名字> 传进来："
  say "    · 顶层的直接写名字，如 gki_defconfig"
  say "    · vendor/ 下的要带路径，如 vendor/alioth_user_defconfig"
  exit 0
fi

# ── 版本探测：这是「任何机型都能编」的核心 ───────────────────────────────────
V=$(sed -n 's/^VERSION *= *//p'         "$SRCROOT/Makefile" | head -n1)
P=$(sed -n 's/^PATCHLEVEL *= *//p'      "$SRCROOT/Makefile" | head -n1)
S=$(sed -n 's/^SUBLEVEL *= *//p'        "$SRCROOT/Makefile" | head -n1)
[ -n "$V" ] && [ -n "$P" ] || die "无法从 $SRCROOT/Makefile 读出 VERSION/PATCHLEVEL"
KVER="$V.$P"
KVER_FULL="$KVER${S:+.$S}"

case "$V" in
  4|5|6) ;;
  *) die "探测到 Linux $KVER_FULL —— 本脚本覆盖 4.x/5.x/6.x；其它版本请自行改默认值";;
esac

case "$KVER" in
  4.*)   DEF_TOOLCHAIN=gcc  ; DEF_TARGET=Image.gz-dtb ;;
  5.4)   DEF_TOOLCHAIN=clang; DEF_TARGET=Image ;;
  5.*)   DEF_TOOLCHAIN=llvm ; DEF_TARGET=Image ;;
  6.*)   DEF_TOOLCHAIN=llvm ; DEF_TARGET=Image ;;
  *)     DEF_TOOLCHAIN=llvm ; DEF_TARGET=Image ;;
esac
[ "$TOOLCHAIN" = "auto" ] && TOOLCHAIN=$DEF_TOOLCHAIN
[ -z "$TARGET" ] && TARGET=$DEF_TARGET
case "$TOOLCHAIN" in gcc|clang|llvm) ;; *) die "--toolchain 只能是 auto/gcc/clang/llvm";; esac

[ -n "$JOBS" ] || JOBS=$( { command -v nproc >/dev/null 2>&1 && nproc; } || echo 4 )
[ -n "$OUT" ] || OUT="$(dirname "$KDIR")/out-generic"
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT";; esac

step "环境"
say "  布局       : $LAYOUT"
say "  源码根     : $SRCROOT"
say "  编译根     : $KDIR"
say "  内核版本   : $KVER_FULL"
say "  架构       : $ARCH"
say "  工具链     : $TOOLCHAIN"
say "  make 目标  : $TARGET"
say "  输出目录   : $OUT"
say "  并行度     : $JOBS"
[ -n "$KMI" ] && say "  标签       : $KMI"

if [ "$V" = "4" ] && [ "$TOOLCHAIN" != "gcc" ]; then
  warn "4.x 通常用 GCC。若汇编报错，换 --toolchain gcc。"
fi
if [ "$V" -ge 5 ] && [ "$TOOLCHAIN" = "gcc" ]; then
  warn "$KVER 通常用 Clang。部分厂商树可以，但 GKI 分支一般不行。"
fi

# ── 伪装 SUBLEVEL（可选；改之前记录原值）────────────────────────────────────
if [ -n "$SUBLEVEL_OVERRIDE" ]; then
  step "伪装 SUBLEVEL"
  say "  $S -> $SUBLEVEL_OVERRIDE （原值记录在 $SRCROOT/Makefile.orig-sublevel）"
  if [ "$DRY_RUN" -eq 0 ]; then
    [ -f "$SRCROOT/Makefile.orig-sublevel" ] || cp "$SRCROOT/Makefile" "$SRCROOT/Makefile.orig-sublevel"
    sed -i "s/^SUBLEVEL[[:space:]]*=[[:space:]]*.*/SUBLEVEL = $SUBLEVEL_OVERRIDE/" "$SRCROOT/Makefile"
  fi
fi

# ── 工具链 ───────────────────────────────────────────────────────────────────
MAKE_ARGS=("ARCH=$ARCH" "O=$OUT")
prepare_toolchain() {
  case "$TOOLCHAIN" in
    gcc)
      local pfx="$CROSS_COMPILE"
      [ -n "$pfx" ] || pfx="${GCC_DIR:+$GCC_DIR/bin/}aarch64-linux-android-"
      if [ -n "$GCC_DIR" ]; then
        [ -d "$GCC_DIR" ] || die "--gcc-dir 不存在：$GCC_DIR"
        export PATH="$GCC_DIR/bin:$PATH"
      fi
      MAKE_ARGS+=("CROSS_COMPILE=$pfx")
      say "  CROSS_COMPILE=$pfx"
      ;;
    clang)
      local pfx="${CROSS_COMPILE:-aarch64-linux-gnu-}"
      if [ -n "$CLANG_DIR" ]; then
        [ -d "$CLANG_DIR" ] || die "--clang-dir 不存在：$CLANG_DIR"
        export PATH="$CLANG_DIR/bin:$PATH"
      fi
      [ "$DRY_RUN" -eq 1 ] || command -v clang >/dev/null 2>&1 || die "PATH 里没有 clang"
      MAKE_ARGS+=("CC=clang" "CLANG_TRIPLE=${ARCH}-linux-gnu-" "CROSS_COMPILE=$pfx")
      say "  CC=clang CLANG_TRIPLE=${ARCH}-linux-gnu- CROSS_COMPILE=$pfx"
      ;;
    llvm)
      local pfx="${CROSS_COMPILE:-aarch64-linux-gnu-}"
      if [ -n "$CLANG_DIR" ]; then
        [ -d "$CLANG_DIR" ] || die "--clang-dir 不存在：$CLANG_DIR"
        export PATH="$CLANG_DIR/bin:$PATH"
      fi
      [ "$DRY_RUN" -eq 1 ] || command -v clang >/dev/null 2>&1 || die "PATH 里没有 clang"
      [ "$DRY_RUN" -eq 1 ] || command -v ld.lld >/dev/null 2>&1 || warn "PATH 里没有 ld.lld —— LLVM=1 需要它"
      MAKE_ARGS+=("LLVM=1" "LLVM_IAS=1" "CROSS_COMPILE=$pfx")
      say "  LLVM=1 LLVM_IAS=1 CROSS_COMPILE=$pfx"
      if [ -n "$THINLTO_CACHE" ]; then MAKE_ARGS+=("thinlto-cache-dir=$THINLTO_CACHE"); fi
      ;;
  esac
}

# ── KernelSU / paperSU 内置模式 ──────────────────────────────────────────────
# 已实测：小米三棵树（mondrian/rubens/socrates）根目录都有 drivers/，
# 所以 setup.sh 的 `GKI_ROOT/drivers` 分支能直接用。
# ⚠️ Kconfig: config KSU  depends on KPROBES && EXT4_FS —— 缺了会被静默关掉。
KSU_CONFIGS="CONFIG_KSU=y,CONFIG_KPROBES=y,CONFIG_EXT4_FS=y,CONFIG_KSU_MANUAL_SU=y"
setup_ksu() {
  [ -n "$KSU_SRC" ] || return 0
  [ -d "$KSU_SRC/kernel" ] || die "--ksu-src 里没有 kernel/ 目录：$KSU_SRC"
  [ -f "$KSU_SRC/kernel/setup.sh" ] || die "--ksu-src 里没有 kernel/setup.sh"
  step "集成 KernelSU / paperSU（内置模式）"
  say "  ln -sfn $KSU_SRC $KDIR/KernelSU"
  if [ "$DRY_RUN" -eq 0 ]; then
    ln -sfn "$KSU_SRC" "$KDIR/KernelSU"
    ( cd "$KDIR" && sh KernelSU/kernel/setup.sh ) || die "setup.sh 失败（drivers/ 存在吗？）"
  fi
  if [ -n "$KSU_SIZE2" ] && [ -z "$KSU_HASH2" ]; then
    die "--ksu-size2 与 --ksu-hash2 必须成对（Kbuild 里是硬报错）"
  fi
  if [ -n "$KSU_HASH2" ] && [ -z "$KSU_SIZE2" ]; then
    die "--ksu-size2 与 --ksu-hash2 必须成对"
  fi
  if [ -n "$KSU_PACKAGE" ]; then MAKE_ARGS+=("KSU_MANAGER_PACKAGE=$KSU_PACKAGE"); say "  KSU_MANAGER_PACKAGE=$KSU_PACKAGE"; fi
  if [ -n "$KSU_SIZE2" ];   then MAKE_ARGS+=("KSU_EXPECTED_SIZE2=$KSU_SIZE2");     say "  KSU_EXPECTED_SIZE2=$KSU_SIZE2"; fi
  if [ -n "$KSU_HASH2" ];   then MAKE_ARGS+=("KSU_EXPECTED_HASH2=$KSU_HASH2");     say "  KSU_EXPECTED_HASH2=$KSU_HASH2"; fi
  if [ -z "$KSU_PACKAGE" ] && [ -z "$KSU_HASH2" ]; then
    warn "没给 --ksu-package/--ksu-hash2：内核会带上游默认签名，paperSU 应用不会被认主。"
  fi
}

prepare_toolchain
setup_ksu
if [ -n "$EXTRA_MAKE" ]; then
  for kv in $(printf '%s' "$EXTRA_MAKE" | tr ',' ' '); do MAKE_ARGS+=("$kv"); done
fi

# ── 配置 ─────────────────────────────────────────────────────────────────────
set_config_lines() {
  local lines="$1" c name val
  [ -n "$lines" ] || return 0
  for c in $(printf '%s' "$lines" | tr ',' ' '); do
    name=${c%%=*}; val=${c#*=}
    [ "$name" = "$c" ] && val=y
    if [ -x "$SRCROOT/scripts/config" ]; then
      case "$val" in
        y) run "$SRCROOT/scripts/config" --file "$OUT/.config" --enable  "$name" >/dev/null;;
        n) run "$SRCROOT/scripts/config" --file "$OUT/.config" --disable "$name" >/dev/null;;
        m) run "$SRCROOT/scripts/config" --file "$OUT/.config" --module  "$name" >/dev/null;;
        *) run "$SRCROOT/scripts/config" --file "$OUT/.config" --set-str "$name" "$val" >/dev/null;;
      esac
      say "    配置 $c"
    else
      warn "没有 scripts/config，$c 未应用（请手动加进 defconfig）"
    fi
  done
}

step "配置内核"
run mkdir -p "$OUT"
if [ "$CONFIG_FROM_DEVICE" -eq 1 ]; then
  command -v adb >/dev/null 2>&1 || die "--config-from-device 需要 adb"
  say "  从设备抓 /proc/config.gz（需要已 root）"
  if [ "$DRY_RUN" -eq 0 ]; then
    adb shell 'su -c "cat /proc/config.gz"' | gzip -dc > "$OUT/.config" || die "抓配置失败"
  fi
else
  say "  defconfig: $DEFCONFIG"
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '  [dry-run] cd %s && make %s %s\n' "$KDIR" "${MAKE_ARGS[*]}" "$DEFCONFIG"
  else
    ( cd "$KDIR" && make "${MAKE_ARGS[@]}" "$DEFCONFIG" ) || die "defconfig 失败：$DEFCONFIG 存在吗？先跑 --list-defconfigs 看看"
  fi
fi
set_config_lines "$KSU_CONFIGS"
set_config_lines "$EXTRA_CONFIG"
if [ "$DRY_RUN" -eq 0 ]; then
  ( cd "$KDIR" && make "${MAKE_ARGS[@]}" olddefconfig ) || die "olddefconfig 失败"
  if [ -n "$KSU_SRC" ]; then
    if grep -q '^CONFIG_KSU=y' "$OUT/.config"; then
      say "  ✅ CONFIG_KSU=y 已生效"
    else
      die "CONFIG_KSU 没打开 —— 检查 CONFIG_KPROBES / CONFIG_EXT4_FS（KSU 依赖它们）"
    fi
  fi
fi

# ── 编译 ─────────────────────────────────────────────────────────────────────
if [ "$DO_CLEAN" -eq 1 ]; then
  step "make clean"
  run bash -c "cd '$KDIR' && make ${MAKE_ARGS[*]} clean"
fi
step "开始编译（$TARGET）"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  [dry-run] cd %s && make %s -j%s %s\n' "$KDIR" "${MAKE_ARGS[*]}" "$JOBS" "$TARGET"
else
  ( cd "$KDIR" && make "${MAKE_ARGS[@]}" -j"$JOBS" "$TARGET" ) \
    || die "编译失败。先看第一条 error；工具链错配（4.x 用 clang / 5.x 用 gcc）是最常见原因。"
fi

# ── 产物 ─────────────────────────────────────────────────────────────────────
step "产物"
BOOTDIR="$OUT/arch/$ARCH/boot"
IMAGES="zImage zImage-dtb Image Image.gz Image.gz-dtb Image.lz4 Image.bz2 Image.xz Image.fit"
found=""
if [ "$DRY_RUN" -eq 0 ]; then
  for i in $IMAGES; do
    if [ -f "$BOOTDIR/$i" ]; then
      printf '  %-16s %12s B\n' "$i" "$(wc -c < "$BOOTDIR/$i" | tr -d ' ')"
      if [ -z "$found" ]; then found="$BOOTDIR/$i"; fi
    fi
  done
  if [ -f "$BOOTDIR/dtb" ]; then printf '  %-16s %12s B\n' dtb "$(wc -c < "$BOOTDIR/dtb" | tr -d ' ')"; fi
  [ -n "$found" ] || die "在 $BOOTDIR 里没找到内核镜像 —— 目标名对吗？（试 --target Image 或 zImage）"
  say ""
  say "  主镜像: $found"
fi

# ── AnyKernel3 打包 ──────────────────────────────────────────────────────────
if [ "$AK3" -eq 1 ]; then
  step "打包 AnyKernel3"
  AK3_DIR="$OUT/AnyKernel3"
  if [ "$DRY_RUN" -eq 0 ]; then
    rm -rf "$AK3_DIR"
    git clone --quiet --depth 1 "$AK3_REPO" "$AK3_DIR" || die "克隆 AK3 模板失败：$AK3_REPO"
    rm -rf "$AK3_DIR/.git"
    # 小米机型不该顶着一加的内核横幅
    if [ -n "$AK3_STRING" ]; then
      sed -i "s|^kernel\.string=.*|kernel.string=$AK3_STRING|" "$AK3_DIR/anykernel.sh"
      say "  kernel.string → $AK3_STRING"
    fi
    # ⚠️ 纯内核包必须是 BLOCK=boot。若模板写的是 auto，Android 13+ GKI 上
    #    会优先命中 init_boot（那里只有 ramdisk、没有内核）⇒ 内核写进错分区。
    if grep -qE '^\s*BLOCK=auto' "$AK3_DIR/anykernel.sh"; then
      warn "AK3 模板里 BLOCK=auto —— 纯内核包会被写进 init_boot，已改为 boot"
      sed -i 's|^\(\s*\)BLOCK=auto|\1BLOCK=boot|' "$AK3_DIR/anykernel.sh"
    fi
    say "  BLOCK=$(grep -E '^\s*BLOCK=' "$AK3_DIR/anykernel.sh" | head -1 | cut -d= -f2-)"
    # 只留一个镜像，避免 AK3 按清单找到不该找的那个
    for i in $IMAGES dtb dtbo; do rm -f "$AK3_DIR/$i"; done
    cp -f "$found" "$AK3_DIR/$(basename "$found")"
    [ -f "$BOOTDIR/dtb" ] && cp -f "$BOOTDIR/dtb" "$AK3_DIR/dtb"
    NAME="paperSU-${KMI:-$KVER_FULL}-AnyKernel3"
    ZIP="$(dirname "$OUT")/$NAME.zip"
    rm -f "$ZIP"
    ( cd "$AK3_DIR" && zip -r9 "$ZIP" . -x '.git' '.gitignore' '*.zip' '*placeholder' >/dev/null ) || die "打包失败（需要 zip）"
    say "  ✅ $ZIP"
    say "     $(wc -c < "$ZIP" | tr -d ' ') B"
  fi
fi

step "完成"
say "  内核    : $KVER_FULL ($ARCH)  $LAYOUT"
say "  输出    : $OUT"
say ""
say "  刷写前提醒：这个内核只适用于这台设备的这个 ROM。刷前务必备份原 boot。"
