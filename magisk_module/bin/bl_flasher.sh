#!/system/bin/sh
# 系统更新后 保留bl版本
if [ -z "$MODDIR" ]; then
  # CDPATH= deliberately clears any inherited CDPATH for this cd; ShellCheck
  # SC1007 misreads the empty assignment as a stray space.
  # shellcheck disable=SC1007
  MODDIR=$(CDPATH= cd -- "$(dirname "$0")/.." 2>/dev/null && pwd)
fi
if [ -z "$MODDIR" ]; then
  echo 'ERROR=MODDIR detection failed' >&2
  exit 1
fi
RUNTIME_DIR="$MODDIR/tmp"
BY_NAME_DIR="${GBL_BY_NAME_DIR:-/dev/block/by-name}"
IMAGE_NAMES="abl"
LOG_FILE="$RUNTIME_DIR/flash.log"
STATE_FILE="$RUNTIME_DIR/state"
MESSAGE_FILE="$RUNTIME_DIR/message"
UPDATED_FILE="$RUNTIME_DIR/updated"
TASK_FILE="$RUNTIME_DIR/task_id"
PID_FILE="$RUNTIME_DIR/flash.pid"
LOCK_DIR="$RUNTIME_DIR/flash.lock"

export PATH="/data/adb/ksu/bin:/system/bin:/system/xbin:$PATH"

timestamp() { date '+%Y-%m-%d %H:%M:%S'; }
emit() { printf '%s' "$1" | tr '\n' '\t'; }

ensure_runtime() {
  mkdir -p "$RUNTIME_DIR"
  [ -f "$LOG_FILE" ]     || : > "$LOG_FILE"
  [ -f "$STATE_FILE" ]   || printf '%s\n' 'idle' > "$STATE_FILE"
  [ -f "$MESSAGE_FILE" ] || printf '%s\n' '等待操作' > "$MESSAGE_FILE"
  [ -f "$UPDATED_FILE" ] || timestamp > "$UPDATED_FILE"
  [ -f "$TASK_FILE" ] || printf '%s\n' '0' > "$TASK_FILE"
}

write_state() {
  ensure_runtime
  printf '%s\n' "$1" > "$STATE_FILE"
  printf '%s\n' "$2" > "$MESSAGE_FILE"
  timestamp > "$UPDATED_FILE"
}

write_log() {
  ensure_runtime
  printf '[%s] %s\n' "$(timestamp)" "$*" >> "$LOG_FILE"
}

# Remove leftovers from a previous run (patched.efi, LinuxLoader.efi, non-flash
# logs, ...) while keeping the state, log and lock files the WebUI reads, so a
# stale artifact can never be mistaken for the current run's output.
clean_workdir() {
  for _f in "$RUNTIME_DIR"/*; do
    [ -e "$_f" ] || continue
    case "${_f##*/}" in
      flash.pid|state|message|updated|task_id|flash.log|flash.lock) ;;
      *) rm -rf "$_f" ;;
    esac
  done
}

detect_current_slot() {
  case "$(getprop ro.boot.slot_suffix 2>/dev/null)" in
    _a) printf '%s\n' '_a' ;;
    _b) printf '%s\n' '_b' ;;
    *)  return 1 ;;
  esac
}

other_slot() {
  case "$1" in
    _a) printf '%s\n' '_b' ;;
    _b) printf '%s\n' '_a' ;;
    *)  return 1 ;;
  esac
}

partition_path() { printf '%s\n' "$BY_NAME_DIR/${1}${2}"; }

