# 小米 / 红米内核构建

用 `Build Kernel Xiaomi` 工作流（或本地 `scripts/build-kernel-generic.sh`）编译任意小米/红米机型的内核。

---

# 红米 K20 Pro（已适配，工作流默认值）

K20 Pro 是**当前默认目标** —— 进 Actions 直接点 Run 就是这个机型，不用改任何输入。

## 实测数据（读该分支真实 `Makefile` / `ls-tree` 得到）

| 分支 | 机型 | 内核 | 结构 | 配置 |
|---|---|---|---|---|
| **`raphael-p-oss`** | Redmi K20 Pro | **4.14.83** | 根目录（无 `common/`） | `arch/arm64/configs/raphael_user_defconfig` |
| `cepheus-q-oss` | Mi 9 / Redmi K20 Pro | **4.14.117** | 同上 | 同名（另一个官方分支，Android Q） |

官方表里 K20 Pro 有这两条；默认用 `raphael-p-oss`（Android P 基线，`LA.UM.7.1.r1-12100-sm8150.0`）。
要编 Android Q 版本就把 `device_branch` 改成 `cepheus-q-oss`。

## 为什么 K20 Pro 需要专门适配

它是 **4.14 非 GKI** 设备，三个关键点都和 GKI 机型不同：

| | K20 Pro（4.14） | K50/K60 那类（5.10+ GKI） |
|---|---|---|
| 工具链 | **GCC**（不能用 Clang） | Clang（`LLVM=1`） |
| make 目标 | **`Image.gz-dtb`**（复合镜像，dtb 已内含） | `Image` |
| 配置路径 | 顶层 `raphael_user_defconfig` | 顶层 `gki_defconfig` |

工作流为此做了三件事：

1. **探测内核版本**（`Detect kernel version` 步骤）→ 导出 `KVER_MAJOR`
2. **按版本切工具链** → `KVER_MAJOR == 4` 时走 `Setup GCC toolchain`，并**跳过**所有 Clang 步骤（省时间）
3. **GCC 来源有两级兜底**：
   - 优先取 **AOSP 的 `aarch64-linux-android-4.9`**（Android 4.14 内核的标准工具链，经 gitiles `+archive` 只取该目录）
   - 取不到就退回发行版 `aarch64-linux-gnu`（deps 步骤已装），并**明确告警**：发行版 GCC 版本较新，编 4.14 可能因新警告报错；真失败时在 `extra_make` 里填 `KCFLAGS=-Wno-error` 再试

`make` 目标不用管 —— 脚本从版本自动选（4.x → `Image.gz-dtb`）。

## 用 Actions 构建

仓库 → Actions → **`Build Kernel Xiaomi`** → Run workflow，默认值已经是：

```
device_branch = raphael-p-oss
defconfig     = raphael_user_defconfig
kmi           = redmi-k20pro
ksu_enable    = true（内置 paperSU，包名与签名已预填）
```

直接点运行即可。跑完在 Artifacts 里下 `paperSU-Xiaomi-raphael-p-oss-AnyKernel3.zip`。

**第一次跑建议先看日志里 `List available defconfigs` 那一步**，确认 `raphael_user_defconfig` 在列表里。

## 本地跑（Git Bash 也能先做规划）

```bash
# 只看它打算干什么 —— 应当显示 4.14.83 / gcc / Image.gz-dtb
./scripts/build-kernel-generic.sh --kernel-dir kernel-src \
  --defconfig raphael_user_defconfig --dry-run

# 真编译
./scripts/build-kernel-generic.sh --kernel-dir kernel-src \
  --defconfig raphael_user_defconfig \
  --gcc-dir ~/toolchain/gcc --cross-compile ~/toolchain/gcc/bin/aarch64-linux-android- \
  --ksu-src ~/PaperSU --ksu-package top.becuy.eric.papersu \
  --ksu-size2 0x036d --ksu-hash2 14ea1b98c9f693f282a05022b8cf02dcbd2dd8e28c9d6b97bd6acfda1352f82f \
  --ak3 --ak3-string "paperSU Kernel" --kmi redmi-k20pro
```

## K20 Pro 刷写注意

