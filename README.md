# GBL Root Canoe

`gbl_root_canoe` 是一个基于 EDK2 的工作区，用于修补高通 ABL (Android Bootloader) 内的 EFI 程序。它利用 GBL (Generic Bootloader Loader) 漏洞对 ABL 打补丁，主要目的是在骁龙 8 Gen 5 / 8 Elite (Gen 5) 设备上实现**假回锁**（绕过 Bootloader 的解锁状态检测）。修补后的 EFI 会被刷入 `efisp` 分区。

<img width="1080" height="1600" alt="98D7AB68DDCF6AB49B1BAEEBA0C9E094" src="https://github.com/user-attachments/assets/701bdd1b-7aa2-4d55-9388-cdd54c899025" />

**刷入及使用流程：**
在使用 Root 管理器（KernelSU/Magisk/APatch）刷入该压缩包时，脚本会通过音量键与您交互：
- **按音量上键 (首次全新安装)：** 脚本会自动提取当前槽位的 `.abl`，对其打补丁，并把修补后的文件直接刷入 `/dev/block/by-name/efisp`。完成后，请重启手机进入 Recovery 模式**格式化 Data**。开机后，请再次刷入本模块（第二次刷入时按音量下键）以走完完整安装流程。
- **按音量下键 (格式化后 / 非首次安装)：** 安装脚本只安装模块文件后即结束，**不会**读取、备份或刷写任何分区。格式化 Data 之后、或模块已经配置好只需重新安装时，选此项。它**不是** OTA 保留步骤。


### OTA 升级
OTA 保留操作在模块的 **WebUI**（“刷写到另一槽位” / `bin/bl_flasher.sh`）中完成，而不是安装时的音量键菜单。重启进行 OTA 更新前，请打开模块页面执行刷写，把当前槽位的 `abl` 写入另一槽位，从而保留旧版本 ABL。跨版本升级时建议勾选“更新 efisp”，否则可能卡一屏。页面上的“已完成/已失败”提示只描述**本次**启动的任务：如果后台任务根本没有起来，页面会提示“任务启动失败”，而不会把上一次的结果当成本次结果。

