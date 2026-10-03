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

## 七、如实说明（没验证过的部分）

1. **工作流从未真正跑过** —— 我这里没有 GitHub runner。做的是：10 个 `run:` 块全部通过 `bash -n`；传给脚本的 14 个参数与脚本支持集逐一核对一致；YAML 缩进与制表符检查。
2. **YAML 没用真正的解析器验证** —— 环境里没有 PyYAML/js-yaml。push 后 Actions 页面会立刻告诉你。
3. **工具链下载 URL 没能验证** —— `android.googlesource.com` 从这台开发机**直连被墙**（实测返回 000）。GitHub runner 在美国通常可达；失败会明确报错停下。备用方案：`toolchain_source=url`。
4. **版本探测是在真实 Makefile 上验证的**（6 个分支，见上表），但**没有真正编译过任何一个小米内核**（没有 Linux 环境和完整工具链）。
5. 小米官方 OSS 仓库**每个内核树都是几百 MB 到 1 GB 以上**，工作流用 `--depth 1 --single-branch` 浅取，仍然会比较慢。

## 八、许可

本目录内的构建脚本由 paperSU 项目编写。`MiCode/Xiaomi_Kernel_OpenSource` 上的内核源码遵循各自的内核许可（GPLv2 等），分发编译产物时请遵守对应源码仓库的许可与署名要求。
