#!/bin/sh
# set-hostname.sh — POSIX sh 通用版（更适合多发行版/Alpine/BusyBox）
# 用法：
#   curl -fsSL https://xxx/set-hostname.sh | sudo sh -s -- clawdbot
#   curl -fsSL https://xxx/set-hostname.sh | sudo sh -s -- clawdbot --fqdn clawdbot.example.com --cloud-init

set -eu

log() { printf '%s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

need_root() {
  if [ "$(id -u)" != "0" ]; then
    die "需要 root 权限运行（请用 sudo）"
  fi
}

ts() { date +%Y%m%d-%H%M%S; }

backup_file() {
  f="$1"
  [ -f "$f" ] || return 0
  b="${f}.bak.$(ts)"
  if cp -a "$f" "$b" 2>/dev/null; then :; else cp -p "$f" "$b"; fi
  log "备份: $f -> $b"
}

# 允许 a-z0-9- 和 '.'（FQDN），每段<=63，总长<=253，段首尾不得为 '-'
validate_hostname() {
  hn="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  [ -n "$hn" ] || return 1
  [ "${#hn}" -le 253 ] || return 1

  printf '%s' "$hn" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' || return 1

  # 每段长度<=63
  echo "$hn" | tr '.' '\n' | while IFS= read -r seg; do
    [ -n "$seg" ] || exit 1
    [ "${#seg}" -le 63 ] || exit 1
  done || return 1

  return 0
}

set_runtime_hostname() {
  short="$1"
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$short"
  elif command -v hostname >/dev/null 2>&1; then
    hostname "$short" || true
  fi
}

set_persistent_hostname() {
  short="$1"
  if [ -e /etc/hostname ]; then
    backup_file /etc/hostname
    printf '%s\n' "$short" > /etc/hostname
    log "写入 /etc/hostname: $short"
  fi
}

update_hosts_file() {
  short="$1"
  fqdn="${2:-}"
  hosts="/etc/hosts"
  [ -f "$hosts" ] || die "/etc/hosts 不存在"

  backup_file "$hosts"

  if [ -n "$fqdn" ]; then
    repl="127.0.1.1 $fqdn $short"
  else
    repl="127.0.1.1 $short"
  fi

  tmp="$(mktemp)"
  if grep -Eq '^[[:space:]]*127\.0\.1\.1[[:space:]]+' "$hosts"; then
    awk -v repl="$repl" '
      BEGIN{done=0}
      $0 ~ /^[[:space:]]*127\.0\.1\.1[[:space:]]+/ && done==0 {print repl; done=1; next}
      {print}
    ' "$hosts" >"$tmp"
  else
    awk -v repl="$repl" '
      BEGIN{ins=0}
      $0 ~ /^[[:space:]]*127\.0\.0\.1[[:space:]]+/ && ins==0 {
        print; print repl; ins=1; next
      }
      {print}
      END{ if(ins==0) print repl }
    ' "$hosts" >"$tmp"
  fi
  mv "$tmp" "$hosts"
  log "更新 /etc/hosts: $repl"
}

cloudinit_present() {
  [ -d /etc/cloud ] && command -v cloud-init >/dev/null 2>&1
}

cloudinit_set_preserve_hostname() {
  f="/etc/cloud/cloud.cfg.d/99-hostname-preserve.cfg"
  if [ -f "$f" ]; then
    if grep -Eq '^[[:space:]]*preserve_hostname[[:space:]]*:[[:space:]]*true' "$f"; then
      log "cloud-init: preserve_hostname 已启用 ($f)"
      return 0
    fi
    backup_file "$f"
  fi
  cat >"$f" <<'EOF'
# 由 set-hostname.sh 写入：避免 cloud-init 重启覆盖手动 hostname
preserve_hostname: true
EOF
  log "cloud-init: 写入 preserve_hostname: true ($f)"
}

cloudinit_patch_hosts_templates() {
  short="$1"
  fqdn="${2:-}"
  dir="/etc/cloud/templates"
  [ -d "$dir" ] || { log "cloud-init: 未找到 $dir，跳过模板修改"; return 0; }

  if [ -n "$fqdn" ]; then
    repl="127.0.1.1 $fqdn $short"
  else
    repl="127.0.1.1 $short"
  fi

  found=0
  for tpl in "$dir"/hosts.*.tmpl; do
    [ -f "$tpl" ] || continue
    found=1
    backup_file "$tpl"
    tmp="${tpl}.tmp"
    awk -v repl="$repl" '
      BEGIN{done=0}
      $0 ~ /^[[:space:]]*127\.0\.1\.1[[:space:]]+/ && done==0 {print repl; done=1; next}
      {print}
    ' "$tpl" >"$tmp"
    mv "$tmp" "$tpl"
    log "cloud-init: 修改模板 $tpl -> $repl"
  done
  [ "$found" -eq 1 ] || log "cloud-init: 未找到 hosts.*.tmpl，跳过模板修改"
}

usage() {
  cat >&2 <<'EOF'
用法：
  set-hostname.sh <NEW_HOSTNAME> [选项]

选项：
  --fqdn <FQDN>         /etc/hosts 写入 FQDN（127.0.1.1 FQDN HOST）
  --no-hosts            不修改 /etc/hosts
  --cloud-init          若存在 cloud-init：preserve_hostname + 修改 hosts 模板
  --dry-run             仅展示动作，不写入
  -h, --help            帮助
EOF
}

DRY_RUN=0
NO_HOSTS=0
DO_CLOUDINIT=0
NEW=""
FQDN=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-hosts) NO_HOSTS=1; shift ;;
    --cloud-init) DO_CLOUDINIT=1; shift ;;
    --fqdn) [ $# -ge 2 ] || die "--fqdn 需要参数"; FQDN="$2"; shift 2 ;;
    --) shift; break ;;
    -* ) die "未知选项: $1" ;;
    *  ) if [ -z "$NEW" ]; then NEW="$1"; shift; else die "多余参数: $1"; fi ;;
  esac
