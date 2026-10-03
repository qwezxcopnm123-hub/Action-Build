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
#   --ak3-string <text>      改写 AK3 的 kernel.string（默认一加文案，小米应改）
#   --no-cc-wrapper          不使用内核自带的 scripts/gcc-wrapper.py
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
DO_CLEAN=0 ; DRY_RUN=0 ; CONFIG_FROM_DEVICE=0 ; LIST_DEFCONFIGS=0 ; NO_CC_WRAPPER=0

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
    --no-cc-wrapper) NO_CC_WRAPPER=1; shift;;
    --clean) DO_CLEAN=1; shift;;
    --dry-run) DRY_RUN=1; shift;;
    -h|--help) sed -n '2,86p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *)
      # 帮助排查"值被按空格切开"这类调用方问题：如果传进来的东西像某个
      # 含空格值的后半截（例如 --ak3-string "paperSU Kernel" 没加引号，
      # 这里就会收到孤零零的 "Kernel"），下面这句能让人立刻反应过来。
      die "未知参数：$1
     提示：如果某个值里含空格，调用方必须加引号或改用数组，例如
       $0 --ak3-string \"paperSU Kernel\"
     不加引号会被按空格切成多个参数，于是这里收到的是碎片。
     完整用法见 --help。";;
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
      RESOLVED_CC_PREFIX="$pfx"
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

# 注意：这两个必须在 prepare_toolchain **之前**初始化 ——
# prepare_toolchain 会给 RESOLVED_CC_PREFIX 赋值（GCC 分支），
# 初始化写在它后面会把那个值清掉，CC 兜底就失效了。
CC_OVERRIDE=0
RESOLVED_CC_PREFIX=""

prepare_toolchain

# ── 老内核自带的 Python 2 构建脚本 ────────────────────────────────────────────
# 实测复现（红米 K20 Pro，raphael-p-oss，4.14.83 高通树）：
#   Makefile:393  PYTHON = python
#   Makefile:398  CC = $(PYTHON) $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)
# 这一行是**无条件**的，没有配置开关；而 gcc-wrapper.py 是 Python 2 脚本
# （shebang 是 python2，正文有 6 处 py2 的 print 语句）。
# 系统只有 Python 3 时 CC 整体不可用 → 所有编译器探测都失败，最终表现为：
#   Cannot use CONFIG_CC_STACKPROTECTOR_STRONG: -fstack-protector-strong
#   not supported by compiler
#   make[1]: *** [Makefile:1226: prepare-compiler-check] Error 1
# "编译器不支持"是**假象** —— 真编译器没问题，坏的是那个 wrapper。
#
# 处理：转成 Python 3（保留它原本 warning-as-error 的语义），并用**一次真实调用**
# 验证转换有效；万一验证不过，就退回"用 CROSS_COMPILE gcc 直接覆盖 CC"。
fix_py2_build_scripts() {
  local w="$SRCROOT/scripts/gcc-wrapper.py" py=""
  [ -f "$w" ] || return 0
  head -n1 "$w" | grep -q python2 || return 0

  # 内核 Makefile 里写的是 `PYTHON = python`，所以 python3 与 python 都要试。
  # 两个都没有 → wrapper 无论如何都跑不起来，直接走 CC 覆盖这条兜底。
  if command -v python3 >/dev/null 2>&1; then py=python3
  elif command -v python >/dev/null 2>&1; then py=python
  else
    warn "系统里既没有 python3 也没有 python —— gcc-wrapper.py 无法运行，改为覆盖 CC"
    CC_OVERRIDE=1
    return 0
  fi

  if "$py" -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$w" 2>/dev/null; then
    say "  scripts/gcc-wrapper.py 已能正常运行，无需处理"
    return 0
  fi
  step "修正 Python 2 构建脚本"
  say "  发现 Python 2 脚本：scripts/gcc-wrapper.py（用 $py 处理）"
  say "  （4.14/4.19 高通树的 CC 无条件指向它；没有 Python 2 时编译器探测会全失败）"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  [dry-run] 跳过实际改写"
    return 0
  fi
  cp -f "$w" "$w.py2bak"
  # py2 的 `print x,`（尾逗号）语义是"不换行"，要单独处理并放在前面
  sed -i -E 's/^([[:space:]]*)print (.*),$/\1print(\2, end="")/' "$w"
  sed -i -E 's/^([[:space:]]*)print (.*)$/\1print(\2)/' "$w"
  # py3 下子进程的 stderr 是 bytes，而 warning_re 是 str 模式 → 会 TypeError，
  # 所以必须让它以文本模式读取（这一步和 print 一样是必需的）
  sed -i 's/subprocess\.PIPE)/subprocess.PIPE, universal_newlines=True)/' "$w"
  # 真实调用一次验证：用往 stderr 写字的命令，能覆盖到 print 那条路径
  if "$py" "$w" /bin/sh -c 'echo wrapper-ok >&2' >/dev/null 2>&1; then
    say "  ✅ 已转换为 Python 3，并通过实际调用验证"
  else
    warn "转换后验证失败 → 退回直接覆盖 CC（不再使用该 wrapper）"
    cp -f "$w.py2bak" "$w"
    CC_OVERRIDE=1
  fi
}