# Backups live outside the module tree so a module uninstall/reinstall can never
# delete the only copy of a partition that was flashed.
BACKUP_ROOT="${GBL_BACKUP_DIR:-/data/adb/gbl_backup}"

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
  case "$_pname" in ''|*[!A-Za-z0-9_]*) write_log "备份失败：非法分区名 '$_pname'"; return 1 ;; esac
  [ -e "$_src" ] || { write_log "备份失败：分区不存在 $_src"; return 1; }
  mkdir -p "$BACKUP_ROOT" || { write_log "备份失败：无法创建 $BACKUP_ROOT"; return 1; }
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
      write_log "备份失败：无法创建备份文件 $_img"
      return 1
    fi
    _n=$((_n + 1))
  done
  if ! dd if="$_src" of="$_img" bs=4M conv=fsync >> "$LOG_FILE" 2>&1; then
    rm -f "$_img"
    write_log "备份失败：读取 $_pname 出错"
    return 1
  fi
  # The image must be non-empty.
  _sz="$(wc -c < "$_img" 2>/dev/null | tr -d '[:space:]')"
  case "$_sz" in ''|*[!0-9]*) rm -f "$_img"; write_log "备份失败：无法读取 $_pname 备份大小"; return 1 ;; esac
  if [ "$_sz" -le 0 ]; then
    rm -f "$_img"; write_log "备份失败：$_pname 备份为空"; return 1
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
        write_log "备份失败：$_pname 备份大小 $_sz 与源分区容量 $_srcsz 不一致"
        return 1
      fi ;;
  esac
  _sha="$(sha256sum "$_img" 2>/dev/null | cut -d' ' -f1)"
  if [ -z "$_sha" ]; then
    rm -f "$_img"
    write_log "备份失败：无法计算 $_pname 的 SHA-256"
    return 1
  fi
  if ! write_backup_meta "$_img.meta" "$_pname" "$_slot" "$_src" "$_sha" || [ ! -s "$_img.meta" ]; then
    rm -f "$_img" "$_img.meta"
    write_log "备份失败：无法写入 $_pname 的元数据"
    return 1
  fi
  if ! printf '%s  %s\n' "$_sha" "$(basename "$_img")" > "$_img.sha256" || [ ! -s "$_img.sha256" ]; then
    rm -f "$_img" "$_img.meta" "$_img.sha256"
    write_log "备份失败：无法写入 $_pname 的 SHA-256 文件"
    return 1
  fi
  write_log "已备份 $_pname ($_slot) -> $(basename "$_img") sha256=$_sha"
  return 0
}

# Read exactly $1 bytes back from block device $2 and compare with $3 (a regular
# file or another block device). Returns 0 only on an exact match, so a partial
# or short write is never reported as success.
#
# The read-back is written to a temporary file instead of being piped, so the
# read command's exit status is observable and a real I/O error is never
# mistaken for a content mismatch. Any read error, short read, or differing
# content fails; the temp file is always removed.
verify_written_range() { # <bytes> <blockdev> <source>
  _n="$1"; _dev="$2"; _src="$3"
  case "$_n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$_n" -gt 0 ] || return 1
  [ -e "$_dev" ] || return 1
  [ -e "$_src" ] || return 1
  _fsha="$(sha256sum "$_src" 2>/dev/null | cut -d' ' -f1)"
  [ -n "$_fsha" ] || return 1
  _vlog="${LOG_FILE:-$RUNTIME_DIR/verify.log}"
  _rb="$RUNTIME_DIR/verify_readback.bin"
  rm -f "$_rb"
  # Read ceil(N/4096) blocks (a whole number of blocks covering the range) into
  # the temp file. count=0 means "until EOF", so the block math must be >= 1.
  if ! dd if="$_dev" of="$_rb" bs=4096 count=$(((_n + 4095) / 4096)) 2>>"$_vlog"; then
    rm -f "$_rb"; return 1
  fi
  # A short read means the range could not be read back in full.
  _rsize="$(wc -c < "$_rb" 2>/dev/null | tr -d '[:space:]')"
  case "$_rsize" in ''|*[!0-9]*) rm -f "$_rb"; return 1 ;; esac
  [ "$_rsize" -ge "$_n" ] || { rm -f "$_rb"; return 1; }
  _dsha="$(head -c "$_n" "$_rb" 2>/dev/null | sha256sum | cut -d' ' -f1)"
  rm -f "$_rb"
  [ -n "$_dsha" ] && [ "$_fsha" = "$_dsha" ]
}

# Flash $1 to block device $2 and read the written range back. Returns 0 only
# when the write succeeded and the read-back matched; a mismatch is a failure,
# never reported as success.
flash_and_verify() { # <source> <blockdev>
  _src="$1"; _dev="$2"
  _bytes="$(wc -c < "$_src" 2>/dev/null | tr -d '[:space:]')"
  case "$_bytes" in ''|*[!0-9]*) write_log '刷写失败：无法确定写入长度'; return 1 ;; esac
  [ "$_bytes" -gt 0 ] || { write_log '刷写失败：源为空'; return 1; }
  if ! dd if="$_src" of="$_dev" bs=4M conv=fsync >> "$LOG_FILE" 2>&1; then
    write_log '刷写失败：dd 写入出错'
    return 1
  fi
  sync
  if ! verify_written_range "$_bytes" "$_dev" "$_src"; then
    write_log '刷写后校验失败：分区内容与源不一致'
    return 1
  fi
  write_log "刷写后校验通过（$_bytes 字节）"
  return 0
}