- K20 Pro 是**非 A/B** 设备，`BLOCK=boot` 直接对；`IS_SLOT_DEVICE=auto` 也不会找错。
- 刷前**务必备份原 boot**：TWRP → Backup → 勾 `Boot`，或管理器里的备份功能。
- 刷错进不去系统时：`fastboot flash boot <原厂 boot.img>`，K20 Pro 是 `boot` 分区（不是 `boot_a`）。
- **4.14 上跑 KernelSU 有不确定性**：paperSU 的内核代码来自 SukiSU/KernelSU 血统，主线主要面向 GKI 5.10+；4.14 是否能直接编过**我没能实际验证**（没有 Linux 环境与完整工具链）。如果 `setup.sh` 或内核代码在 4.14 上报错，那不是配置问题而是**代码层面的 4.14 兼容性**问题，需要额外 backport。工作流会在 `CONFIG_KSU=y` 没生效时明确报错，不会让你拿到一个"看起来成功"的包。

---

# 其余机型（通用）

## 为什么单独一个工作流

和 `Build Kernel OnePlus.yml` **不能合并**，源码模型根本不同：

| | 一加那套 | 小米这套 |
|---|---|---|
| 源码获取 | AOSP `repo` 工具 + OnePlusOSS 的 `kernel_manifest` 清单 | 官方仓库按机型分支直接 clone |
| 机型怎么选 | 选一个清单文件（`FILE`，如 `oneplus_ace2_pro_b`） | 选一个**分支**（如 `mondrian-s-oss`） |
| 源码位置 | `kernel_platform/common/` | **仓库根目录**（实测 6 个分支都是） |
| 厂商补丁 | 全程依赖 `vendor/oplus/*`（DROID_SPACES / RE_KERNEL / hmbird / midas） | 小米树上**没有这些东西** |
| 额外配置 | `CONFIG_OPLUS_*` | 无 |

所以一加那套的补丁与配置在小米内核里**根本不存在**，硬套只会失败。

## 一、先查这台机型有哪些配置

```bash
./scripts/build-kernel-generic.sh --kernel-dir kernel-src --list-defconfigs
```

**会递归列出**（这点很重要）：

- **新机型**（5.10/5.15，如 K50/K60）配置在 `arch/arm64/configs/` 顶层，通常有 `gki_defconfig`
- **老机型**（4.x 高通树）配置在 `arch/arm64/configs/vendor/` 下，要**带路径**传：
  `--defconfig vendor/alioth_user_defconfig`

实测分布：

| 分支 | 机型 | defconfig 总数 | 在 `vendor/` 下 |
|---|---|---|---|
| `mondrian-s-oss` | 红米 K60 | 5 | 0 |
| `rubens-s-oss` | 红米 K50 | 12 | 0 |
| `socrates-t-oss` | 红米 K60 Pro | 6 | 0 |
| `corot-t-oss` | 红米 K60 Ultra | 19 | 0 |
| `alioth-r-oss` | 红米 K40 | 25 | **17** |
| `sweet-r-oss` | 红米 Note 10 Pro | 36 | **31** |

## 二、机型分支名

