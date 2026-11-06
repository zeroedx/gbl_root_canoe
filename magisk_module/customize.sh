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

# Read the currently held volume key once. Prints "up"/"down" or nothing.
read_volume_key() {
  case "$(timeout 0.5 getevent -l 2>/dev/null)" in
    *KEY_VOLUMEUP*)   printf '%s\n' 'up' ;;
    *KEY_VOLUMEDOWN*) printf '%s\n' 'down' ;;
  esac
}
BY_NAME_DIR="${GBL_BY_NAME_DIR:-/dev/block/by-name}"
RUNTIME_DIR="$MODPATH/tmp"
mkdir -p "$RUNTIME_DIR"
partition_path() { printf '%s\n' "$BY_NAME_DIR/${1}${2}"; }
ABLREPO_URL="https://raw.githubusercontent.com/SuperTurtleDev/gbl_root_canoe/main/ablrepo"

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

# Backups live outside the module tree so a module uninstall/reinstall can never
# delete the only copy of a partition that was flashed.
BACKUP_ROOT="${GBL_BACKUP_DIR:-/data/adb/gbl_backup}"

# Record which device/slot/time/source produced a backup, next to the image.
write_backup_meta() { # <meta_file> <partition> <slot> <source> <sha256>
  {
    printf 'partition=%s\n' "$2"
    printf 'slot=%s\n' "$3"
    printf 'model=%s\n' "$(getprop ro.product.name 2>/dev/null)"
    printf 'device_model=%s\n' "$(getprop ro.product.model 2>/dev/null)"
    printf 'source=%s\n' "$4"
    printf 'sha256=%s\n' "$5"
    printf 'created=%s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  } > "$1"
}

# Copy partition $1 to a timestamped file under $BACKUP_ROOT with a metadata
# sidecar. Each run writes a NEW file, so a failed run can never overwrite or
# delete the previous valid backup. Returns 0 only when the image was copied
# non-empty, its size matches the source capacity, and both the metadata and the
# SHA-256 sidecar were written.
backup_partition() { # <partition_path> <partition> <slot>
  _src="$1"; _pname="$2"; _slot="$3"
  case "$_pname" in ''|*[!A-Za-z0-9_]*) ui_print "备份失败：非法分区名 '$_pname'"; return 1 ;; esac
  [ -e "$_src" ] || { ui_print "备份失败：分区不存在 $_src"; return 1; }
  if ! mkdir -p "$BACKUP_ROOT"; then
    ui_print "备份失败：无法创建 $BACKUP_ROOT"
    return 1
  fi
  _stamp="$(date '+%Y%m%d-%H%M%S' 2>/dev/null)"
  [ -n "$_stamp" ] || _stamp="$(date +%s 2>/dev/null)"
  # Claim a backup filename that does not exist yet. A timestamp alone is not
  # unique: two backups in the same second (same or different PID) would collide
  # and clobber a good backup. `set -C` (noclobber) makes the create atomic, so an
  # existing name is never truncated; a numeric suffix resolves a collision
  # without ever touching the file that is already there.
  _n=0
  while :; do
    if [ "$_n" -eq 0 ]; then
      _img="$BACKUP_ROOT/${_pname}${_slot}_${_stamp}-$$.img"
    else
      _img="$BACKUP_ROOT/${_pname}${_slot}_${_stamp}-$$-$_n.img"
    fi
    if ( set -C; : > "$_img" ) 2>/dev/null; then
      break
    elif [ ! -e "$_img" ]; then
      ui_print "备份失败：无法创建备份文件 $_img"
      return 1
    fi
    _n=$((_n + 1))
  done
  if ! dd if="$_src" of="$_img" bs=4M conv=fsync >> "$RUNTIME_DIR/backup.log" 2>&1; then
    rm -f "$_img"
    ui_print "备份失败：读取 $_pname 出错"
    return 1
  fi
  # The image must be non-empty.
  _sz="$(wc -c < "$_img" 2>/dev/null | tr -d '[:space:]')"
  case "$_sz" in ''|*[!0-9]*) rm -f "$_img"; ui_print "备份失败：无法读取 $_pname 备份大小"; return 1 ;; esac
  if [ "$_sz" -le 0 ]; then
    rm -f "$_img"; ui_print "备份失败：$_pname 备份为空"; return 1
  fi
  # When the source reports its size, the copy must match it exactly. A mismatch
  # means the read was short (or the partition changed underneath us), so the
  # backup cannot be trusted. blockdev is skipped for regular files, which have
  # no BLKGETSIZE64.
  _srcsz="$(blockdev --getsize64 "$_src" 2>/dev/null | tr -d '[:space:]')"
  case "$_srcsz" in
    ''|*[!0-9]*) ;; # not a block device / size unavailable: skip the cross-check
    *)
      if [ "$_sz" != "$_srcsz" ]; then
        rm -f "$_img"
        ui_print "备份失败：$_pname 备份大小 $_sz 与源分区容量 $_srcsz 不一致"
        return 1
      fi ;;
  esac
  _sha="$(sha256sum "$_img" 2>/dev/null | cut -d' ' -f1)"
  if [ -z "$_sha" ]; then
    rm -f "$_img"
    ui_print "备份失败：无法计算 $_pname 的 SHA-256"
    return 1
  fi
  if ! write_backup_meta "$_img.meta" "$_pname" "$_slot" "$_src" "$_sha" || [ ! -s "$_img.meta" ]; then
    rm -f "$_img" "$_img.meta"
    ui_print "备份失败：无法写入 $_pname 的元数据"
    return 1
  fi
  if ! printf '%s  %s\n' "$_sha" "$(basename "$_img")" > "$_img.sha256" || [ ! -s "$_img.sha256" ]; then
    rm -f "$_img" "$_img.meta" "$_img.sha256"
    ui_print "备份失败：无法写入 $_pname 的 SHA-256 文件"
    return 1
  fi
  ui_print "已备份 $_pname ($_slot) -> $(basename "$_img")"
  ui_print "  机型=$(getprop ro.product.name 2>/dev/null) 时间=$_stamp sha256=$_sha"
  return 0
}