current_pid() {
  if [ -f "$PID_FILE" ]; then
    pid=$(tr -d '[:space:]' < "$PID_FILE")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid"; return 0
    fi
    rm -f "$PID_FILE"
  fi
  return 1
}
# Extract $1 (an ABL partition) and apply the efisp patch, leaving the result in
# $RUNTIME_DIR/patched.efi and the tool output in $RUNTIME_DIR/patch.log. Stale
# outputs are removed first so a failed run cannot be mistaken for a success.
# Returns 0 only when a non-empty patched.efi was produced, otherwise 1.
build_patched_efi() {
  rm -f "$RUNTIME_DIR/LinuxLoader.efi" "$RUNTIME_DIR/patched.efi" "$RUNTIME_DIR/patch.log"
  if ! "$MODDIR/bin/extractfv" -o "$RUNTIME_DIR" -v "$1" >> "$LOG_FILE" 2>&1; then
    write_log 'ABL 提取失败'
    return 1
  fi
  if [ ! -s "$RUNTIME_DIR/LinuxLoader.efi" ]; then
    write_log 'ABL 提取失败：未生成 LinuxLoader.efi'
    return 1
  fi
  if ! "$MODDIR/bin/patch_abl" "$RUNTIME_DIR/LinuxLoader.efi" "$RUNTIME_DIR/patched.efi" >> "$RUNTIME_DIR/patch.log" 2>&1; then
    cat "$RUNTIME_DIR/patch.log" >> "$LOG_FILE"
    write_log '补丁应用失败'
    return 1
  fi
  cat "$RUNTIME_DIR/patch.log" >> "$LOG_FILE"
  if [ ! -s "$RUNTIME_DIR/patched.efi" ]; then
    write_log '补丁应用失败'
    return 1
  fi
  return 0
}

# extractfv and patch_abl from abl_dest
# 0 success, 1 failed 2 new ABL version with GBL vulnerability detected, skipping BL flash to preserve BL version
# $1: abl partition path, $2: debug_mode (optional, "debug" to skip flash)
patch_efisp() {
  debug_mode="${2:-no-debug}"
  build_patched_efi "$1" || return 1

  # Skip flash in debug mode
  if [ "$debug_mode" = "debug" ]; then
    write_log "调试模式：跳过 efisp 分区刷写，文件已保存在 $RUNTIME_DIR/patched.efi"
    return 0
  fi

  #flash
  # Resolve the efisp device through partition_path so the path is consistent
  # with every other partition access (and overridable via GBL_BY_NAME_DIR).
  efisp_dev="$(partition_path efisp "")"
  if ! blockdev --setrw "$efisp_dev" >> "$LOG_FILE" 2>&1; then
    write_log 'efisp 分区设置可写失败'
    return 1
  fi
  # Write the patched efisp and read the written range back; a mismatch is a
  # failure, so a partial write is never reported as done.
  if ! flash_and_verify "$RUNTIME_DIR/patched.efi" "$efisp_dev"; then
    write_log 'efisp 分区刷写或校验失败'
    return 1
  fi
  write_log "efisp 分区刷写完成并通过校验"
  #检查patch log 是否包含 "Warning: Failed to patch ABL GBL\n" 如果没有则新的ABL版本存在GBL漏洞，返回伪失败，绕过后续BL flash
  if ! grep -q "Warning: Failed to patch ABL GBL" "$RUNTIME_DIR/patch.log"; then
    write_log "检测到新的ABL版本，存在GBL漏洞，跳过后续BL刷写以保留BL版本"
    return 2
  fi
  return 0
}

