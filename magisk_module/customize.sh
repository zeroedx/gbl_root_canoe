#!/system/bin/sh

ui_print "- Verifying device model"
_model=$(getprop ro.product.model 2>/dev/null)
_name=$(getprop ro.product.name 2>/dev/null)
_incr=$(getprop ro.build.version.incremental 2>/dev/null)
ui_print "- Device verified: $_model / $_name / $_incr"
ui_print "- Setting permissions"
set_perm_recursive "$MODPATH/bin" 0 0 0755 0755
set_perm_recursive "$MODPATH/webroot" 0 0 0755 0644
set_perm "$MODPATH/module.prop" 0 0 0644
set_perm "$MODPATH/skip_mount" 0 0 0644
set_perm "$MODPATH/customize.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755

detect_current_slot() {
  case "$(getprop ro.boot.slot_suffix 2>/dev/null)" in
    _a) printf '%s\n' '_a' ;;
    _b) printf '%s\n' '_b' ;;
    *)  return 1 ;;
  esac
}
BY_NAME_DIR="/dev/block/by-name"
RUNTIME_DIR="$MODPATH/tmp"
mkdir -p "$RUNTIME_DIR"
partition_path() { printf '%s\n' "$BY_NAME_DIR/${1}${2}"; }
ABLREPO_URL="https://raw.githubusercontent.com/superturtlee/gbl_root_canoe/main/ablrepo"

# Verify $1 against the sha256 in $2 (first whitespace-delimited token).
verify_sha256() {
  [ -f "$1" ] && [ -f "$2" ] || return 1
  expected=$(cut -d' ' -f1 "$2" | tr -d '[:space:]')
  actual=$(sha256sum "$1" | cut -d' ' -f1 | tr -d '[:space:]')
  [ -n "$expected" ] && [ "$expected" = "$actual" ]
}

# Download $1 into $2 using whichever fetcher is available.
download_url() {
  if command -v wget >/dev/null 2>&1; then
    timeout 60 wget -O "$2" "$1" >/dev/null 2>&1
  elif command -v curl >/dev/null 2>&1; then
    timeout 60 curl -fL -o "$2" "$1" >/dev/null 2>&1
  else
    return 1
  fi
}

# Fetch an older ABL with the GBL vulnerability. Looks up the local module
# bundle first, then the cloud. On success, leaves the image at
# $RUNTIME_DIR/repo_abl.img and returns 0; otherwise returns 1.
fetch_abl_from_repo() {
  product=$(getprop ro.product.name 2>/dev/null)
  [ -z "$product" ] && return 1
  local_dir="$MODPATH/ablrepo/$product"
  # Drop any stale image first so a failed fetch cannot leave an old one behind
  # for the caller to flash.
  rm -f "$RUNTIME_DIR/repo_abl.img"
  if [ -f "$local_dir/abl.img" ]; then
    if [ -f "$local_dir/abl.sha256" ] && verify_sha256 "$local_dir/abl.img" "$local_dir/abl.sha256"; then
      if cp "$local_dir/abl.img" "$RUNTIME_DIR/repo_abl.img"; then
        ui_print "已从本地模块找到 ABL"
        return 0
      fi
      ui_print "本地 ABL 复制失败"
      return 1
    fi
    ui_print "本地 ABL 校验失败，尝试云端"
  fi
  ui_print "正在从云端下载 ABL..."
  if download_url "$ABLREPO_URL/$product/abl.sha256" "$RUNTIME_DIR/repo_abl.sha256" && \
     download_url "$ABLREPO_URL/$product/abl.img" "$RUNTIME_DIR/repo_abl.img"; then
    if verify_sha256 "$RUNTIME_DIR/repo_abl.img" "$RUNTIME_DIR/repo_abl.sha256"; then
      return 0
    fi
    ui_print "云端 ABL 校验失败"
  fi
  return 1
}

