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
BY_NAME_DIR="/dev/block/by-name"
IMAGE_NAMES="abl"
LOG_FILE="$RUNTIME_DIR/flash.log"
STATE_FILE="$RUNTIME_DIR/state"
MESSAGE_FILE="$RUNTIME_DIR/message"
UPDATED_FILE="$RUNTIME_DIR/updated"
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
      flash.pid|state|message|updated|flash.log|flash.lock) ;;
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
  if ! blockdev --setrw "/dev/block/by-name/efisp" >> "$LOG_FILE" 2>&1; then
    write_log 'efisp 分区设置可写失败'
    return 1
  fi
  if ! dd if="$RUNTIME_DIR/patched.efi" of=/dev/block/by-name/efisp bs=4M conv=fsync >> "$LOG_FILE" 2>&1; then
    write_log 'efisp dd 刷写失败'
    return 1
  fi
  sync
  write_log "efisp 分区刷写完成"
  #检查patch log 是否包含 "Warning: Failed to patch ABL GBL\n" 如果没有则新的ABL版本存在GBL漏洞，返回伪失败，绕过后续BL flash
  if ! grep -q "Warning: Failed to patch ABL GBL" "$RUNTIME_DIR/patch.log"; then
    write_log "检测到新的ABL版本，存在GBL漏洞，跳过后续BL刷写以保留BL版本"
    return 2
  fi
  return 0
}

# detect ABL GBL vulnerability without flashing efisp
# 0 vulnerable (should skip BL flash), 1 detect failed, 2 not vulnerable
detect_gbl_vulnerability() {
  if ! build_patched_efi "$1"; then
    write_log '漏洞检测失败：补丁文件未生成'
    return 1
  fi
  if ! grep -q "Warning: Failed to patch ABL GBL" "$RUNTIME_DIR/patch.log"; then
    write_log '检测到新的ABL版本，存在GBL漏洞，跳过后续BL刷写'
    return 0
  fi
  write_log '未检测到GBL漏洞，继续后续BL刷写'
  return 2
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

  _out="CURRENT_SLOT=${current_slot}
TARGET_SLOT=${target_slot}
RUNNING=${running}
PID=${pid}
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

  efisp_failed='0'
  abl_part=$(partition_path abl "$target_slot")

  if [ "$update_efisp" = 'update-efisp' ] || [ "$update_efisp" = '1' ] || [ "$update_efisp" = 'true' ]; then
    #patch abl and flash efisp first, since it's the only one that can brick the device if something goes wrong
    #0 success, 1 failed, 2 new ABL version with GBL vulnerability detected
    patch_efisp "$abl_part" "$debug_mode"
    ret=$?
    case $ret in
      0) ;; # 成功，继续
       1) efisp_failed='1'
         write_state 'running' 'efisp 分区刷写失败，继续刷写 BL 以保留旧版本'
         write_log '警告：新版本ABL补丁应用失败，但是继续刷写BL以保留BL版本，以加载旧版本efisp'
         write_log '理论可以保留BL版本成功引导，但不排除存在未知风险，请上传补丁日志以供分析'
         ;;
      2) write_state 'success' 'efisp 分区刷写完成，但跳过了BL刷写以保留BL版本'
         write_log 'efisp 分区刷写完成，但跳过了BL刷写（检测到GBL漏洞）'
         exit 0 ;;
      *) write_state 'error' '未知错误'
         exit 1 ;;
    esac
  else
    write_log '未勾选 efisp 更新，跳过 efisp 分区操作'
      detect_gbl_vulnerability "$abl_part"
      ret=$?
      case $ret in
        0) write_state 'success' '检测到GBL漏洞，已跳过BL刷写'
           write_log '未更新efisp且检测到GBL漏洞，已跳过BL刷写'
           exit 0 ;;
        1) write_log '漏洞检测失败，继续执行BL刷写流程' ;;
        2) ;;
        *) write_log '警告：未知检测结果，继续执行BL刷写流程' ;;
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
    if ! dd if="$srcpart" of="$part" bs=4M conv=fsync >> "$LOG_FILE" 2>&1; then
      write_state 'error' "分区 $name 刷写失败"; exit 1
    fi
    sync
    write_log "$name 完成"
  done

  if [ "$efisp_failed" = '1' ]; then
    write_state 'warning' "BL 刷写完成，但 efisp 未更新"
    write_log 'BL 镜像刷写完成，但 efisp 未更新'
  elif [ "$update_efisp" = 'update-efisp' ] || [ "$update_efisp" = '1' ] || [ "$update_efisp" = 'true' ]; then
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