# ── 老内核 + 现代宿主工具链的兼容修正 ────────────────────────────────────────
# 实测复现（红米 K20 Pro，4.14.83）：
#   security/selinux/include/classmap.h:247:2: error:
#       #error New address family defined, please update secclass_map.
#   /usr/bin/ld: scripts/dtc/dtc-parser.tab.o: multiple definition of `yylloc';
#                scripts/dtc/dtc-lexer.lex.o: first defined here
#
# ⚠️ 这两条与交叉编译器**无关** —— 出问题的是 HOSTCC（宿主的 gcc），
#    所以换 GCC/Clang 版本、换 32 位/64 位工具链都躲不掉，必须单独修。
#
# ① dtc 的 yylloc 重复定义
#    GCC 10 起默认 -fno-common。而 scripts/dtc/dtc-lexer.l 与 bison 生成的
#    dtc-parser.tab.c 各自有一个 `YYLTYPE yylloc;` 暂定定义；在 -fno-common 下
#    它们变成两个真正的定义，链接时报 multiple definition。
#    修法：只给 dtc 的宿主编译加回 -fcommon（改 scripts/dtc/Makefile 一行，最外科，
#    不去动全局 HOSTCFLAGS，免得和 Makefile 里 HOSTCFLAGS += 的追加语义打架）。
#
# ② selinux classmap.h 的 PF_MAX 检查
#    scripts/selinux/genheaders/genheaders.c 里 include 的是**宿主的**
#    <sys/socket.h>（注释还写着 "we really do want to use the kernel headers here"，
#    但实际拿到的是 glibc 的定义），所以 PF_MAX 来自 glibc。
#    Ubuntu 24.04 的 glibc 报 PF_MAX=46，而 4.14 的表只到 smc(43) → 触发 #error。
#    加 -I 内核头路径没有用，因为 <sys/socket.h> 是宿主头。
#    修法：把 4.14 之后才引入、宿主已知多出来的两个族类 **追加** 到表尾
#    （AF_XDP=44、AF_MCTP=45，与上游后续提交一致）。
#    **追加而不是插入**是关键：已有类的编号不变，因此设备上按 AOSP 4.14
#    classmap 生成的 sepolicy 仍然对得上号；多出来的两个类只是没人引用。
#    genheaders 只用来为**本内核**生成 flask.h/av_permissions.h，
#    缺少后续内核才有的族类对本内核没有任何影响。
#    同时把阈值按 AF_MAX=last+1 的语义调到 46，并把这句 #error 降级为说明。
fix_old_kernel_host_issues() {
  local dm="$SRCROOT/scripts/dtc/Makefile"
  local cm="$SRCROOT/security/selinux/include/classmap.h"
  local did=0

  # ① dtc -fcommon
  if [ -f "$dm" ] && ! grep -q -- '-fcommon' "$dm"; then
    if grep -q '^HOSTCFLAGS_DTC := ' "$dm"; then
      if [ "$DRY_RUN" -eq 1 ]; then
        say "  [dry-run] 会给 scripts/dtc/Makefile 的 HOSTCFLAGS_DTC 加 -fcommon"
      else
        sed -i 's|^HOSTCFLAGS_DTC := |HOSTCFLAGS_DTC := -fcommon |' "$dm"
        grep -q -- '-fcommon' "$dm" \
          && say "  ✅ scripts/dtc/Makefile 已加 -fcommon（修 yylloc 重复定义）" \
          || warn "  给 scripts/dtc/Makefile 加 -fcommon 失败"
      fi
      did=1
    fi
  fi

  # ② classmap.h
  if [ -f "$cm" ] && ! grep -q 'mctp_socket' "$cm"; then
    if grep -q '#if PF_MAX > 44' "$cm"; then
      if [ "$DRY_RUN" -eq 1 ]; then
        say "  [dry-run] 会给 classmap.h 追加 xdp_socket/mctp_socket 并调整 PF_MAX 阈值"
      else
        # 在 bpf 表项之后、{ NULL } 之前插入两个族类（追加，不动已有编号）
        awk '
          /prog_run/ { sawbpf = 1 }
          sawbpf == 1 && !done && /^[[:space:]]*\{ NULL \}[[:space:]]*$/ {
            print "\t{ \"xdp_socket\","
            print "\t  { COMMON_SOCK_PERMS, NULL } },"
            print "\t{ \"mctp_socket\","
            print "\t  { COMMON_SOCK_PERMS, NULL } },"
            done = 1
          }
          { print }
        ' "$cm" > "$cm.new" && mv "$cm.new" "$cm"
        # 阈值：glibc 的 PF_MAX = AF_MAX = 最后一个族 + 1
        sed -i 's|^#if PF_MAX > 44$|#if PF_MAX > 46|' "$cm"
        if grep -q 'mctp_socket' "$cm" && grep -q 'PF_MAX > 46' "$cm"; then
          say "  ✅ classmap.h 已补 xdp_socket/mctp_socket 并通过 PF_MAX 检查"
        else
          warn "  classmap.h 修补结果不符合预期，请人工检查"
        fi
      fi
      did=1
    fi
  fi

  if [ "$did" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    say "  （这两处是宿主工具链导致的老内核兼容问题，与交叉编译器无关）"
  fi
}

# ── C99 的 for 内声明 vs 全局 -std=gnu89 ──────────────────────────────────────
# 实测（红米 K20 Pro，4.14.83 高通树）编译到：
#   drivers/gpu/drm/msm/dp/dp_display.c:272:17: error: 'for' loop initial
#   declarations are only allowed in C99 or C11 mode
#   drivers/gpu/drm/msm/dp/dp_display.c:1671:25: 同上
# 原因：顶层 Makefile 的 KBUILD_CFLAGS 里全局是 `-std=gnu89`（4.14 时代的标准），
# 而这棵树里有一批**较新的高通代码**用了 C99 写法 `for (int i = ...)`。
# 我全树扫过：18 个内核 .c 文件含这种写法，分布在
#   drivers/gpu/drm/msm（2 个）、drivers/soc/qcom、fs、block 等多处。
# 逐个文件修会反复卡住，所以一次性处理这一**类**问题。
#
# ⚠️ 两条关键细节（都验证过，不是想当然）：
#  1) 本树 Makefile 里**没有** `KBUILD_CFLAGS += $(KCFLAGS)`
#     —— 所以 `make KCFLAGS=-std=gnu99` 是无效的，必须改那一行本身。
#  2) 必须**同时**加 `-fgnu89-inline`。C99 与 gnu89 的 inline 语义不同：
#     gnu89 会为非 static 的 inline 函数生成外部定义，C99 不会。
#     只把 -std 改成 gnu99 有产生 undefined reference 的风险；
#     两个一起加，既拿到 C99 的语法（for 内声明），
#     又保持 gnu89 的链接行为不变。
#  3) 只改 KBUILD_CFLAGS 那处，**绝不动 HOSTCFLAGS**（那是给 fixdep/kconfig/dtc
#     等宿主程序用的，改了会改变它们的语义）。
fix_c99_language_mode() {
  local mk="$SRCROOT/Makefile"
  [ -f "$mk" ] || return 0
  grep -q -- '-std=gnu89' "$mk" || return 0
  grep -q -- '-std=gnu99' "$mk" && return 0

  step "语言模式：-std=gnu89 → -std=gnu99 -fgnu89-inline"
  say "  这棵树里有 C99 的 for 内声明，而全局是 gnu89 → 编译必然中断"
  say "  同时加 -fgnu89-inline 以保持原本的 inline 链接语义"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  [dry-run] 会改顶层 Makefile 里 KBUILD_CFLAGS 的那处 -std"
    return 0
  fi
  cp -f "$mk" "$mk.orig-papersu"
  # 只在 KBUILD_CFLAGS 那个续行块内部替换；HOSTCFLAGS 那处不受影响。
  awk '
    /^KBUILD_CFLAGS[ \t]*:=/ { blk = 1 }
    blk && /-std=gnu89/ { sub(/-std=gnu89/, "-std=gnu99 -fgnu89-inline"); n++ }
    blk && $0 !~ /\\$/ { blk = 0 }
    { print }
    END { exit (n > 0) ? 0 : 1 }
  ' "$mk" > "$mk.new-papersu"
  if [ $? -eq 0 ] && grep -q -- '-std=gnu99 -fgnu89-inline' "$mk.new-papersu"; then
    mv -f "$mk.new-papersu" "$mk"
    say "  ✅ 已改（HOSTCFLAGS 保持 -std=gnu89 不变）"
    say "     $(grep -n -- '-std=gnu99 -fgnu89-inline' "$mk" | head -n1 | tr -d '\n')"
  else
    rm -f "$mk.new-papersu"
    cp -f "$mk.orig-papersu" "$mk"
    warn "顶层 Makefile 改写失败，保持原样"
  fi
}

# ── 漏写返回类型（隐式 int）──────────────────────────────────────────────────
# 实测（切到 C99 后立即暴露的下一个错误）：
#   drivers/gpu/drm/msm/sde/sde_hw_catalog.h:1232:15: error:
#     return type defaults to 'int' [-Werror=implicit-int]
# 那一行是：
#   static inline sde_hw_intf_te_supported(const struct sde_mdss_cfg *sde_cfg)
# **漏写了返回类型**。紧邻的同类函数写的是 `static inline bool ...`。
# 在 C89 下"隐式 int"是合法的（所以一直没暴露），C99 下非法。
#
# ⚠️ 为什么不直接用 -Wno-error=implicit-int 关掉：
#    `-Werror=implicit-int` 是**内核自己**加的（Makefile:919
#     KBUILD_CFLAGS += $(call cc-option,-Werror=implicit-int)），
#    是刻意的安全加固 —— 隐式 int 可能是真 bug（例如本该返回指针的函数
#    被静默当成返回 int）。关掉它等于拆掉内核的防护。
#    所以正确做法是**补上类型**。
#
# 为什么补 bool：该函数全树只有一个调用方，且是布尔语境
#   if (sde_hw_intf_te_supported(phys_enc->sde_kms->catalog))
#   同文件里功能相邻的 sde_hw_sspp_multirect_enabled() 也用 bool ⇒ 符合原意。
#
# 我全树扫过这个模式：真正漏写类型的位置在 arm64 本机构建路径上只有这一处
# （其余真命中在 arch/powerpc、arch/sparc 等不会编译的目录）。
fix_implicit_int_returns() {
  local f="$SRCROOT/drivers/gpu/drm/msm/sde/sde_hw_catalog.h"
  [ -f "$f" ] || return 0
  grep -qE 'static[[:space:]]+inline[[:space:]]+sde_hw_intf_te_supported[[:space:]]*\(' "$f" || return 0

  step "补上漏写的返回类型（隐式 int）"
  say "  sde_hw_catalog.h: sde_hw_intf_te_supported() 没有返回类型"
  say "  （C89 下隐式 int 合法、C99 下非法；内核自己开了 -Werror=implicit-int）"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  [dry-run] 会补成 static inline bool ..."
    return 0
  fi
  cp -f "$f" "$f.orig-papersu"
  sed -i -E 's/static([[:space:]]+)inline([[:space:]]+)sde_hw_intf_te_supported[[:space:]]*\(/static\1inline\2bool sde_hw_intf_te_supported(/' "$f"
  if grep -qE 'static[[:space:]]+inline[[:space:]]+bool[[:space:]]+sde_hw_intf_te_supported[[:space:]]*\(' "$f"; then
    say "  ✅ 已补 bool"
  else
    warn "补类型失败，已回滚"
    cp -f "$f.orig-papersu" "$f"
  fi
}

# ── KernelSU 里"新内核才有的东西"在 4.14 上的兼容 ────────────────────────────
# 实测（4.14.83 + SukiSU）：
#   drivers/kernelsu/core/init.c:249:1: error: type defaults to 'int'
#   in declaration of 'MODULE_IMPORT_NS' [-Werror=implicit-int]
#
# 原因：KSU 源码里是这么写的（main 的 core/init.c 与 old 的 ksu.c 都一样）：
#     #if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 13, 0)
#     MODULE_IMPORT_NS("VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver");
#     #else
#     MODULE_IMPORT_NS(VFS_internal_I_am_really_a_filesystem_and_am_NOT_a_driver);
#     #endif
# 而 `MODULE_IMPORT_NS` 是 **5.4+** 才引入的宏，4.14 里不存在 →
# 被当成"隐式 int 的声明"→ 撞上内核自己的 -Werror=implicit-int。
#
# 正确修法**不是补一个空宏**，而是把 `#else` 收紧成 `#elif >= 5.4`：
# 5.4 以下的模块系统根本没有 namespace 的概念，这行**本来就应该是空的**。
# 这样语义最准确，也不需要伪造内核 API。
#
# 该修法对 main 与 old 两个分支都适用（两者的写法相同）。
fix_ksu_old_kernel_compat() {
  [ -n "$KSU_SRC" ] && [ -d "$KSU_SRC" ] || return 0
  # 只在老内核上才需要（MODULE_IMPORT_NS 自 5.4 起存在）
  if [ "$V" -gt 5 ] || { [ "$V" -eq 5 ] && [ "$P" -ge 4 ]; }; then
    return 0
  fi
  local files
  files=$(grep -rl 'MODULE_IMPORT_NS' "$KSU_SRC" --include='*.c' --include='*.h' 2>/dev/null || true)
  [ -n "$files" ] || return 0

  step "KernelSU 兼容：MODULE_IMPORT_NS（5.4+ 才有）"
  say "  内核 $V.$P < 5.4，而 KSU 源码在 <6.13 时会无条件使用 MODULE_IMPORT_NS"
  if [ "$DRY_RUN" -eq 1 ]; then
    say "  [dry-run] 会把受影响的 #else 收紧为 #elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)"
    return 0
  fi
  local f n=0
  for f in $files; do
    # 仅当某行的 #else 紧跟着一行 MODULE_IMPORT_NS 时才改这一处；
    # 用 awk 做跨行判断，避免误改其它 #else。
    if awk '
      { l[NR] = $0 }
      END {
        hit = 0
        for (i = 1; i <= NR; i++) {
          if (l[i] ~ /^[[:space:]]*#else[[:space:]]*$/ && l[i+1] ~ /MODULE_IMPORT_NS/) {
            l[i] = "#elif LINUX_VERSION_CODE >= KERNEL_VERSION(5, 4, 0)"
            hit = 1
          }
        }
        for (i = 1; i <= NR; i++) print l[i]
        exit (hit ? 0 : 1)
      }
    ' "$f" > "$f.papersu-new"; then
      mv -f "$f.papersu-new" "$f"
      n=$((n + 1))
      say "  ✅ $f"
    else
      rm -f "$f.papersu-new"
    fi
  done
  if [ "$n" -gt 0 ]; then
    say "  共收紧 $n 个文件（4.14 的模块系统没有 namespace，这行本就该是空的）"
  else
    warn "  没找到需要收紧的 #else（写法可能不同），保持原样"
  fi
}

setup_ksu
fix_py2_build_scripts
# 4.x 老内核才需要：修宿主工具链导致的两个编译阻断
case "$V" in 4|5) fix_old_kernel_host_issues; fix_c99_language_mode; fix_implicit_int_returns;; esac
# 不限版本：KSU 用了新内核才有的符号时要兜住
fix_ksu_old_kernel_compat

