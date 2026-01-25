#!/usr/bin/env sh
set -eu

DEFAULT_KEYS_URL="https://github.com/akuma-real.keys"

OVERWRITE=0
DISABLE_PASSWORD=0
TARGET_USER=""
SRC_GITHUB_USER=""
SRC_URL=""
SRC_FILE=""
SRC_INLINE_KEYS=""

log() { printf '%s\n' "$*"; }
warn() { printf '警告: %s\n' "$*" >&2; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

mktemp_file() {
  if need_cmd mktemp; then
    mktemp
  else
    # 尽量避免冲突
    echo "/tmp/sshkey_setup.$$.$(date +%s)"
  fi
}

is_root() {
  if need_cmd id; then
    [ "$(id -u)" = "0" ]
  else
    # 没有 id 的极端环境：默认非 root
    return 1
  fi
}

detect_pkg_mgr() {
  if need_cmd apt-get; then echo "apt"
  elif need_cmd dnf; then echo "dnf"
  elif need_cmd yum; then echo "yum"
  elif need_cmd zypper; then echo "zypper"
  elif need_cmd pacman; then echo "pacman"
  elif need_cmd apk; then echo "apk"
  elif need_cmd emerge; then echo "emerge"
  else echo "unknown"
  fi
}

pkg_install() {
  # $@ packages
  pm="$(detect_pkg_mgr)"
  case "$pm" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    dnf)
      dnf install -y "$@" ;;
    yum)
      yum install -y "$@" ;;
    zypper)
      zypper --non-interactive install "$@" ;;
    pacman)
      pacman -Sy --noconfirm "$@" ;;
    apk)
      apk update >/dev/null 2>&1 || true
      apk add --no-cache "$@" ;;
    emerge)
      emerge --quiet "$@" ;;
    *)
      die "无法识别包管理器，无法自动安装依赖：$*"
      ;;
  esac
}

ensure_fetcher() {
  if need_cmd curl || need_cmd wget; then
    return 0
  fi
  if ! is_root; then
    die "缺少 curl/wget，且当前非 root，无法自动安装。请先安装 curl 或 wget。"
  fi
  log "未检测到 curl/wget，尝试自动安装 curl..."
  pkg_install curl || die "安装 curl 失败，请手动安装 curl 或 wget。"
}

fetch_to_file() {
  # $1 url, $2 out_file
  url="$1"
  out="$2"
  ensure_fetcher
  if need_cmd curl; then
    curl -fsSL "$url" > "$out"
  else
    wget -qO- "$url" > "$out"
  fi
}

ensure_openssh_server() {
  # 仅在 root 且系统看起来没有 sshd 时尝试安装
  is_root || return 0

  if [ -x /usr/sbin/sshd ] || [ -x /sbin/sshd ] || need_cmd sshd; then
    return 0
  fi

  pm="$(detect_pkg_mgr)"
  log "未检测到 sshd，尝试安装 OpenSSH Server..."
  case "$pm" in
    apt) pkg_install openssh-server ;;
    dnf|yum) pkg_install openssh-server ;;
    zypper) pkg_install openssh ;;
    pacman) pkg_install openssh ;;
    apk) pkg_install openssh ;;
    emerge) pkg_install net-misc/openssh ;;
    *) warn "无法自动安装 openssh-server（未知包管理器）。跳过安装。" ;;
  esac
}

try_enable_start_sshd() {
  # 不强依赖启动成功；失败不退出
  is_root || return 0

  if need_cmd systemctl; then
    systemctl enable --now sshd >/dev/null 2>&1 || true
    systemctl enable --now ssh  >/dev/null 2>&1 || true
    return 0
  fi

  if need_cmd rc-service; then
    rc-update add sshd default >/dev/null 2>&1 || true
    rc-service sshd restart >/dev/null 2>&1 || rc-service sshd start >/dev/null 2>&1 || true
    return 0
  fi

  if need_cmd service; then
    service sshd restart >/dev/null 2>&1 || service ssh restart >/dev/null 2>&1 || true
    return 0
  fi
}

get_home_dir() {
  # $1 user
  u="$1"
  if need_cmd getent; then
    h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6 || true)"
    [ -n "$h" ] && { printf '%s' "$h"; return 0; }
  fi
  # fallback: /etc/passwd
  h="$(grep "^$u:" /etc/passwd 2>/dev/null | cut -d: -f6 || true)"
  [ -n "$h" ] && { printf '%s' "$h"; return 0; }
  return 1
}

user_exists() {
  u="$1"
  if need_cmd getent; then
    getent passwd "$u" >/dev/null 2>&1 && return 0
  fi
  grep "^$u:" /etc/passwd >/dev/null 2>&1
}

primary_group() {
  u="$1"
  if need_cmd id; then
    id -gn "$u" 2>/dev/null || echo "$u"
  else
    echo "$u"
  fi
}

