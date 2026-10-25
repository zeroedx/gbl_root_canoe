# GBL Root Canoe

[English](README.md)

`gbl_root_canoe` 是一个基于 EDK2 的工作区，用于修补高通 ABL (Android Bootloader) 内的 EFI 程序。它利用 GBL (Generic Bootloader Loader) 漏洞对 ABL 打补丁，主要目的是在骁龙 8 Gen 5 / 8 Elite (Gen 5) 设备上实现**假回锁**（绕过 Bootloader 的解锁状态检测）。修补后的 EFI 会被刷入 `efisp` 分区。

本项目提供两类构建产物：面向设备端使用的 **Magisk 模块**（`magisk_module.zip`），以及用于在 PC 上修补 `abl.img` 的 **Windows 工具包**（`toolkit_windows.zip`）。

---

## 开发者构建指南 (Builder Guide)

本节适用于希望从源码编译产物的开发者。

### 编译依赖
构建必须在 **Linux** 环境下进行：
- `gcc` / `clang`, `make`, `zip`, `python3`
- `liblzma-dev` (用于编译 `extractfv` 解包工具)
- **Android NDK**（用于 `make build_module` 交叉编译 Android 平台的修补工具）
- **MinGW-w64**（`x86_64-w64-mingw32-gcc`，用于 `make dist_loader_windows` 交叉编译）

### 核心构建目标

**注意**：在仅编译产物时，**不需要**事先提供 `abl.img`。通过 `DIST_NAME` 环境变量为发布压缩包命名（例如 `DIST_NAME=toolkit make dist_loader_windows`）。

- **`make dist_loader_windows`**
  使用 MinGW-w64 将修补工具（`extractfv`, `patch_abl`）交叉编译为 Windows 原生的 `.exe` 格式文件，并打包为 `release/$(DIST_NAME)_windows.zip`。

- **`make build_module`**
  使用 NDK 将修补工具交叉编译至 Android 原生平台架构，并封装为一个标准的 KernelSU/Magisk 模块。

- **`make patch`**
  开发辅助目标：对本地 `images/abl.img` 打补丁，结果输出到 `dist/` 供检查。

---

## 普通用户使用指南 (User Guide)

本节面向使用 `release/` 目录中已编译产物的普通用户。更详细的使用说明请参考 [Wiki](https://github.com/superturtlee/gbl_root_canoe/wiki)。

### 1. 使用模块版本（手机端）

模块可直接通过 Root 管理器在有 Root 权限的手机上刷入运行。

**设备要求：**
- 必须是骁龙 8 Gen 5 / 8 Elite (Gen 5) 芯片设备。
- 设备 BL 锁已经解锁。
- 内核**没有** Baseband Guard 拦截。

**刷入及使用流程：**
在使用 Root 管理器（KernelSU/Magisk/APatch）刷入该压缩包时，脚本会通过音量键与您交互：
- **按音量上键 (首次全新安装)：** 脚本会自动提取当前槽位的 `.abl`，对其打补丁，并把修补后的文件直接刷入 `/dev/block/by-name/efisp`。完成后，请重启手机进入 Recovery 模式**格式化 Data**。开机后，请再次刷入本模块（第二次刷入时按音量下键）以走完完整安装流程。
- **按音量下键 (非首次安装的日常 OTA 保留)：** 用于在 OTA 更新后保留 BL 版本。OTA 更新前使用模块自动降级 ABL，然后重启系统。

> **注意：** 本模块的 ID 为 `zeroedx_fake_bl_efisp`。若你之前安装过使用旧 ID 的同名模块，请先在 Root 管理器中手动卸载旧模块，再安装本模块，以免新旧模块同时运行并操作相同的分区或文件。Magisk/KernelSU 不会自动将旧 ID 的模块升级为本模块。

### 2. 使用 Windows 工具包

如果你下载的是 `toolkit_windows.zip`：
1. 请先解压该 zip 并进入套件文件夹。
2. 提取出你所用机型的官方 `abl.img`，并将其直接拷贝至套件中的 `images\` 目录下。
3. 双击运行 `build.bat`。
4. 脚本会提取并破解 ABL，输出 `ABL.efi`（假回锁）和 `ABL_original.efi`（原版，仅供分析）。请查看 `patch_log.txt`，若显示 "Warning: Failed to patch ABL GBL"，则该 ABL 没有漏洞，需将 `abl` 分区降级为带有 GBL 漏洞的旧版本 ABL。

随后将修补后的 `ABL.efi` 刷入 `efisp` 分区（例如 `fastboot flash efisp ABL.efi`），或使用上文所述的模块流程。

### 3. OTA 升级
重启进行 OTA 更新前，使用模块刷写以保留旧版本 ABL。跨版本升级时建议勾选“更新 efisp”，否则可能卡一屏。

### 4. 文件说明
1. `ABL.efi`：带假回锁的修补后 ABL。
2. `ABL_original.efi`：原始未破解 ABL，供开发者用 IDA 分析、报错使用，**不要刷入**。