#install efisp
ui_print "确保你的内核没有Baseband Guard，设备BL锁已经解锁"
ui_print "确保你的设备是8gen5/8elitegen5"
ui_print "检测漏洞中..."
current_slot=$(detect_current_slot 2>/dev/null)
ui_print "请选择是否第一次安装假回锁"
ui_print "音量上为是（全新安装，需要格式化)"
ui_print "音量下为否（如果之前安装过一次假回锁或者刚刚首次安装并格式化，建议选择否）"
ui_print "如果选择是，将会安装包含补丁的efisp 然后重启recovery 进行格式化，格式化后请安装一次这个模块来完成安装，这时选择否"
ui_print "如果选择否，将会安装OTA更新补丁，每次OTA更新后都需要打开这个模块来安装补丁，来保留BL版本，安装完成后重启系统即可"
while true; do #循环等待用户按键选择，音量上为是，音量下为否
  keyevent=$(timeout 0.5 getevent -l 2>/dev/null)
  if echo "$keyevent" | grep -q "KEY_VOLUMEUP"; then
    ui_print "选择了是，正在安装包含补丁的efisp"
    if [ -z "$current_slot" ]; then
      ui_print "无法识别当前槽位，已中止安装"
      abort "cannot detect current slot"
    fi
    abl_part=$(partition_path abl "$current_slot")
    $MODPATH/bin/extractfv -o "$MODPATH/tmp" -v "$abl_part" >> "$MODPATH/tmp/extract.log" 2>&1
    $MODPATH/bin/patch_abl "$MODPATH/tmp/LinuxLoader.efi" "$MODPATH/tmp/patched.efi" >> "$MODPATH/tmp/patch.log" 2>&1
    if [ ! -f "$MODPATH/tmp/patched.efi" ]; then
      ui_print "补丁应用失败，已中止安装"
      abort "patch failed"
    fi
    if grep -q "Warning: Failed to patch ABL GBL" "$RUNTIME_DIR/patch.log"; then
      ui_print "检测到当前 ABL 没有 GBL 漏洞"
      ui_print "ABL repo 中有带漏洞的旧版 ABL，是否下载并降级 abl 分区？"
      ui_print "音量上 = 下载并降级"
      ui_print "音量下 = 取消"
      repo_confirm=""
      while [ -z "$repo_confirm" ]; do
        keyevent=$(timeout 0.5 getevent -l 2>/dev/null)
        if echo "$keyevent" | grep -q "KEY_VOLUMEUP"; then
          repo_confirm=yes
        elif echo "$keyevent" | grep -q "KEY_VOLUMEDOWN"; then
          repo_confirm=no
        fi
      done
      if [ "$repo_confirm" = "no" ]; then
        ui_print "已取消降级，中止安装"
        abort "downgrade declined"
      fi
      if ! fetch_abl_from_repo; then
        ui_print "ABL repo 查找失败，请手动刷写带 GBL 漏洞的旧版本 ABL 到 abl 分区后重试"
        abort "abl repo lookup failed"
      fi
      ui_print "正在降级 abl 分区..."
      if ! blockdev --setrw "$abl_part" >> "$RUNTIME_DIR/flash.log" 2>&1; then
        ui_print "abl 分区设置可写失败"
        abort "setrw abl failed"
      fi
      if ! dd if="$RUNTIME_DIR/repo_abl.img" of="$abl_part" bs=4M conv=fsync >> "$RUNTIME_DIR/flash.log" 2>&1; then
        ui_print "abl 分区降级刷写失败"
        abort "downgrade abl failed"
      fi
      sync
      ui_print "abl 分区已降级"
    fi
    if ! blockdev --setrw "/dev/block/by-name/efisp" >> "$MODPATH/tmp/flash.log" 2>&1; then
      ui_print "efisp 分区设置可写失败，已中止安装"
      abort "setrw failed"
    fi
    if ! dd if="$MODPATH/tmp/patched.efi" of=/dev/block/by-name/efisp bs=4M conv=fsync >> "$MODPATH/tmp/flash.log" 2>&1; then
      ui_print "efisp 分区刷写失败，已中止安装"
      abort "flash failed"
    fi
    sync
    ui_print "安装完成，请重启到recovery进行格式化，格式化后请安装一次这个模块来完成安装，这时选择否"
    rm -rf "$RUNTIME_DIR"
    break
  elif echo "$keyevent" | grep -q "KEY_VOLUMEDOWN"; then
    ui_print "选择了否，正在安装OTA更新模块"
    ui_print "安装完成，请重启系统即可"
    rm -rf "$RUNTIME_DIR"
    break
  fi
done
