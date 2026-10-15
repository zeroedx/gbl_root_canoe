# 构建指南

项目没有“机型限定”或“通用”的顶层构建；可发布的工具包与模块通过 `target_*`
目标构建，随后每个工具包再对你自己提供的 `abl.img` 运行其自带的
`build.sh` / `build.bat`。


## 构建工具包 / 模块

在仓库根目录执行（依赖见 README）：

```bash
make target_toolkit_linux      # toolkit_linux.zip
make target_toolkit_windows    # toolkit_windows.zip
make target_toolkit_android    # toolkit_android.zip
make target_magisk_module      # module_android.zip
```

构建这些目标**不需要** `abl.img`；该镜像只在之后运行工具包的
`build.sh` / `build.bat` 时才需要。


## 为特定机型修补 ABL

1. 将机型的 `abl.img` 放入工具包的 `./images` 目录
   （`PUT_ABL_IMG_HERE` 只是占位文件）。
2. 运行工具包自带的 `build.sh`（Linux / Android）或 `build.bat`（Windows）。

工具包会提取并破解 ABL，并生成一个 `efisp/` 目录
（`boot.efi`、`BOOTENTRIES`、`tools/`）。这些文件的去向与当前由谁加载，
见 安装说明 页面。

> 备注：ABL 修补依赖 GBL 漏洞，因此 ABL 必须带有该漏洞。若
> `patch_log.txt` 出现 `Failed to patch ABL GBL`，则需在开机前将 `abl`
> 分区降级为仍带该漏洞的旧版 ABL。