来自官方对照表 —— [MiCode/Xiaomi_Kernel_OpenSource 的 `README` 分支](https://github.com/MiCode/Xiaomi_Kernel_OpenSource/tree/README)（266 个分支，带机型名与安卓版本）。

> ⚠️ **新机型的分支名带 `bsp-` 前缀**。写 `duchamp-u-oss` 会克隆失败，正确的是 `bsp-duchamp-u-oss`。这是最容易踩的坑。

常用对照（部分）：

| 分支 | 机型 |
|---|---|
| `sweet-r-oss` | 红米 Note 10 Pro |
| `alioth-r-oss` | 红米 K40 |
| `ares-r-oss` | 红米 K40 Gaming |
| `rubens-s-oss` | 红米 K50 |
| `mondrian-s-oss` | 红米 K60 |
| `socrates-t-oss` | 红米 K60 Pro |
| `corot-t-oss` | 红米 K60 Ultra |
| `bsp-duchamp-u-oss` | 红米 K70E |
| `bsp-manet-u-oss` | 红米 K70 Pro |
| `bsp-rothko-u-oss` | 红米 K70 Ultra |
| `bsp-vermeer-t-oss` | 红米 K70 |
| `bsp-zorn-v-oss` | 红米 K80 |
| `bsp-miro-v-oss` | 红米 K80 Pro |

## 三、工具链与目标是怎么定的

脚本从内核自己的 `Makefile` 读 `VERSION/PATCHLEVEL`，据此自动选 —— **不需要你判断**：

| 内核 | 工具链 | make 目标 |
|---|---|---|
| 4.x | GCC | `Image.gz-dtb` |
| 5.4 | Clang | `Image` |
| 5.10 / 5.15 | Clang（`LLVM=1`） | `Image` |
| 6.1–6.12 | Clang（`LLVM=1`） | `Image` |

**实测验证过的 6 个分支**：

| 分支 | 实测内核版本 | 自动选到 |
|---|---|---|
| `sweet-r-oss` | 4.14.180 | gcc / Image.gz-dtb |
| `alioth-r-oss` | 4.19.113 | gcc / Image.gz-dtb |
| `rubens-s-oss` | 5.10.66 | llvm / Image |
| `mondrian-s-oss` | 5.10.81 | llvm / Image |
| `socrates-t-oss` | 5.15.41 | llvm / Image |
| `corot-t-oss` | 5.15.78 | llvm / Image |

想覆盖就传 `--toolchain gcc|clang|llvm` 或 `--target`。

## 四、跑工作流

仓库 → Actions → **`Build Kernel Xiaomi`** → Run workflow：

| 输入 | 填什么 |
|---|---|
| `device_branch` | 机型分支，如 `mondrian-s-oss` |
| `defconfig` | 如 `gki_defconfig`（或 `vendor/xxx_defconfig`） |
| `kmi` | 只影响产物名，如 `redmi-k60` |
| `ksu_enable` | ✅（内置 paperSU） |
| `ksu_package` / `ksu_size2` / `ksu_hash2` | 已预填成 paperSU 的值 |
| `sublevel` | 想伪装内核等级就填，留空不改 |
| `toolchain_source` | `aosp`（默认） |

跑完在 Artifacts 里下载 `paperSU-Xiaomi-<branch>-AnyKernel3.zip`。

跑之前建议先看日志里 **`List available defconfigs`** 那一步的输出，确认配置名对得上。

## 五、本地跑

```bash
# 只看它打算干什么（Windows Git Bash 也能跑，不需要 make）
./scripts/build-kernel-generic.sh --kernel-dir kernel-src \
  --defconfig gki_defconfig --dry-run

# 真编译
./scripts/build-kernel-generic.sh --kernel-dir kernel-src \
  --defconfig gki_defconfig \
  --clang-dir ~/toolchain/clang \
  --ksu-src ~/PaperSU \
  --ksu-package top.becuy.eric.papersu \
  --ksu-size2 0x036d \
  --ksu-hash2 14ea1b98c9f693f282a05022b8cf02dcbd2dd8e28c9d6b97bd6acfda1352f82f \
  --ak3 --ak3-string "paperSU Kernel" --kmi redmi-k60
```

全部参数：`./scripts/build-kernel-generic.sh --help`

## 六、几个已经处理掉的坑

**① `--list-defconfigs` / `--dry-run` 不需要 `make`**
这两个是纯查看操作，Windows 的 Git Bash 没有 `make`。脚本已豁免，否则你第一步就卡住。

**② 老机型的配置在 `vendor/` 下**
所以是递归列出的；只列顶层会让 4.x 用户看到空列表。

**③ AK3 的 `BLOCK` 必须是 `boot`**
若 AK3 模板里写的是 `BLOCK=auto`，纯内核包在 Android 13+ 的 GKI 设备上会优先命中 `init_boot`（那里只有 ramdisk、没有内核）⇒ **内核写进错分区**。脚本会检测并自动改成 `boot` 并告警。
（你现在用的 `Numbersf/AnyKernel3` 本来就是 `BLOCK=boot`，没问题。）

**④ AK3 横幅**
`Numbersf/AnyKernel3` 里写的是 `kernel.string=OnePlus Kernel by Numbersf`，小米机型顶着这个不合适，所以有 `--ak3-string` 改写。

**⑤ `CONFIG_KSU` 依赖 `CONFIG_KPROBES && CONFIG_EXT4_FS`**
少了这两个会被 `olddefconfig` **静默关掉**，你会拿到「编译成功但没有 KSU」的内核。脚本会自动打开并**在 `olddefconfig` 后校验 `CONFIG_KSU=y` 真的生效**，没生效就报错。

**⑥ `KSU_EXPECTED_SIZE2` 与 `KSU_EXPECTED_HASH2` 必须成对**
Kbuild 里是硬报错（`$(error KSU_EXPECTED_HASH2 must be set when KSU_EXPECTED_SIZE2 is set)`），脚本提前拦下。

**⑦ 换了 keystore 必须重算签名并重编内核**，否则 paperSU 应用不会被认主。

**⑧ 4.x 高通树自带的 `scripts/gcc-wrapper.py` 是 Python 2 脚本 —— 会让整个编译失败**

这是**实际踩到过**的坑（红米 K20 Pro，4.14.83）：

```
Makefile:393  PYTHON = python
Makefile:398  CC = $(PYTHON) $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)   ← 无条件，没有开关
```

`scripts/gcc-wrapper.py` 的 shebang 是 `python2`，正文有 5 处 py2 的 `print` 语句。
现代系统只有 Python 3，于是 `CC` 整体不可用 → **所有编译器探测都失败**，最终表现为：

```
Cannot use CONFIG_CC_STACKPROTECTOR_STRONG: -fstack-protector-strong not supported by compiler
make[1]: *** [Makefile:1226: prepare-compiler-check] Error 1
```

**"编译器不支持 -fstack-protector-strong" 是假象** —— 真编译器没问题，坏的是那个 wrapper。第一次看到这条报错很容易误判成工具链错配、去换 GCC 版本，白费时间。

脚本会自动处理（`fix_py2_build_scripts`）：

1. 检测 `scripts/gcc-wrapper.py` 是否 py2（看 shebang）
2. 转成 Python 3 —— 注意**两处都要改**：
   - 5 处 `print` 语句加括号（`print x,` 的尾逗号语义是"不换行" → `print(x, end="")`）
   - `subprocess.Popen(..., stderr=subprocess.PIPE)` → 加 `universal_newlines=True`。
     **只改 print 不够**：py3 下 `proc.stderr` 是 `bytes`，而正则模式是 `str`，会 `TypeError`
3. 用**一次真实调用**验证转换有效（不是只做语法检查）
4. 万一验证不过 → 回退成 `CC=<工具链前缀>gcc` 直接覆盖，并告警（代价是 wrapper 的 warning-as-error 策略失效）

转换后**行为与原版一致**（实测）：编译器返回 7 → wrapper 返回 7；编译器吐出 warning → `error, forbidden warning` → 返回 1。

**⑨ AOSP 的老 GCC 4.9 是 32 位主机程序 —— 缺运行库时同样伪装成"编译器不支持"**

同一个 K20 Pro 构建里紧接着踩到的第二个坑。`gcc-wrapper.py` 修好之后，报错**看起来一模一样**：

```
Cannot use CONFIG_CC_STACKPROTECTOR_STRONG: -fstack-protector-strong not supported by compiler
```

但日志里多了真正的线索：

```
scripts/gcc-version.sh: line 32: printf: Is: invalid number
scripts/gcc-version.sh: line 32: printf: your: invalid number
scripts/gcc-version.sh: line 32: printf: PATH: invalid number
scripts/gcc-version.sh: line 32: printf: set: invalid number
scripts/gcc-version.sh: line 32: printf: correctly?: invalid number
```

那 5 个词正是 `gcc-wrapper.py` 的 **ENOENT 报错文案** —— 说明 wrapper 执行编译器时拿到 `ENOENT`，编译器**根本跑不起来**。

原因：AOSP 的 `prebuilts/gcc/**linux-x86**/aarch64/aarch64-linux-android-4.9`
（注意路径是 `linux-x86`，**不是** `linux-x86_64`）是 **32 位 x86 主机程序**。
只有 64 位运行库的系统上 `execve` 找不到 `/lib/ld-linux.so.2`，内核返回 ENOENT。

处理（两处）：

1. **装 32 位运行库**：`libc6-i386 lib32stdc++6 lib32z1 lib32gcc-s1`（逐个装，失败不致命）
2. **真正验证工具链能否运行**，不行就明确报错并退回发行版 GCC。这里还修掉了原来一个**掩盖失败的写法**：

   ```sh
   toolchain/gcc/bin/aarch64-linux-android-gcc --version | head -n1   # ❌
   ```
   管道的退出码是 `head` 的，**永远为 0** —— 工具链跑不起来也发现不了，错误被推到很后面而且换了面貌。现在改成把 `--version` 的退出码放进条件判断，失败时还会打印 `file` 与 `ldd` 便于定位。**并且不再假设归档解压出来就是 `bin/xxx`**，而是递归查找 gcc 本体并从真实路径反推前缀（实测就是踩了"直接去看 `bin/aarch64-linux-android-gcc` 结果文件不存在"这个坑）。

**⑩ 老内核 + 现代宿主工具链的两个编译阻断（与交叉编译器无关）**

K20 Pro 继续往前推时遇到的两条错误。注意：**它们出在 HOSTCC（宿主的 gcc）上，换交叉编译器、换 32/64 位工具链都躲不掉**：

```
security/selinux/include/classmap.h:247:2: error: #error New address family defined, please update secclass_map.
/usr/bin/ld: scripts/dtc/dtc-parser.tab.o: multiple definition of `yylloc'; scripts/dtc/dtc-lexer.lex.o: first defined here
```

**① `yylloc` 重复定义** —— GCC 10 起默认 `-fno-common`，而 `scripts/dtc/dtc-lexer.l:41` 与 bison 生成的 `dtc-parser.tab.c` 各有一个 `YYLTYPE yylloc;` 暂定定义，于是变成两个真定义。
修法：只给 dtc 的宿主编译加回 `-fcommon`（改 `scripts/dtc/Makefile` 里 `HOSTCFLAGS_DTC` 一行）。不动全局 `HOSTCFLAGS`，免得和 Makefile 里 `HOSTCFLAGS +=` 的追加语义打架。

**② `classmap.h` 的 `PF_MAX` 检查** —— `genheaders.c` 里 include 的是**宿主的** `<sys/socket.h>`（文件注释写着 "we really do want to use the kernel headers here"，但实际拿到的是 glibc 的定义），所以 `PF_MAX` 来自 glibc：Ubuntu 24.04 报 46，而 4.14 的表只到 `smc`(43) → 必然触发。**加 `-I` 内核头路径没用**，因为 `<sys/socket.h>` 是宿主头。
修法：把 4.14 之后引入、宿主已知多出来的两个族类 `AF_XDP`(44) 与 `AF_MCTP`(45) **追加**到表尾（与上游后续提交一致），阈值按 `PF_MAX = AF_MAX = 最后一个族 + 1` 的语义调到 46。

> **追加而不是插入**是关键：已有类的编号不变，因此设备上按 AOSP 4.14 classmap 生成的 sepolicy 仍然对得上号，多出来的两个类只是没人引用。`genheaders` 只用来为**本内核**生成 `flask.h`/`av_permissions.h`，缺少后续内核才有的族类对本内核没有影响。

实测验证：补丁后花括号 188/188 平衡、`bpf` 表项完好、重复执行不会重复插入、`--dry-run` 不改动文件。

**⑫ `-std=gnu89` vs C99 的 `for` 内声明**

实测（红米 K20 Pro，4.14.83）：

```
drivers/gpu/drm/msm/dp/dp_display.c:272:17: error: 'for' loop initial declarations are only allowed in C99 or C11 mode
drivers/gpu/drm/msm/dp/dp_display.c:1671:25: 同上
```

4.14 的顶层 `Makefile` 里 `KBUILD_CFLAGS` 全局是 **`-std=gnu89`**，而这棵树里有一批**较新的高通代码**用了 C99 写法 `for (int i = ...)`。**我全树扫过：18 个内核 `.c` 文件含这种写法**，分布在 `drivers/gpu/drm/msm`、`drivers/soc/qcom`、`fs`、`block` 等多处 —— 逐个文件修会反复卡住。

脚本一次性改顶层那一行：`-std=gnu89` → **`-std=gnu99 -fgnu89-inline`**。

三条关键细节（都实测过，不是想当然）：

1. **本树 Makefile 里没有 `KBUILD_CFLAGS += $(KCFLAGS)`** —— 所以 `make KCFLAGS=-std=gnu99` **完全无效**，必须改那一行本身。
2. **必须同时加 `-fgnu89-inline`**。C99 与 gnu89 的 `inline` 语义不同：gnu89 会为非 static 的 `inline` 函数生成外部定义，C99 不会。只改 `-std` 有产生 undefined reference 的风险；两个一起加既拿到 C99 语法，又保持链接行为不变。
3. **只改 `KBUILD_CFLAGS`，绝不碰 `HOSTCFLAGS`** —— 后者是给 `fixdep`/`kconfig`/`dtc` 等宿主程序的，改了会改变它们的语义。

实测验证：改完后 `Makefile:432`（KBUILD_CFLAGS）变为 `-std=gnu99 -fgnu89-inline`，而 `Makefile:367`（**HOSTCFLAGS**）**仍是 `-std=gnu89`**；整个 Makefile 与原件**只差 1 行**；重复执行不会重复修改。

**⑬ 切到 C99 后暴露的"隐式 int" —— 高通代码里漏写的返回类型**

改完 `⑫` 之后的下一个错误：

```
drivers/gpu/drm/msm/sde/sde_hw_catalog.h:1232:15: error: return type defaults to 'int' [-Werror=implicit-int]
```

那一行是：

```c
static inline sde_hw_intf_te_supported(const struct sde_mdss_cfg *sde_cfg)
```

**漏写了返回类型**（紧邻的同类函数写的是 `static inline bool ...`）。C89 下"隐式 int"合法所以一直没暴露，C99 下非法。

> ⚠️ **不要用 `-Wno-error=implicit-int` 关掉它。** `-Werror=implicit-int` 是**内核自己**加的（`Makefile:919`，`$(call cc-option,-Werror=implicit-int)`），是刻意的安全加固 —— 隐式 int 可能是真 bug（本该返回指针的函数被静默当成返回 int）。关掉它等于拆掉内核的防护。**正确做法是补上类型。**

补 `bool` 的依据：该函数全树只有一个调用方，且在布尔语境 `if (sde_hw_intf_te_supported(...))`；同文件功能相邻的 `sde_hw_sspp_multirect_enabled()` 也用 `bool`。

实测验证：改后该行变为 `static inline bool sde_hw_intf_te_supported(...)`，与原文件**只差 1 行**，且重复执行不会重复修改。

**⑪ `gcc-wrapper.py` 修好之后，它开始"正常工作"了 —— 而这就是下一个坑**

把 `gcc-wrapper.py` 转成 Python 3 之后，构建推进过 `init/`、`arch/arm64/crypto/` 等数百个目标文件，然后停在：

```
error, forbidden warning: kern_levels.h:5
error, forbidden warning: setup.c:231
make[2]: *** [scripts/Makefile.build:363: arch/arm64/kernel/setup.o] Error 1
```

`error, forbidden warning:` 就是这个 wrapper 输出的话 —— 它**本来的职责就是把任何 warning 变成 error**，而且它的 `allowed_warnings` 在本树里是**空集**。用内核当年的官方 GCC 时没问题；用**比内核新很多的 GCC**（例如发行版 GCC 13 编 4.14）时，新 GCC 报出一堆当年不存在的警告：

- `-Wformat` 更精确（`%lu` 收到 `unsigned int`）
- `-Warray-bounds` 增强（对老代码的经典误报）

于是构建被这些**非致命警告**打断。

> ⚠️ **`-Wno-error` 完全无效** —— wrapper **不检查 `-Werror`**，只要编译器输出里出现 `文件:行: warning:` 就删掉 .o 并退出 1。唯一的办法是**根本不经过它**。

修法：脚本新增 `--no-cc-wrapper`，直接把 `CC` 覆盖成真正的编译器（命令行 `CC=` 会覆盖 Makefile 里那行无条件赋值）。工作流在**退回发行版 GCC 时自动加上它**，因为那正是"用新 GCC 编老内核"的场景。用 AOSP 的年份对应 GCC 4.9 时**不加**，让 wrapper 照原样生效。

## 七、如实说明（没验证过的部分）

1. **工作流从未真正跑过** —— 我这里没有 GitHub runner。做的是：10 个 `run:` 块全部通过 `bash -n`；传给脚本的 14 个参数与脚本支持集逐一核对一致；YAML 缩进与制表符检查。
2. **YAML 没用真正的解析器验证** —— 环境里没有 PyYAML/js-yaml。push 后 Actions 页面会立刻告诉你。
3. **工具链下载 URL 没能验证** —— `android.googlesource.com` 从这台开发机**直连被墙**（实测返回 000）。GitHub runner 在美国通常可达；失败会明确报错停下。备用方案：`toolchain_source=url`。
4. **版本探测是在真实 Makefile 上验证的**（6 个分支，见上表），但**没有真正编译过任何一个小米内核**（没有 Linux 环境和完整工具链）。
5. 小米官方 OSS 仓库**每个内核树都是几百 MB 到 1 GB 以上**，工作流用 `--depth 1 --single-branch` 浅取，仍然会比较慢。

## 八、许可

本目录内的构建脚本由 paperSU 项目编写。`MiCode/Xiaomi_Kernel_OpenSource` 上的内核源码遵循各自的内核许可（GPLv2 等），分发编译产物时请遵守对应源码仓库的许可与署名要求。