# Classify the GBL state of the ABL at $1 from the extractor/patcher's own
# output. Prints exactly one of: Vulnerable | NotVulnerable | Unknown | Error.
#
# The verdict comes only from whether the firmware carries the GBL "efisp"
# marker and from the patcher's exit status/output. It is never derived from the
# ROM version or build id, and any failure along the way is reported as Error or
# Unknown -- never as Vulnerable -- so a failed detection cannot be mistaken for
# a confirmed vulnerable device.
classify_gbl() { # <abl_partition>
  rm -f "$RUNTIME_DIR/LinuxLoader.efi" "$RUNTIME_DIR/patched.efi" "$RUNTIME_DIR/patch.log"
  if ! "$MODDIR/bin/extractfv" -o "$RUNTIME_DIR" -v "$1" >> "$LOG_FILE" 2>&1; then
    write_log 'GBL 状态：Error（ABL 提取失败）'
    printf '%s\n' 'Error'; return 0
  fi
  if [ ! -s "$RUNTIME_DIR/LinuxLoader.efi" ]; then
    write_log 'GBL 状态：Error（提取结果为空）'
    printf '%s\n' 'Error'; return 0
  fi
  if ! "$MODDIR/bin/patch_abl" "$RUNTIME_DIR/LinuxLoader.efi" "$RUNTIME_DIR/patched.efi" >> "$RUNTIME_DIR/patch.log" 2>&1; then
    write_log 'GBL 状态：Error（补丁工具执行失败）'
    printf '%s\n' 'Error'; return 0
  fi
  if [ ! -s "$RUNTIME_DIR/patched.efi" ]; then
    write_log 'GBL 状态：Error（未生成补丁输出）'
    printf '%s\n' 'Error'; return 0
  fi
  if grep -q "Warning: Failed to patch ABL GBL" "$RUNTIME_DIR/patch.log"; then
    write_log 'GBL 状态：NotVulnerable（未发现 GBL 特征）'
    printf '%s\n' 'NotVulnerable'; return 0
  fi
  # The GBL marker was patched. Require the patcher to confirm the output and
  # the bytes to actually differ, otherwise the result stays Unknown.
  if ! grep -q "Saved to " "$RUNTIME_DIR/patch.log"; then
    write_log 'GBL 状态：Unknown（补丁工具未确认输出）'
    printf '%s\n' 'Unknown'; return 0
  fi
  if cmp -s "$RUNTIME_DIR/LinuxLoader.efi" "$RUNTIME_DIR/patched.efi"; then
    write_log 'GBL 状态：Unknown（输出与输入一致）'
    printf '%s\n' 'Unknown'; return 0
  fi
  write_log 'GBL 状态：Vulnerable（检测到 GBL 漏洞特征）'
  printf '%s\n' 'Vulnerable'; return 0
}

# detect ABL GBL vulnerability without flashing efisp
# 0 vulnerable (should skip BL flash), 1 detect failed/unknown, 2 not vulnerable
detect_gbl_vulnerability() {
  state=$(classify_gbl "$1")
  case "$state" in
    Vulnerable)    return 0 ;;
    NotVulnerable) return 2 ;;
    *)             return 1 ;;
  esac
}

cleanup_lock() { rm -rf "$LOCK_DIR"; rm -f "$PID_FILE";  }

print_status() {
  ensure_runtime
  current_slot=$(getprop ro.boot.slot_suffix 2>/dev/null)
  case "$current_slot" in _a|_b) ;; *) current_slot='' ;; esac
  target_slot=''
  case "$current_slot" in _a) target_slot='_b' ;; _b) target_slot='_a' ;; esac

  running='0'; pid=''
  if [ -f "$PID_FILE" ]; then
    pid=$(tr -d '[:space:]' < "$PID_FILE")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      running='1'
    else
      pid=''; rm -f "$PID_FILE"
    fi
  fi

  _state=''; [ -f "$STATE_FILE" ] && read -r _state < "$STATE_FILE"
  _msg=''; [ -f "$MESSAGE_FILE" ] && read -r _msg < "$MESSAGE_FILE"
  _upd=''; [ -f "$UPDATED_FILE" ] && read -r _upd < "$UPDATED_FILE"
  _task=''; [ -f "$TASK_FILE" ] && read -r _task < "$TASK_FILE"

  # A "running" record with no live process means the run was interrupted (the
  # page was closed, the device rebooted, ...). Report it as unknown instead of
  # leaving a stale "running" that the WebUI would show forever.
  stale='0'
  if [ "$running" != '1' ]; then
    case "$_state" in
      running) stale='1' ;;
    esac
  fi

  # module.prop is the single source of truth for the module metadata; the
  # WebUI must never hardcode it.
  _modname=$(sed -n 's/^name=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)
  _modver=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null | head -n 1)

  _out="MODULE_NAME=${_modname}
