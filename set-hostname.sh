#!/bin/sh
# set-hostname (POSIX sh) — 适合 curl | sh 执行的通用改主机名脚本
# 用法：
#   curl -fsSL https://example.com/set-hostname.sh | sudo sh -s -- clawdbot
#   curl -fsSL https://example.com/set-hostname.sh | sudo sh -s -- clawdbot --fqdn clawdbot.example.com --cloud-init
#
# 选项：
#   --fqdn <FQDN>        /etc/hosts 写入 FQDN（IP FQDN HOST）
#   --no-hosts           不修改 /etc/hosts
#   --cloud-init         若存在 cloud-init：preserve_hostname + 修补 hosts 模板
#   --force-hosts        非 Debian 也强制写入一条本机映射（默认更保守）
#   --dry-run            只打印将执行的动作，不落盘
#   -h, --help           帮助

set -eu

log(){ printf '%s\n' "$*" >&2; }
die(){ log "ERROR: $*"; exit 1; }
ts(){ date +%Y%m%d-%H%M%S; }

need_root(){
  [ "$(id -u)" = "0" ] || die "需要 root 权限（请用 sudo）"
}

backup_file(){
  f="$1"
  [ -f "$f" ] || return 0
  b="${f}.bak.$(ts)"
  if cp -a "$f" "$b" 2>/dev/null; then :; else cp -p "$f" "$b"; fi
  log "备份: $f -> $b"
}

# 允许：a-z0-9- 和 '.'（FQDN），段首尾不得为'-'，每段<=63，总长<=253
validate_hostname(){
  hn="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  [ -n "$hn" ] || return 1
  [ "${#hn}" -le 253 ] || return 1
  printf '%s' "$hn" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$' || return 1
  echo "$hn" | tr '.' '\n' | while IFS= read -r seg; do
    [ -n "$seg" ] || exit 1
    [ "${#seg}" -le 63 ] || exit 1
  done || return 1
  return 0
}

os_family_linux_debian(){
  [ -f /etc/debian_version ] && return 0
  if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release || true
    case "${ID:-}" in
      debian|ubuntu|linuxmint|pop) return 0 ;;
    esac
  fi
  return 1
}

get_current_hostname(){
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl --static 2>/dev/null || hostname 2>/dev/null || true
  else
    hostname 2>/dev/null || true
  fi
}

set_hostname_linux(){
  short="$1"
  if command -v hostnamectl >/dev/null 2>&1; then
    hostnamectl set-hostname "$short"
  elif command -v hostname >/dev/null 2>&1; then
    hostname "$short" || true
  fi

  if [ -e /etc/hostname ]; then
    backup_file /etc/hostname
    printf '%s\n' "$short" > /etc/hostname
    log "写入 /etc/hostname: $short"
  fi
}

# 尽量保守更新 /etc/hosts：
# 1) 有 127.0.1.1 行就替换该行
# 2) 否则若出现旧 hostname token，就替换 token
# 3) 否则：Debian 系插入 127.0.1.1；其他系统默认不写（除非 --force-hosts）
update_hosts_linux(){
  short="$1"
  fqdn="${2:-}"
  force="${3:-0}"

  hosts="/etc/hosts"
  [ -f "$hosts" ] || die "/etc/hosts 不存在"
  backup_file "$hosts"

  old="$(get_current_hostname | tr 'A-Z' 'a-z' | head -n1 | tr -d '\r\n')"
  [ -n "$old" ] || old="localhost"

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
    mv "$tmp" "$hosts"
    log "更新 /etc/hosts(替换127.0.1.1): $repl"
    return 0
  fi

  # 替换旧 hostname token（更通用）
  if [ "$old" != "$short" ] && grep -Eq "(^|[[:space:]])$old([[:space:]]|$)" "$hosts"; then
    awk -v o="$old" -v n="$short" '
      {
        for(i=1;i<=NF;i++){
          if($i==o) $i=n
        }
        print
      }
    ' "$hosts" >"$tmp"
    mv "$tmp" "$hosts"
    log "更新 /etc/hosts(替换token): $old -> $short"
    return 0
  fi

  # 没找到可替换点：Debian 系插入；其他系统除非强制否则跳过
  if os_family_linux_debian || [ "$force" -eq 1 ]; then
    awk -v repl="$repl" '
      BEGIN{ins=0}
      $0 ~ /^[[:space:]]*127\.0\.0\.1[[:space:]]+/ && ins==0 {print; print repl; ins=1; next}
      {print}
      END{ if(ins==0) print repl }
    ' "$hosts" >"$tmp"
    mv "$tmp" "$hosts"
    log "更新 /etc/hosts(插入): $repl"
  else
    rm -f "$tmp"
    log "提示: 非 Debian 系且未发现旧 hostname 于 /etc/hosts，默认不改 hosts（可用 --force-hosts）"
  fi
}

