# GBL Root Canoe

[English](README.md)

> ⚠️ **本项目已归档。** 当前版本为最终版本——补丁引擎已在多个厂商、多个 ABL 版本上稳定运行，核心逻辑不再变动，因此停止主动维护。代码仍然可用，欢迎 Fork。详见 [ARCHIVE.md](ARCHIVE.md)。

`gbl_root_canoe` 是一个基于 EDK2 的工作区，用于修补高通 ABL 内的 EFI 程序。它利用 GBL (Generic Bootloader Loader) 漏洞，把 ABL 修补成破解后的加载器，从而在骁龙 8 Gen 5 / 8 Elite (Gen 5) 设备上实现**假回锁**（绕过 Bootloader 的解锁状态检测）。

这里涉及两个**容易混淆**的不同位置：

- 原始的 **`efisp` 分区**（`/dev/block/by-name/efisp`）——一个裸块设备。
- `persist` 分区上的 **`efisp/` 目录**（ext4，系统自动挂载到 `/mnt/vendor/persist`）——一个文件系统目录，存放 `boot.efi`（破解后的 ABL）、`boot_backup.efi`、`BOOTENTRIES` 和 `tools/`。

> ⚠️ **本 Fork 移除了 superfastboot 集成。** 上游还会构建一个一级加载器——*superfastboot BDS*（`BDS.efi`，由 `uefi` 子模块构建）——并**裸刷到 `efisp` 分区**。该加载器是**唯一**读取 `persist` 的 `efisp/` 启动根目录与 `BOOTENTRIES`、并链式启动选中项的组件。本 Fork **不再构建、打包或刷入** BDS。破解后的 ABL 仍会生成，并且（在模块/工具链流程中）仍会被写入 `persist/efisp/boot.efi`，但**已没有任何随包组件会加载它**。设备自带的原生 fastboot（如小米）**并不已知**会读取 `BOOTENTRIES` 或加载 `persist/efisp/boot.efi`。在建立加载路径之前，请把 `persist` 的 `efisp/` 文件视为**已生成但缺少已知加载路径**。

---

## 开发者构建指南 (Builder Guide)

本节适用于希望从源码编译工具包的开发者。

### 编译依赖
构建各种发布包必须在 **Linux** 环境下进行：
- `gcc` / `clang`, `lld`, `make`, `zip`, `python3`
- `liblzma-dev` (用于编译 `extractfv` 解包工具)
- **Android NDK**（用于 `make target_magisk_module` 交叉编译 Android 平台的修补工具）
- **MinGW-w64**

### 核心构建目标

**注意**：在仅编译工具包或模块时，**不需要**事先提供 `abl.img`。

- **`make target_toolkit_linux`**
  从 `uefi` 子模块构建启动菜单工具（`RebootTools`, `BLTools`, `ArbTools`），并将修补工具（`extractfv`, `patch_abl`）编译为 Linux 原生程序。

- **`make target_toolkit_windows`**
  逻辑与 `target_toolkit_linux` 相同，但使用 MinGW-w64 将修补工具交叉编译为 Windows 原生的 `.exe` 格式文件。

- **`make target_magisk_module`**
  使用 NDK 将修补工具交叉编译至 Android 原生平台架构，构建工具，并封装为一个标准的 KernelSU/Magisk 模块。

- **`make target_toolkit_android`**
  构建独立的 Android arm64 工具包（`toolkit_android.zip`），包含 Android 原生二进制工具，可在设备上脱离模块独立使用。

---

## 普通用户使用指南 (User Guide)