MODULE_VERSION=${_modver}
CURRENT_SLOT=${current_slot}
TARGET_SLOT=${target_slot}
RUNNING=${running}
STALE=${stale}
PID=${pid}
TASK_ID=${_task}
DEVICE=$(getprop ro.product.name 2>/dev/null)
MODEL=$(getprop ro.product.model 2>/dev/null)
STATE=${_state}
MESSAGE=${_msg}
UPDATED_AT=${_upd}"

  emit "$_out"
}

run_flash() {
  update_efisp="${1:-skip-efisp}"
  debug_mode="no-debug"
  # Parse mode
  case "$update_efisp" in
    "debug")
      debug_mode="debug"
      update_efisp="skip-efisp"
      ;;
  esac

  ensure_runtime
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    write_log '已有刷写任务在执行，拒绝重复启动'
    exit 1
  fi
  printf '%s\n' "$$" > "$PID_FILE"
  printf '%s-%s\n' "$(date +%s)" "$$" > "$TASK_FILE"
  trap cleanup_lock EXIT INT TERM HUP
  : > "$LOG_FILE"
  clean_workdir

  current_slot=$(detect_current_slot 2>/dev/null || true)
  if [ -z "$current_slot" ]; then
    write_state 'error' '无法识别当前槽位'; write_log '无法识别当前槽位'; exit 1
  fi
  target_slot=$(other_slot "$current_slot" 2>/dev/null || true)
  if [ -z "$target_slot" ]; then
    write_state 'error' '无法计算目标槽位'; write_log '无法计算目标槽位'; exit 1
  fi

  write_state 'running' "正在将镜像刷写到槽位 $target_slot"
  write_log "当前槽位: $current_slot  目标槽位: $target_slot"

  # Debug mode: process but don't flash
  if [ "$debug_mode" = "debug" ]; then
    write_log "调试模式：仅处理不刷写"
    abl_part=$(partition_path abl "$target_slot")
    if [ "$update_efisp" = 'update-efisp' ] || [ "$update_efisp" = '1' ] || [ "$update_efisp" = 'true' ]; then
      patch_efisp "$abl_part" "$debug_mode"
      ret=$?
      if [ $ret -eq 0 ]; then
        write_state 'success' "调试完成，文件保存在 $RUNTIME_DIR"
        write_log "调试完成，生成的文件：$RUNTIME_DIR/patched.efi"
      else
     write_state 'error' '调试过程中出错'
        write_log '调试失败，请查看日志'
      fi
    else
      write_log '调试模式下未勾选 efisp 更新，仅提取 ABL'
      rm "$RUNTIME_DIR/LinuxLoader.efi" 2>/dev/null || true
      "$MODDIR/bin/extractfv" -o "$RUNTIME_DIR" -v "$abl_part" >> "$LOG_FILE" 2>&1
      if [ -f "$RUNTIME_DIR/LinuxLoader.efi" ]; then
        write_state 'success' "调试完成，ABL 已提取到 $RUNTIME_DIR/LinuxLoader.efi"
        write_log "调试完成，提取的 ABL：$RUNTIME_DIR/LinuxLoader.efi"
      else
        write_state 'error' 'ABL 提取失败'
      fi
    fi
    exit 0
  fi

  # Back up the partitions this run can write BEFORE flashing. A failed backup
  # aborts the run, so no destructive step depends on a missing backup. Each run
  # writes a new timestamped file and never deletes an existing backup.
  write_log '开始备份原始分区'
  if ! backup_partition "$(partition_path abl "$target_slot")" abl "$target_slot"; then
    write_state 'error' 'abl 备份失败，已中止刷写'
    write_log 'abl 备份失败，已中止刷写'
    exit 1
  fi
  if [ "$update_efisp" = 'update-efisp' ] || [ "$update_efisp" = '1' ] || [ "$update_efisp" = 'true' ]; then
    if ! backup_partition "$(partition_path efisp "")" efisp "$current_slot"; then
      write_state 'error' 'efisp 备份失败，已中止刷写'
      write_log 'efisp 备份失败，已中止刷写'
      exit 1
    fi
  fi

  abl_part=$(partition_path abl "$target_slot")

  if [ "$update_efisp" = 'update-efisp' ] || [ "$update_efisp" = '1' ] || [ "$update_efisp" = 'true' ]; then
    #patch abl and flash efisp first, since it's the only one that can brick the device if something goes wrong
    #0 success, 1 failed, 2 new ABL version with GBL vulnerability detected
    patch_efisp "$abl_part" "$debug_mode"
    ret=$?
    case $ret in
      0) ;; # 成功，继续
      2) write_state 'success' 'efisp 分区刷写完成，但跳过了BL刷写以保留BL版本'
         write_log 'efisp 分区刷写完成，但跳过了BL刷写（检测到GBL漏洞）'
         exit 0 ;;
      *) # efisp 写入或回读校验失败：立即中止，绝不继续写 ABL 目标槽
         write_state 'error' 'efisp 分区刷写或校验失败，已中止刷写（未修改 ABL 目标槽）'
         write_log 'efisp 分区刷写或校验失败，已中止刷写，未修改 ABL 目标槽'
         exit 1 ;;
    esac
  else
    write_log '未勾选 efisp 更新，跳过 efisp 分区操作'
      detect_gbl_vulnerability "$abl_part"
      ret=$?
      case $ret in
        0) # Vulnerable: keep the BL version by skipping the BL flash.
           write_state 'success' '检测到GBL漏洞，已跳过BL刷写'
           write_log '未更新efisp且检测到GBL漏洞，已跳过BL刷写'
           exit 0 ;;
        2) ;; # NotVulnerable: keep the normal BL flash behaviour.
        *) # Unknown/Error: the GBL state could not be confirmed. Abort instead
           # of writing the ABL target slot on an unconfirmed verdict.
           write_state 'error' 'GBL 状态无法确定（Unknown/Error），已中止刷写（未修改 ABL 目标槽）'
           write_log 'GBL 状态无法确定（检测失败或未知），已中止刷写，未修改 ABL 目标槽'
           exit 1 ;;
      esac
  fi

  for name in $IMAGE_NAMES; do
    part=$(partition_path "$name" "$target_slot")
    srcpart=$(partition_path "$name" "$current_slot")

    write_log "blockdev --setrw $part"
    if ! blockdev --setrw "$part" >> "$LOG_FILE" 2>&1; then
      write_state 'error' "分区 $name 设置可写失败"; exit 1
    fi
    write_log "刷写 $name -> $part"
    # Flash the slot copy and read the written range back; a mismatch aborts
    # instead of reporting a success the device cannot rely on.
    if ! flash_and_verify "$srcpart" "$part"; then
      write_state 'error' "分区 $name 刷写或校验失败"; exit 1
    fi
    write_log "$name 完成"
  done

  if [ "$update_efisp" = 'update-efisp' ] || [ "$update_efisp" = '1' ] || [ "$update_efisp" = 'true' ]; then
    write_state 'success' "全部刷写完成（含 efisp）"
    write_log '全部镜像与 efisp 刷写完成'
  else
    write_state 'success' "全部刷写完成（未更新 efisp）"
    write_log '全部镜像刷写完成（未更新 efisp）'
  fi
}