cloudinit_present(){
  [ -d /etc/cloud ] && command -v cloud-init >/dev/null 2>&1
}

cloudinit_set_preserve_hostname(){
  f="/etc/cloud/cloud.cfg.d/99-hostname-preserve.cfg"
  if [ -f "$f" ]; then
    if grep -Eq '^[[:space:]]*preserve_hostname[[:space:]]*:[[:space:]]*true' "$f"; then
      log "cloud-init: preserve_hostname 已启用 ($f)"
      return 0
    fi
    backup_file "$f"
  fi
  cat >"$f" <<'EOF'
# written by set-hostname.sh: prevent cloud-init from overriding hostname on reboot
preserve_hostname: true
EOF
  log "cloud-init: 写入 preserve_hostname: true ($f)"
}

cloudinit_patch_hosts_templates(){
  short="$1"
  fqdn="${2:-}"
  dir="/etc/cloud/templates"
  [ -d "$dir" ] || { log "cloud-init: 未找到 $dir，跳过模板修补"; return 0; }

  if [ -n "$fqdn" ]; then
    repl="127.0.1.1 $fqdn $short"
  else
    repl="127.0.1.1 $short"
  fi

  found=0
  for tpl in "$dir"/hosts.*.tmpl; do
    [ -f "$tpl" ] || continue
    # 仅在模板存在 127.0.1.1 行时修补（更保守）
    grep -Eq '^[[:space:]]*127\.0\.1\.1[[:space:]]+' "$tpl" || continue
    found=1
    backup_file "$tpl"
    tmp="${tpl}.tmp"
    awk -v repl="$repl" '
      BEGIN{done=0}
      $0 ~ /^[[:space:]]*127\.0\.1\.1[[:space:]]+/ && done==0 {print repl; done=1; next}
      {print}
    ' "$tpl" >"$tmp"
    mv "$tmp" "$tpl"
    log "cloud-init: 修补模板 $tpl -> $repl"
  done
  [ "$found" -eq 1 ] || log "cloud-init: 未发现可修补的 hosts 模板(127.0.1.1)，跳过"
}

usage(){
  cat >&2 <<'EOF'
用法：
  set-hostname.sh <NEW_HOSTNAME> [选项]

选项：
  --fqdn <FQDN>        /etc/hosts 写入 FQDN（IP FQDN HOST）
  --no-hosts           不修改 /etc/hosts
  --cloud-init         若存在 cloud-init：preserve_hostname + 修补 hosts 模板
  --force-hosts        非 Debian 也强制写入一条本机映射
  --dry-run            仅展示动作，不写入
  -h, --help           帮助
EOF
}

DRY_RUN=0
NO_HOSTS=0
DO_CLOUDINIT=0
FORCE_HOSTS=0
NEW=""
FQDN=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --no-hosts) NO_HOSTS=1; shift ;;
    --cloud-init) DO_CLOUDINIT=1; shift ;;
    --force-hosts) FORCE_HOSTS=1; shift ;;
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
  log "[dry-run] 将设置 Linux hostname，并写入 /etc/hostname（如存在）"
  [ "$NO_HOSTS" -eq 0 ] && log "[dry-run] 将更新 /etc/hosts" || log "[dry-run] 跳过 /etc/hosts"
  [ "$DO_CLOUDINIT" -eq 1 ] && log "[dry-run] 将处理 cloud-init"
  exit 0
fi

UNAME_S="$(uname -s 2>/dev/null || echo unknown)"
case "$UNAME_S" in
  Linux)
    set_hostname_linux "$SHORT"
    [ "$NO_HOSTS" -eq 0 ] && update_hosts_linux "$SHORT" "$FQDN" "$FORCE_HOSTS"
    if [ "$DO_CLOUDINIT" -eq 1 ] && cloudinit_present; then
      cloudinit_set_preserve_hostname
      cloudinit_patch_hosts_templates "$SHORT" "$FQDN"
    fi
    ;;
  *)
    die "当前脚本主要支持 Linux。检测到系统: $UNAME_S"
    ;;
esac

log "完成。快速验证："
if command -v hostnamectl >/dev/null 2>&1; then hostnamectl | sed 's/^/  /' || true; fi
if command -v hostname >/dev/null 2>&1; then log "  hostname: $(hostname)"; fi
[ -f /etc/hosts ] && grep -E '^[[:space:]]*127\.(0|1)\.0\.1[[:space:]]+' /etc/hosts | sed 's/^/  /' || true