# Read exactly $1 bytes back from block device $2 and compare with file $3.
# Returns 0 only on an exact match, so a partial/short write is never reported
# as success.
#
# The read-back goes to a temporary file instead of a pipe, so the read
# command's exit status is observable and a real I/O error is never mistaken for
# a content mismatch. Any read error, short read, or differing content fails.
verify_written_range() { # <bytes> <blockdev> <file> <log>
  _n="$1"; _dev="$2"; _file="$3"; _vlog="${4:-$RUNTIME_DIR/verify.log}"
  case "$_n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_n" -gt 0 ] || return 1
  [ -e "$_dev" ] || return 1
  [ -f "$_file" ] || return 1
  _fsha="$(sha256sum "$_file" 2>/dev/null | cut -d' ' -f1)"
  [ -n "$_fsha" ] || return 1
  _rb="$RUNTIME_DIR/verify_readback.bin"
  rm -f "$_rb"
  if ! dd if="$_dev" of="$_rb" bs=4096 count=$(((_n + 4095) / 4096)) 2>>"$_vlog"; then
    rm -f "$_rb"; return 1
  fi
  _rsize="$(wc -c < "$_rb" 2>/dev/null | tr -d '[:space:]')"
  case "$_rsize" in ''|*[!0-9]*) rm -f "$_rb"; return 1 ;; esac
  [ "$_rsize" -ge "$_n" ] || { rm -f "$_rb"; return 1; }
  _dsha="$(head -c "$_n" "$_rb" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  rm -f "$_rb"
  [ -n "$_dsha" ] && [ "$_fsha" = "$_dsha" ]
}

# Flash file $1 to block device $2 and read the written range back. Returns 0
# only when the write succeeded AND the read-back matched; a mismatch is
# reported as a failure, never as success.
flash_and_verify() { # <file> <blockdev> <log>
  _file="$1"; _dev="$2"; _log="$3"
  _bytes="$(wc -c < "$_file" 2>/dev/null | tr -d '[:space:]')"
  case "$_bytes" in ''|*[!0-9]*) ui_print "刷写失败：无法确定写入长度"; return 1 ;; esac
  [ "$_bytes" -gt 0 ] || { ui_print "刷写失败：源文件为空"; return 1; }
  if ! dd if="$_file" of="$_dev" bs=4M conv=fsync >> "$_log" 2>&1; then
    ui_print "刷写失败：dd 写入出错"
    return 1
  fi
  sync
  if ! verify_written_range "$_bytes" "$_dev" "$_file" "$_log"; then
    ui_print "刷写后校验失败：分区内容与源文件不一致（未确认写入成功）"
    return 1
  fi
  ui_print "刷写后校验通过（$_bytes 字节）"
  return 0
}

# Map the running device to its ablrepo directory name. Matching is exact, so a
# device can never fall back to another device's firmware. The nezha global ROM
# shares the "nezha" codename but ships different ABL firmware, so it is picked
# out by its global build suffix (...MIXM); every other device maps by codename.
resolve_device() {
  _product=$(getprop ro.product.name 2>/dev/null)
  case "$_product" in
    myron|pudding|popsicle|pandora|nezha_global) printf '%s\n' "$_product" ;;
    nezha)
      _build="$(getprop ro.build.version.incremental 2>/dev/null)$(getprop ro.build.display.id 2>/dev/null)"
      case "$_build" in
        *MIXM*) printf '%s\n' nezha_global ;;
        *)      printf '%s\n' nezha ;;
      esac ;;
    *) return 1 ;;
  esac
}

# Fetch an older ABL with the GBL vulnerability. Looks up the local module
# bundle first, then the cloud. On success, leaves the image at
# $RUNTIME_DIR/repo_abl.img and returns 0; otherwise returns 1.
fetch_abl_from_repo() {
  product=$(resolve_device) || return 1
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
  # Never leave a partial or failed download behind for the caller to flash.
  rm -f "$RUNTIME_DIR/repo_abl.img" "$RUNTIME_DIR/repo_abl.sha256"
  return 1
}