更详细的使用说明请参考 [Wiki](https://github.com/superturtlee/gbl_root_canoe/wiki)。

### 1. 使用模块版本（手机端热修补）

模块可直接通过 Root 管理器在有 Root 权限的手机上刷入运行。

**设备要求：**
- 必须是骁龙 8 Gen 5 / 8 Elite (Gen 5) 芯片设备。
- 设备 BL 锁已经解锁。
- 内核**没有** Baseband Guard 拦截。
- `abl` 分区上的 ABL 必须包含 GBL 漏洞。若没有，请先刷写一个带有该漏洞的旧版本 ABL（破解后的 `boot.efi` 不必与 `abl` 分区上的 ABL 版本一致）。

**刷入及使用流程：**
在使用 Root 管理器（KernelSU/Magisk/APatch）刷入该压缩包时，脚本会通过音量键与您交互：
- **按音量上键 (首次全新安装)：** 脚本会提取当前槽位的 `.abl`，破解为 `boot.efi`，将 `boot.efi` 与 `BOOTENTRIES`（以及 `tools/`）放入 `/mnt/vendor/persist/efisp/`。完成后，请重启手机进入 Recovery 模式**格式化 Data**。开机后，请再次刷入本模块（第二次刷入时按音量下键）以走完完整安装流程。
- **按音量下键 (非首次安装的日常 OTA 保留)：** 安装 OTA 更新补丁。每次 OTA 后，打开模块 WebUI 重新刷写以保留 BL 版本。

> ⚠️ 移除 BDS 后，本 Fork 会布置 `persist` 的 `efisp/` 启动根目录，但不再安装任何会读取它的组件。本 Fork 目前**没有已知的加载路径**来加载破解后的 `boot.efi`。

### 2. 使用 PC 工具包 (Linux / Windows)

如果你下载的是 `target_toolkit_linux` 或 `target_toolkit_windows` 的发布压缩包：
1. 请先解压该 zip 并进入套件文件夹。
2. 提取出你所用机型的官方 `abl.img`，并将其直接拷贝至套件中的 `images/`（或 `images\`）目录下。
3. **Linux 平台：** 开启终端执行 `bash build.sh`。**Windows 平台：** 双击运行 `build.bat`。
4. 脚本会提取并破解 ABL，输出 `ABL.efi`（假回锁）和 `ABL_original.efi`（原版）。请查看 `patch_log.txt`，若显示 "Warning: Failed to patch ABL GBL"，则该 ABL 没有漏洞，需将 `abl` 分区降级为带有 GBL 漏洞的旧版本 ABL。

随后手动完成安装（完整步骤见 [Wiki](https://github.com/superturtlee/gbl_root_canoe/wiki)）：将 `ABL.efi` 复制到 `/mnt/vendor/persist/efisp/`（命名为 `boot.efi`），创建 `BOOTENTRIES`，`sync`。（如上所述，移除 BDS 后本 Fork 中没有任何组件会加载这些文件。）

### 3. OTA 升级
重启进行 OTA 更新前，使用模块 WebUI 刷写以保留旧版本 ABL。“更新 efisp”默认开启；跨版本升级时请保持开启，否则可能卡一屏。

### 4. 文件说明
1. `boot.efi` / `ABL.efi`：带假回锁的破解 ABL（模块中名为 `boot.efi`；toolkit 中名为 `ABL.efi`），写入 `persist` 分区的 `efisp/` 下。移除 BDS 后，本 Fork **没有已知组件会加载它**。
2. `BDS.efi`：上游的 superfastboot 一级加载器，裸刷到 `efisp` 分区。**本 Fork 已移除**——不再构建、打包或刷入。
3. `LinuxLoader.efi` / `ABL_original.efi`：提取出的、未破解的 ABL EFI。`extractfv` 先将其写为 `LinuxLoader.efi`，toolkit 随后改名为 `ABL_original.efi` 保留用于分析（不要刷入）——两者都不属于模块的最终产物；原始镜像即你的官方 `abl.img`，修补后的产物是 `boot.efi` / `ABL.efi`（见第 1 条）。
4. `BOOTENTRIES`：供 superfastboot BDS 使用的启动项列表（`<名称>:<相对 efisp/ 的路径>`）。其唯一消费者是 BDS；没有它时，本 Fork 中该文件没有读取方。