# ── 是否绕过内核自带的 gcc-wrapper.py ────────────────────────────────────────
# 这个 wrapper 的职责就是把**任何** warning 变成 error 并删掉 .o（它的
# allowed_warnings 在本树里是空集）。用内核当年的官方 GCC 时它没问题，
# 但用比内核新很多的 GCC（例如发行版 GCC 13 编 4.14）时，新版本 GCC 会报出
# 一堆当年不存在的警告（-Wformat 更精确、-Warray-bounds 增强……），
# 于是构建必然被这些警告打断：
#   error, forbidden warning: kern_levels.h:5
#   error, forbidden warning: setup.c:231
#   make[2]: *** [scripts/Makefile.build:363: arch/arm64/kernel/setup.o] Error 1
# ⚠️ 注意 -Wno-error **没有用**：wrapper 不检查 -Werror，只要输出里出现
#    "文件:行: warning:" 就退出 1。唯一的办法是根本不经过它。
# 用 --no-cc-wrapper 时我们直接把 CC 覆盖成真正的编译器。
if [ "$NO_CC_WRAPPER" -eq 1 ] && [ -f "$SRCROOT/scripts/gcc-wrapper.py" ]; then
  CC_OVERRIDE=1
  say ""
  say "  --no-cc-wrapper：本树带 scripts/gcc-wrapper.py，已跳过它"