#install efisp
ui_print "确保你的内核没有Baseband Guard，设备BL锁已经解锁"
ui_print "确保你的设备是8gen5/8elitegen5"
ui_print "检测漏洞中..."
# Device identification is a hard gate: an unrecognised device must abort before
# any partition is read or written, never fall through to a risky operation.
_resolved_product=$(resolve_device) || {
  ui_print "未知设备：$(getprop ro.product.name 2>/dev/null) 不在支持列表中，已安全中止（未触碰任何分区）"
  abort "unsupported device"
}
ui_print "设备识别通过：$_resolved_product"
current_slot=$(detect_current_slot 2>/dev/null)
ui_print "请选择是否第一次安装假回锁"
ui_print "音量上为是（全新安装，需要格式化)"
ui_print "音量下为否（如果之前安装过一次假回锁或者刚刚首次安装并格式化，建议选择否）"
ui_print "如果选择是，将会安装包含补丁的efisp 然后重启recovery 进行格式化，格式化后请安装一次这个模块来完成安装，这时选择否"
ui_print "如果选择否，将会安装OTA更新补丁，每次OTA更新后都需要打开这个模块来安装补丁，来保留BL版本，安装完成后重启系统即可"
while true; do #循环等待用户按键选择，音量上为是，音量下为否
  case "$(read_volume_key)" in
  up)
    ui_print "选择了是，正在安装包含补丁的efisp"
    if [ -z "$current_slot" ]; then
      ui_print "无法识别当前槽位，已中止安装"
      abort "cannot detect current slot"
    fi
    abl_part=$(partition_path abl "$current_slot")
    efisp_part=$(partition_path efisp "")
    # Back up the partitions this flow writes BEFORE anything is flashed. A
    # failed backup aborts the run: no destructive step is allowed to depend on
    # a backup that does not exist. Backups are never deleted automatically.
    ui_print "正在备份原始分区..."
    if ! backup_partition "$efisp_part" efisp "$current_slot"; then
      ui_print "efisp 备份失败，已中止安装（未刷写任何分区）"
      abort "efisp backup failed"
    fi
    if ! backup_partition "$abl_part" abl "$current_slot"; then
      ui_print "abl 备份失败，已中止安装（未刷写任何分区）"
      abort "abl backup failed"
    fi
    # Drop any stale outputs first so a failed run cannot leave an old
    # patched.efi behind for the flash step to pick up.
    rm -f "$MODPATH/tmp/LinuxLoader.efi" "$MODPATH/tmp/patched.efi"
    if ! "$MODPATH/bin/extractfv" -o "$MODPATH/tmp" -v "$abl_part" >> "$MODPATH/tmp/extract.log" 2>&1; then
      ui_print "ABL 提取失败，已中止安装"
      abort "extract failed"
    fi
    if [ ! -s "$MODPATH/tmp/LinuxLoader.efi" ]; then
      ui_print "ABL 提取结果为空，已中止安装"
      abort "extract produced no output"
    fi
    if ! "$MODPATH/bin/patch_abl" "$MODPATH/tmp/LinuxLoader.efi" "$MODPATH/tmp/patched.efi" >> "$MODPATH/tmp/patch.log" 2>&1; then
      ui_print "补丁应用失败，已中止安装"
      abort "patch failed"
    fi
    if [ ! -s "$MODPATH/tmp/patched.efi" ]; then
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
        case "$(read_volume_key)" in
          up)   repo_confirm=yes ;;
          down) repo_confirm=no ;;
        esac
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
      # The downgrade image is a fixed-size partition dump; flash it and read
      # the written range back before trusting it.
      if ! flash_and_verify "$RUNTIME_DIR/repo_abl.img" "$abl_part" "$RUNTIME_DIR/flash.log"; then
        ui_print "abl 分区降级刷写或校验失败，已中止安装"
        abort "downgrade abl failed"
      fi
      ui_print "abl 分区已降级并通过校验"
    fi
    if ! blockdev --setrw "$efisp_part" >> "$MODPATH/tmp/flash.log" 2>&1; then
      ui_print "efisp 分区设置可写失败，已中止安装"
      abort "setrw failed"
    fi
    if ! flash_and_verify "$MODPATH/tmp/patched.efi" "$efisp_part" "$MODPATH/tmp/flash.log"; then
      ui_print "efisp 分区刷写或校验失败，已中止安装"
      abort "flash failed"
    fi
    ui_print "安装完成，请重启到recovery进行格式化，格式化后请安装一次这个模块来完成安装，这时选择否"
    rm -rf "$RUNTIME_DIR"
    break
    ;;
  down)
    ui_print "选择了否，正在安装OTA更新模块"
    ui_print "安装完成，请重启系统即可"
    rm -rf "$RUNTIME_DIR"
    break
    ;;
  esac
done
