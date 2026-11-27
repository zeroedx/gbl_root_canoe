# GBL Root Canoe

`gbl_root_canoe` 是一个基于 EDK2 的工作区，用于修补高通 ABL (Android Bootloader) 内的 EFI 程序。它利用 GBL (Generic Bootloader Loader) 漏洞对 ABL 打补丁，主要目的是在骁龙 8 Gen 5 / 8 Elite (Gen 5) 设备上实现**假回锁**（绕过 Bootloader 的解锁状态检测）。修补后的 EFI 会被刷入 `efisp` 分区。

本项目提供一类构建产物：面向设备端使用的 **Magisk 模块**（`magisk_module.zip`）。
<img width="1080" height="1600" alt="98D7AB68DDCF6AB49B1BAEEBA0C9E094" src="https://github.com/user-attachments/assets/701bdd1b-7aa2-4d55-9388-cdd54c899025" />


###  使用模块版本

模块可直接通过 Root 管理器在有 Root 权限的手机上刷入运行。

**设备要求：**
- 必须是骁龙 8 Gen 5 / 8 Elite (Gen 5) 芯片设备。
- 设备 BL 锁已经解锁。
- 内核**没有** Baseband Guard 拦截。

**支持机型：**
模块通过设备代号（`ro.product.name`）识别机型。当前明确支持的设备标识为：`myron`、`pudding`、`popsicle`、`pandora`、`nezha`、`nezha_global`、`byron`、`songyuan`。模块为上述每个机型内置了带漏洞的 ABL；若本地内置固件缺失或未通过 SHA-256 校验，模块会回退到云端仓库获取，并以同样方式校验下载结果。未知设备不会被映射到其他机型，而是安全中止安装，不会触碰 `abl` 分区。


**安全机制。** 在刷写 `efisp` 之前，安装脚本会先把该分区备份到 `/data/adb/gbl_backup/<分区><槽位>_<时间>-<pid>.img`，并同时写入 `.meta` 元数据（机型代号、机型、槽位、来源、SHA-256、时间）与对应的 `.sha256` 文件。备份失败会中止安装，且备份不会被自动删除。`abl` 降级不再单独备份：降级本身已有写后回读校验，校验失败会在触碰 loader 之前中止，额外备份只会重复读取分区。每次写入之后都会按实际写入范围回读校验；校验不一致一律判定为失败，绝不报告成功。GBL 检测结果分为 Vulnerable、NotVulnerable、Unknown、Error 四种，检测失败绝不会被当作 Vulnerable。

**刷入及使用流程：**
在使用 Root 管理器（KernelSU/Magisk/APatch）刷入该压缩包时，脚本会通过音量键与您交互：
- **按音量上键 (首次全新安装)：** 脚本会自动提取当前槽位的 `.abl`，对其打补丁，并把修补后的文件直接刷入 `/dev/block/by-name/efisp`。完成后，请重启手机进入 Recovery 模式**格式化 Data**。开机后，请再次刷入本模块（第二次刷入时按音量下键）以走完完整安装流程。
- **按音量下键 (格式化后 / 非首次安装)：** 安装脚本只安装模块文件后即结束，**不会**读取、备份或刷写任何分区。格式化 Data 之后、或模块已经配置好只需重新安装时，选此项。它**不是** OTA 保留步骤。


### OTA 升级
OTA 保留操作在模块的 **WebUI**（“刷写到另一槽位” / `bin/bl_flasher.sh`）中完成，而不是安装时的音量键菜单。重启进行 OTA 更新前，请打开模块页面执行刷写，把当前槽位的 `abl` 写入另一槽位，从而保留旧版本 ABL。跨版本升级时建议勾选“更新 efisp”，否则可能卡一屏。