fi

if [ "$CC_OVERRIDE" -eq 1 ]; then
  MAKE_ARGS+=("CC=${RESOLVED_CC_PREFIX}gcc")
  warn "已用 CC=${RESOLVED_CC_PREFIX}gcc 覆盖 —— 不再经过 gcc-wrapper.py"
  warn "（该 wrapper 会把任何 warning 变成 error；用比内核新很多的 GCC 时必然失败）"
fi
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
kdf() { df -h "$OUT" 2>/dev/null | awk 'NR==2{print $4" 可用 / "$2" 总"}'; }
say "  磁盘（构建卷 $OUT）：$(kdf)"
BUILD_LOG="$OUT/build.log"
if [ "$DRY_RUN" -eq 1 ]; then
  printf '  [dry-run] cd %s && make %s -j%s %s\n' "$KDIR" "${MAKE_ARGS[*]}" "$JOBS" "$TARGET"
else
  # 把 make 的输出同时写进日志文件。
  # 为什么要这样：老内核 + 新 GCC 会产生**成千上万条非致命警告**
  # （-Wmaybe-uninitialized / -Warray-bounds / -Waddress-of-packed-member /
  #  以及几百个参考板 dtb 的 DTC 警告）。CI 日志会被 GitHub 截断，
  # 真正的 error 埋在几万行警告之后，根本翻不到。
  # 这里在失败时**主动把 error 抓出来**打印，并把完整日志留成 artifact。
  : > "$BUILD_LOG"
  set +e
  ( cd "$KDIR" && make "${MAKE_ARGS[@]}" -j"$JOBS" "$TARGET" ) 2>&1 | tee -a "$BUILD_LOG"
  rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    printf '\n===================== 编译失败 =====================\n' >&2
    printf '退出码：%s\n' "$rc" >&2
    printf '\n----- 错误行（最多 15 条，来自 %s）-----\n' "$BUILD_LOG" >&2
    grep -n -E '(^|[[:space:]])(fatal )?error:|Error [0-9]+|No space left on device|Killed|undefined reference' \
      "$BUILD_LOG" | head -n 15 >&2 || true
    printf '\n----- 日志最后 25 行 -----\n' >&2
    tail -n 25 "$BUILD_LOG" >&2 || true
    printf '\n----- 磁盘（构建卷，即真正在写的地方）-----\n' >&2
    df -h "$OUT" >&2 || true
    printf -- '----- 磁盘（根分区，仅供对比）-----\n' >&2
    df -h / >&2 || true
    printf -- '----- 内存与交换 -----\n' >&2
    free -h >&2 || true
    printf '===================================================\n' >&2
    die "编译失败（上面已摘出错误行；完整日志见 $BUILD_LOG，CI 里会作为 artifact 上传）"
  fi
  say "  编译输出日志：$BUILD_LOG（$(wc -l < "$BUILD_LOG" | tr -d ' ') 行）"
  say "  磁盘（编译后，构建卷）：$(kdf)"
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