start_flash() {
  update_efisp="${1:-skip-efisp}"
  ensure_runtime
  if pid=$(current_pid 2>/dev/null); then
    emit "ALREADY_RUNNING=${pid}"; return 0
  fi
  if command -v nohup >/dev/null 2>&1; then
    nohup sh "$0" flash "$update_efisp" >/dev/null 2>&1 &
  else
    sh "$0" flash "$update_efisp" </dev/null >/dev/null 2>&1 &
  fi
  sleep 1
  if pid=$(current_pid 2>/dev/null); then
    emit "STARTED=1
PID=${pid}"
  else
    _st=''; [ -f "$STATE_FILE" ] && read -r _st < "$STATE_FILE"
    case "$_st" in
      success|error|warning) emit "FINISHED=${_st}" ;;
      *) emit 'STARTED=0' ;;
    esac
  fi
}

print_log() { ensure_runtime; tr '\n' '\t' < "$LOG_FILE"; }
tail_log()  { ensure_runtime; tail -n "${1:-200}" "$LOG_FILE" | tr '\n' '\t'; }

clear_log() {
  ensure_runtime
  if current_pid >/dev/null 2>&1; then emit 'BUSY=1'; return 1; fi
  : > "$LOG_FILE"
  write_state 'idle' '日志已清空'
  emit 'CLEARED=1'
}

case "$1" in
  status)    print_status ;;
  flash)     run_flash "$2" ;;
  start)     start_flash "$2" ;;
  log)       print_log ;;
  tail)      tail_log "$2" ;;
  clear-log) clear_log ;;
  *)         printf 'Usage: %s {status|flash|start|log|tail [lines]|clear-log}\n' "$0" >&2; exit 1 ;;
esac