filter_keys() {
  # $1 raw_file, $2 out_file
  raw="$1"
  out="$2"
  # 去 CRLF，过滤常见公钥前缀，去空行，去重
  tr -d '\r' < "$raw" \
    | awk '
        /^[[:space:]]*$/ {next}
        $0 ~ /^(ssh-|ecdsa-|sk-)/ && index($0, " ")>0 {print}
      ' \
    | awk '!seen[$0]++' > "$out"

  [ -s "$out" ] || die "未获得任何有效公钥（源内容为空或格式不正确）。"
}

append_keys() {
  # $1 keys_file, $2 authorized_keys
  keys="$1"
  auth="$2"

  # overwrite 模式：先备份再清空
  if [ "$OVERWRITE" -eq 1 ] && [ -f "$auth" ]; then
    bak="${auth}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$auth" "$bak" 2>/dev/null || true
    : > "$auth"
  fi

  touch "$auth"

  added=0
  while IFS= read -r k || [ -n "$k" ]; do
    [ -n "$k" ] || continue
    if grep -Fqx "$k" "$auth" 2>/dev/null; then
      :
    else
      printf '%s\n' "$k" >> "$auth"
      added=$((added+1))
    fi
  done < "$keys"

  printf '%s' "$added"
}

set_sshd_global_option() {
  # 仅修改 “Match” 之前的全局段，避免破坏 Match 块
  # $1 key, $2 value, $3 file
  k="$1"; v="$2"; f="$3"
  tmp="$(mktemp_file)"

  awk -v k="$k" -v v="$v" '
    function ltrim(s){ sub(/^[ \t]+/, "", s); return s }
    function is_match_line(s){
      s=ltrim(s)
      return (tolower(substr(s,1,5))=="match")
    }
    BEGIN{ inmatch=0; inserted=0 }
    {
      line=$0
      if (!inmatch && is_match_line(line)) {
        if (!inserted) { print k " " v; inserted=1 }
        inmatch=1
        print $0
        next
      }

      if (!inmatch) {
        t=ltrim(line)
        if (substr(t,1,1)=="#") { t=ltrim(substr(t,2)) }
        split(t, a, /[ \t]+/)
        if (tolower(a[1])==tolower(k)) {
          # 丢弃旧值
          next
        }
      }

      print $0
    }
    END{
      if (!inserted) print k " " v
    }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

harden_sshd_password_auth() {
  is_root || die "禁用密码登录需要 root 权限。"

  cfg="/etc/ssh/sshd_config"
  [ -f "$cfg" ] || die "未找到 $cfg"

  # 尽量兼容不同版本关键字
  set_sshd_global_option "PubkeyAuthentication" "yes" "$cfg"
  set_sshd_global_option "PasswordAuthentication" "no" "$cfg"
  set_sshd_global_option "KbdInteractiveAuthentication" "no" "$cfg"
  set_sshd_global_option "ChallengeResponseAuthentication" "no" "$cfg"

  # 尝试重载/重启
  if need_cmd systemctl; then
    systemctl reload sshd >/dev/null 2>&1 || systemctl restart sshd >/dev/null 2>&1 || true
    systemctl reload ssh  >/dev/null 2>&1 || systemctl restart ssh  >/dev/null 2>&1 || true
  elif need_cmd rc-service; then
    rc-service sshd restart >/dev/null 2>&1 || true
  elif need_cmd service; then
    service sshd restart >/dev/null 2>&1 || service ssh restart >/dev/null 2>&1 || true
  fi
}

usage() {
  cat <<EOF
用法:
  sh $0 [选项]

默认行为:
  - 不带任何参数时，从 ${DEFAULT_KEYS_URL} 拉取公钥并写入目标用户的 authorized_keys。

选项:
  -g <GitHub用户名>   从 https://github.com/<用户名>.keys 获取公钥
  -u <URL>           从指定 URL 获取公钥
  -f <文件路径>      从本地文件读取公钥
  -k <公钥字符串>    直接传入公钥（可多次 -k）
  -t <用户名>        指定写入到哪个用户（默认：root 下优先 \$SUDO_USER，否则当前用户）
  -o                覆盖 authorized_keys（会先备份为 .bak.时间戳）
  -d                禁用密码登录（会修改 /etc/ssh/sshd_config；务必确认你已能用密钥登录）
  -h                显示帮助

示例:
  sudo sh $0
  sudo sh $0 -g akuma-real -t root
  sudo sh $0 -u https://github.com/akuma-real.keys -t ubuntu
  sudo sh $0 -k "ssh-ed25519 AAAA..." -t root
  sudo sh $0 -g akuma-real -o
  sudo sh $0 -g akuma-real -d

EOF
}

# --- 参数解析 ---
SRC_COUNT=0
while getopts "g:u:f:k:t:odh" opt; do
  case "$opt" in
    g) SRC_GITHUB_USER="$OPTARG"; SRC_COUNT=$((SRC_COUNT+1)) ;;
    u) SRC_URL="$OPTARG"; SRC_COUNT=$((SRC_COUNT+1)) ;;
    f) SRC_FILE="$OPTARG"; SRC_COUNT=$((SRC_COUNT+1)) ;;
    k) SRC_INLINE_KEYS="${SRC_INLINE_KEYS}${OPTARG}\n"; SRC_COUNT=$((SRC_COUNT+1)) ;;
    t) TARGET_USER="$OPTARG" ;;
    o) OVERWRITE=1 ;;
    d) DISABLE_PASSWORD=1 ;;
    h) usage; exit 0 ;;
    *) usage; exit 1 ;;
  esac