done

[ -n "$NEW" ] || { usage; die "缺少 NEW_HOSTNAME"; }

NEW="$(printf '%s' "$NEW" | tr 'A-Z' 'a-z')"
validate_hostname "$NEW" || die "主机名不合法: $NEW"

SHORT="${NEW%%.*}"

if [ -n "$FQDN" ]; then
  FQDN="$(printf '%s' "$FQDN" | tr 'A-Z' 'a-z')"
  validate_hostname "$FQDN" || die "FQDN 不合法: $FQDN"
fi

need_root

log "目标主机名: short=$SHORT${FQDN:+, fqdn=$FQDN}"

if [ "$DRY_RUN" -eq 1 ]; then
  log "[dry-run] 将设置运行时 hostname，并写入 /etc/hostname（如存在）"
  [ "$NO_HOSTS" -eq 0 ] && log "[dry-run] 将更新 /etc/hosts 的 127.0.1.1 行" || log "[dry-run] 跳过 /etc/hosts"
  [ "$DO_CLOUDINIT" -eq 1 ] && log "[dry-run] 将处理 cloud-init：preserve_hostname + 修改 hosts 模板"
  exit 0
fi

set_runtime_hostname "$SHORT"
set_persistent_hostname "$SHORT"

[ "$NO_HOSTS" -eq 0 ] && update_hosts_file "$SHORT" "$FQDN"

if [ "$DO_CLOUDINIT" -eq 1 ] && cloudinit_present; then
  cloudinit_set_preserve_hostname
  cloudinit_patch_hosts_templates "$SHORT" "$FQDN"
fi

log "完成。验证："
if command -v hostnamectl >/dev/null 2>&1; then hostnamectl | sed 's/^/  /'; fi
if command -v hostname >/dev/null 2>&1; then log "  hostname: $(hostname)"; fi
grep -E '^[[:space:]]*127\.0\.1\.1[[:space:]]+' /etc/hosts 2>/dev/null | sed 's/^/  /' || true