done
shift $((OPTIND-1))

# 允许多个 -k，但不允许混用多种来源（-g/-u/-f/-k）
if [ "$SRC_COUNT" -gt 1 ]; then
  # 特例：多个 -k 仍算一种来源，这里 SRC_COUNT 会被累加；修正：仅当存在非 -k 的同时又有 -k 才报错
  nonk=0
  [ -n "$SRC_GITHUB_USER" ] && nonk=$((nonk+1))
  [ -n "$SRC_URL" ] && nonk=$((nonk+1))
  [ -n "$SRC_FILE" ] && nonk=$((nonk+1))
  if [ "$nonk" -ge 1 ] && [ -n "$SRC_INLINE_KEYS" ]; then
    die "公钥来源参数请不要混用（-g/-u/-f/-k 选其一；-k 可多次）。"
  fi
  if [ "$nonk" -ge 2 ]; then
    die "公钥来源参数请不要混用（-g/-u/-f 选其一；-k 可多次）。"
  fi
fi

# --- 目标用户默认值 ---
if [ -z "$TARGET_USER" ]; then
  if is_root && [ "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    TARGET_USER="$SUDO_USER"
  else
    TARGET_USER="$(id -un 2>/dev/null || echo root)"
  fi
fi

user_exists "$TARGET_USER" || die "用户不存在：$TARGET_USER"

HOME_DIR="$(get_home_dir "$TARGET_USER" || true)"
[ -n "$HOME_DIR" ] || die "无法获取用户家目录：$TARGET_USER"

SSH_DIR="${HOME_DIR}/.ssh"
AUTH_FILE="${SSH_DIR}/authorized_keys"

RAW_KEYS="$(mktemp_file)"
KEYS_FILE="$(mktemp_file)"
cleanup() { rm -f "$RAW_KEYS" "$KEYS_FILE" 2>/dev/null || true; }
trap cleanup EXIT

# --- 获取公钥 ---
if [ -n "$SRC_GITHUB_USER" ]; then
  fetch_to_file "https://github.com/${SRC_GITHUB_USER}.keys" "$RAW_KEYS"
elif [ -n "$SRC_URL" ]; then
  fetch_to_file "$SRC_URL" "$RAW_KEYS"
elif [ -n "$SRC_FILE" ]; then
  [ -f "$SRC_FILE" ] || die "文件不存在：$SRC_FILE"
  cat "$SRC_FILE" > "$RAW_KEYS"
elif [ -n "$SRC_INLINE_KEYS" ]; then
  # shellcheck disable=SC2059
  printf "$SRC_INLINE_KEYS" > "$RAW_KEYS"
else
  fetch_to_file "$DEFAULT_KEYS_URL" "$RAW_KEYS"
fi

filter_keys "$RAW_KEYS" "$KEYS_FILE"

# --- 可选：安装/启动 SSH 服务 ---
ensure_openssh_server
try_enable_start_sshd

# --- 写入 authorized_keys ---
umask 077
mkdir -p "$SSH_DIR"
touch "$AUTH_FILE"

chmod 700 "$SSH_DIR"
chmod 600 "$AUTH_FILE"

added="$(append_keys "$KEYS_FILE" "$AUTH_FILE")"

# chown（仅 root）
if is_root; then
  grp="$(primary_group "$TARGET_USER")"
  chown "$TARGET_USER:$grp" "$SSH_DIR" "$AUTH_FILE" 2>/dev/null || true
  # SELinux 环境尽量修复上下文
  if need_cmd restorecon; then
    restorecon -RF "$SSH_DIR" >/dev/null 2>&1 || true
  fi
fi

# --- 可选：禁用密码登录 ---
if [ "$DISABLE_PASSWORD" -eq 1 ]; then
  warn "你启用了 -d（禁用密码登录）。务必确认你已能用密钥正常登录，否则可能把自己锁在服务器外。"
  harden_sshd_password_auth
fi

log "完成：用户=$TARGET_USER"
log "authorized_keys: $AUTH_FILE"
log "新增公钥条目数: $added"
