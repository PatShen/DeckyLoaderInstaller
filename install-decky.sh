#!/usr/bin/env bash
# =============================================================================
# install-decky.sh — 在 Steam Deck 桌面模式离线安装 / 升级 / 卸载 Decky Loader
#
# 特点：
#   * 只使用放在脚本同目录（或 --binary 指定）的 PluginLoader 二进制，
#     不联网、不需要 jq、不访问 GitHub API。
#   * 行为对齐官方 decky-installer 的 install_release.sh / uninstall.sh：
#     同样的目录（~/homebrew）、同样的 systemd 服务（plugin_loader.service）、
#     同样的 CEF 调试标记文件、同样的 SELinux/所有权收尾。
#
# 用法：
#   bash install-decky.sh [选项]
#
# 注意：本脚本会写入 /etc/systemd/system/plugin_loader.service 并以 root 运行服务。
# 请在 Konsole 中运行。需要 sudo 权限；Deck 默认没有密码时，可选临时把密码设为
# "Decky!"（与官方安装器做法一致），脚本结束时自动删除。
# =============================================================================
set -u -o pipefail

if [ -z "${BASH_VERSION:-}" ]; then
  echo "[x] 请使用 bash 运行本脚本: bash install-decky.sh" >&2
  exit 1
fi

SCRIPT_VERSION="1.0.0"
SYSTEM_UNIT="/etc/systemd/system/plugin_loader.service"

# ---- 选项 ----
BIN_ARG=""
DECKY_VERSION=""
CHECK_ONLY=0
ASSUME_YES=0
ALLOW_TEMP_PASS=0
RESTART_STEAM=0
DO_UNINSTALL=0
DO_WIPE=0
SHOW_HELP=0

# ---- 运行期状态 ----
TARGET_USER=""
TARGET_HOME=""
HOMEBREW=""
SERVICES=""
STEAM_DIR=""
FLATPAK_STEAM_DIR=""
BINARY_PATH=""
BIN_SHA256=""
EXISTING=0
ERRORS=""
ERROR_COUNT=0

SUDO_MODE=""       # root | cached | password
SUDO_PASS=""
TEMP_PASS=0        # 1 = 本脚本临时设置了 deck 的密码，退出时要删除

# ---------------------------------------------------------------------------
# 输出辅助
# ---------------------------------------------------------------------------
info() { printf '[*] %s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
ok()   { printf '[OK] %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
err()  { printf '[x] %s\n' "$*" >&2; }

die() {
  local code="$1"
  shift
  err "$*"
  exit "$code"
}

add_error() {
  ERROR_COUNT=$((ERROR_COUNT + 1))
  ERRORS="${ERRORS}  - $1
"
  err "$1"
}

add_warn() {
  warn "$1"
}

ask_yes_no() {  # $1=提示语 $2=默认值(y/n)
  local prompt="$1" def="${2:-n}" ans
  if [ "$ASSUME_YES" -eq 1 ]; then
    return 0
  fi
  if [ ! -t 0 ]; then
    return 1
  fi
  printf '%s' "$prompt" >&2
  if ! read -r ans; then
    return 1
  fi
  ans="$(printf '%s' "$ans" | tr '[:upper:]' '[:lower:]')"
  case "$ans" in
    "")
      if [ "$def" = "y" ]; then return 0; else return 1; fi
      ;;
    y|yes|是|好|确认)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 用法
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
install-decky.sh — Steam Deck 桌面模式离线安装 / 升级 / 卸载 Decky Loader

用法:
  bash install-decky.sh [选项]
  bash install-decky.sh --check
  bash install-decky.sh --uninstall [--wipe]

安装相关:
  --binary PATH          指定 PluginLoader 文件（默认在脚本同目录查找）
  --version vX.Y.Z       可选，记录版本号到 ~/homebrew/services/.loader.version
  --check                只做预检，不修改任何东西
  --yes                  所有确认自动回答“是”（不含自动设置临时密码）
  --temp-password        deck 没有 sudo 密码时，允许自动临时设为 Decky!（结束删除）
  --restart-steam        安装完成后直接关闭 Steam（默认会询问）

卸载相关:
  --uninstall            停止并删除服务、二进制、CEF 标记（保留插件与配置）
  --wipe                 与 --uninstall 一起使用：额外删除 ~/homebrew（含插件配置）

其他:
  -h, --help             显示本帮助

示例:
  cd ~/decky-install
  bash install-decky.sh --check     # 先看环境是否就绪
  bash install-decky.sh             # 正式安装 / 升级
  bash install-decky.sh --uninstall # 卸载

说明:
  * Decky Loader 自带插件商店（Store），不需要另外安装商店。
  * 安装完成后需完全重启 Steam（或重启机器）并切回游戏模式，
    在快捷菜单(QAM)中才会出现 Decky 图标。
  * 插件商店浏览/下载插件需要联网；本脚本本身不需要联网。
EOF
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help)
        SHOW_HELP=1
        shift
        ;;
      --check)
        CHECK_ONLY=1
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --temp-password)
        ALLOW_TEMP_PASS=1
        shift
        ;;
      --restart-steam)
        RESTART_STEAM=1
        shift
        ;;
      --uninstall)
        DO_UNINSTALL=1
        shift
        ;;
      --wipe)
        DO_WIPE=1
        shift
        ;;
      --binary)
        if [ $# -lt 2 ]; then
          usage >&2
          die 1 "选项 --binary 需要一个路径"
        fi
        BIN_ARG="$2"
        shift 2
        ;;
      --binary=*)
        BIN_ARG="${1#--binary=}"
        shift
        ;;
      --version)
        if [ $# -lt 2 ]; then
          usage >&2
          die 1 "选项 --version 需要一个值，例如 --version v3.3.1"
        fi
        DECKY_VERSION="$2"
        shift 2
        ;;
      --version=*)
        DECKY_VERSION="${1#--version=}"
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        usage >&2
        die 1 "未知选项: $1"
        ;;
      *)
        if [ -z "$BIN_ARG" ]; then
          BIN_ARG="$1"
        else
          usage >&2
          die 1 "多余的参数: $1"
        fi
        shift
        ;;
    esac
  done

  if [ "$DO_WIPE" -eq 1 ] && [ "$DO_UNINSTALL" -eq 0 ]; then
    die 1 "--wipe 只能与 --uninstall 一起使用"
  fi
}

# ---------------------------------------------------------------------------
# 目标用户 / 家目录
# ---------------------------------------------------------------------------
resolve_target() {
  if [ "$EUID" -eq 0 ]; then
    TARGET_USER="${SUDO_USER:-}"
    if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
      TARGET_USER="deck"
    fi
  else
    TARGET_USER="$(id -un 2>/dev/null || true)"
  fi

  if [ -z "$TARGET_USER" ]; then
    add_error "无法确定目标用户（请用 deck 用户运行，而不是 root）"
    return 0
  fi

  if ! id "$TARGET_USER" >/dev/null 2>&1; then
    add_error "目标用户不存在: $TARGET_USER"
    return 0
  fi

  if command -v getent >/dev/null 2>&1; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)"
  fi
  if [ -z "${TARGET_HOME:-}" ] && [ "$TARGET_USER" = "$(id -un 2>/dev/null)" ]; then
    TARGET_HOME="$HOME"
  fi

  if [ -z "${TARGET_HOME:-}" ]; then
    add_error "无法确定 $TARGET_USER 的家目录（系统缺少 getent？）"
    return 0
  fi

  case "$TARGET_HOME" in
    /)
      add_error "家目录异常: /"
      TARGET_HOME=""
      return 0
      ;;
    *[[:space:]]*)
      add_error "家目录包含空格（${TARGET_HOME}），本脚本暂不支持"
      TARGET_HOME=""
      return 0
      ;;
  esac

  if [ ! -d "$TARGET_HOME" ]; then
    add_error "家目录不存在: $TARGET_HOME"
    TARGET_HOME=""
    return 0
  fi

  HOMEBREW="$TARGET_HOME/homebrew"
  SERVICES="$HOMEBREW/services"
  ok "目标用户: $TARGET_USER ($TARGET_HOME)"
}

# ---------------------------------------------------------------------------
# 预检
# ---------------------------------------------------------------------------
check_system() {
  local os arch
  os="$(uname -s 2>/dev/null || echo unknown)"
  arch="$(uname -m 2>/dev/null || echo unknown)"
  if [ "$os" != "Linux" ]; then
    add_error "本脚本仅支持 Linux/SteamOS，当前系统是: ${os}（请在 Steam Deck 桌面模式运行）"
    return 0
  fi
  case "$arch" in
    x86_64|amd64)
      ok "系统: $os / $arch"
      ;;
    aarch64|arm64)
      add_warn "当前架构是 ${arch}；Steam Deck 是 x86_64，请确认下载的是 PluginLoader（不是 PluginLoader-arm64）"
      ;;
    *)
      add_warn "未测试的架构: $arch"
      ;;
  esac
}

check_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    add_error "找不到 systemctl，无法注册开机服务（请确认在 SteamOS 桌面模式）"
    return 0
  fi
  if [ ! -d /run/systemd/system ]; then
    add_error "systemd 未在运行（/run/systemd/system 不存在），无法安装"
    return 0
  fi
  ok "systemd 运行正常"
}

check_encoding() {
  if [ ! -f "$0" ]; then
    return 0
  fi
  if LC_ALL=C grep -q "$(printf '\r')" "$0" 2>/dev/null; then
    add_error "脚本里有 Windows 换行符(CRLF)，请执行: sed -i 's/\r$//' \"$0\""
  else
    ok "脚本换行格式正常(LF)"
  fi
}

check_steam() {
  [ -n "$TARGET_HOME" ] || return 0
  STEAM_DIR="$TARGET_HOME/.steam/steam"
  FLATPAK_STEAM_DIR="$TARGET_HOME/.var/app/com.valvesoftware.Steam/data/Steam"

  if [ -d "$STEAM_DIR" ]; then
    ok "Steam 目录: $STEAM_DIR"
  elif [ "$DO_UNINSTALL" -eq 1 ]; then
    add_warn "未找到 Steam 目录: ${STEAM_DIR}（卸载会继续）"
  elif [ -d "$TARGET_HOME/.local/share/Steam" ]; then
    add_error "找到 Steam 数据目录，但缺少 ${STEAM_DIR}；请先在桌面模式启动一次 Steam，再运行本脚本"
  else
    add_error "未找到 ${STEAM_DIR}；请先在桌面模式启动一次 Steam，再运行本脚本"
  fi

  if [ -d "$FLATPAK_STEAM_DIR" ]; then
    ok "检测到 Flatpak 版 Steam 目录"
  fi
}

port_listeners() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | awk 'NR>1 {print $4}' | grep -E ':(1337|8080)$' || true
  elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk 'NR>2 {print $4}' | grep -E ':(1337|8080)$' || true
  fi
}

check_ports() {
  local busy
  if [ "$DO_UNINSTALL" -eq 1 ]; then
    return 0
  fi
  busy="$(port_listeners)"
  if [ -n "$busy" ]; then
    if [ "$EXISTING" -eq 1 ]; then
      add_warn "端口 1337/8080 已被占用：已有 Decky 在运行则属正常；否则请检查 Syncthing 等程序（建议改用 8384）"
    else
      add_warn "端口 1337/8080 已被占用（Decky 需要它们）: $(printf '%s' "$busy" | tr '\n' ' ')"
      add_warn "如果是 Syncthing 等程序，请把它的端口改掉（例如 Syncthing 改到 8384）"
    fi
  else
    ok "端口 1337/8080 未被占用"
  fi
}

check_existing() {
  EXISTING=0
  if [ -f "$SYSTEM_UNIT" ]; then
    EXISTING=1
  fi
  if [ -n "$SERVICES" ] && [ -f "$SERVICES/PluginLoader" ]; then
    EXISTING=1
  fi
  if [ "$EXISTING" -eq 1 ]; then
    add_warn "检测到已有 Decky 安装：将停止旧服务、备份旧二进制后覆盖（保留插件与配置）"
  elif [ "$DO_UNINSTALL" -eq 1 ]; then
    ok "未检测到已有安装（仍会清理可能残留的文件）"
  else
    ok "未检测到已有安装（全新安装）"
  fi
}

check_sudo_status() {
  [ -n "$TARGET_USER" ] || return 0
  if [ "$EUID" -eq 0 ]; then
    ok "sudo: 当前已以 root 运行"
    return 0
  fi
  if sudo -n true 2>/dev/null; then
    ok "sudo: 可用（已缓存凭据或 NOPASSWD）"
    return 0
  fi
  local st
  st="$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{print $2}')"
  case "${st:-}" in
    NP)
      add_warn "sudo: $TARGET_USER 未设置密码，安装时会询问是否临时设为 Decky!（结束自动删除）"
      ;;
    P|L)
      ok "sudo: 需要输入密码"
      ;;
    *)
      add_warn "sudo: 无法读取密码状态（passwd -S 不可用），安装时会要求输入密码"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# 查找并校验 PluginLoader
# ---------------------------------------------------------------------------
find_binary() {
  if [ -n "$BIN_ARG" ]; then
    if [ ! -f "$BIN_ARG" ]; then
      add_error "指定的文件不存在: $BIN_ARG"
      return 0
    fi
    BINARY_PATH="$BIN_ARG"
    ok "使用指定文件: $BINARY_PATH"
    return 0
  fi

  local dir n f
  dir="$(cd "$(dirname "$0")" 2>/dev/null && pwd)" || dir="$PWD"

  for n in PluginLoader PluginLoader-x86_64 pluginloader plugin_loader PluginLoader.bin; do
    if [ -f "$dir/$n" ]; then
      BINARY_PATH="$dir/$n"
      break
    fi
  done

  if [ -z "$BINARY_PATH" ]; then
    for f in "$dir"/PluginLoader*; do
      [ -e "$f" ] || continue
      case "$f" in
        *.sh|*.desktop|*.md|*.txt|*.zip) continue ;;
      esac
      BINARY_PATH="$f"
      break
    done
  fi

  if [ -z "$BINARY_PATH" ]; then
    add_error "在脚本目录下找不到 PluginLoader：$dir"
    add_error "请从 decky-loader Releases 下载名为 PluginLoader 的文件放到脚本同目录，或用 --binary 指定路径"
  else
    ok "找到二进制: $BINARY_PATH"
  fi
}

file_magic() {
  LC_ALL=C od -An -c -N4 "$1" 2>/dev/null | tr -d ' \n'
}

first_bytes() {
  head -c 4 "$1" 2>/dev/null || true
}

validate_binary() {
  local size magic m1 head4

  if [ ! -f "$BINARY_PATH" ]; then
    add_error "文件不存在: $BINARY_PATH"
    return 0
  fi
  if [ ! -r "$BINARY_PATH" ]; then
    add_error "文件不可读: $BINARY_PATH"
    return 0
  fi

  size="$(wc -c < "$BINARY_PATH" 2>/dev/null | tr -d '[:space:]')"
  case "${size:-}" in
    ''|*[!0-9]*)
      add_error "无法读取文件大小: $BINARY_PATH"
      return 0
      ;;
  esac
  if [ "$size" -lt 5000000 ]; then
    add_warn "文件只有 $size 字节（正常约 35 MB），可能下载不完整"
  fi

  magic="$(file_magic "$BINARY_PATH")"
  if [ "$magic" != "177ELF" ]; then
    head4="$(first_bytes "$BINARY_PATH")"
    case "$head4" in
      '<!DO'|'<htm'|'<?xm')
        add_error "这个文件是网页而不是程序（可能下载到了 404/登录页），请重新下载裸二进制"
        ;;
      'PK'*)
        add_error "这是一个 zip 压缩包；请解压后使用其中的 PluginLoader，或直接下载裸二进制"
        ;;
      *)
        add_error "不是合法的 ELF 可执行文件: $BINARY_PATH"
        ;;
    esac
    return 0
  fi

  m1="$(LC_ALL=C od -An -t u1 -j18 -N2 "$BINARY_PATH" 2>/dev/null | awk '{print $1}')"
  case "${m1:-}" in
    62)
      ok "二进制校验通过: x86-64 ELF, $size 字节"
      ;;
    183)
      add_error "这是 arm64 版本（PluginLoader-arm64）；Steam Deck 需要 x86-64 的 PluginLoader"
      ;;
    *)
      add_warn "未识别的 ELF 架构 (e_machine=${m1:-未知})，仍会尝试安装"
      ;;
  esac

  if command -v sha256sum >/dev/null 2>&1; then
    BIN_SHA256="$(sha256sum "$BINARY_PATH" 2>/dev/null | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    BIN_SHA256="$(shasum -a 256 "$BINARY_PATH" 2>/dev/null | awk '{print $1}')"
  fi
  if [ -n "$BIN_SHA256" ]; then
    info "SHA256: ${BIN_SHA256}（可对照 Release 页面记录的 digest）"
  fi
}

# ---------------------------------------------------------------------------
# 提权
# ---------------------------------------------------------------------------
run_sudo() {
  # 注意：不要用 run_sudo 执行需要从 stdin 读数据的命令（密码占用 stdin）。
  case "$SUDO_MODE" in
    root)
      "$@"
      ;;
    cached)
      sudo -n -- "$@"
      ;;
    password)
      printf '%s\n' "$SUDO_PASS" | sudo -S -p '' -- "$@"
      ;;
    *)
      die 4 "内部错误：sudo 尚未初始化"
      ;;
  esac
}

cleanup_temp_pass() {
  if [ "$TEMP_PASS" -ne 1 ]; then
    return 0
  fi
  printf '%s\n' "$SUDO_PASS" | sudo -S -p '' passwd -d "$TARGET_USER" >/dev/null 2>&1 || true
  local st
  st="$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{print $2}')"
  if [ "${st:-}" = "NP" ]; then
    ok "已删除临时密码，$TARGET_USER 恢复为无密码状态"
  else
    warn "临时密码可能没有删除！请执行下面任一操作恢复："
    warn "  1) sudo passwd -d $TARGET_USER"
    warn "  2) 若 sudo 不可用，先运行 passwd 设一个新密码，再执行 sudo passwd -d $TARGET_USER"
  fi
  TEMP_PASS=0
}

acquire_sudo() {
  if [ "$EUID" -eq 0 ]; then
    SUDO_MODE="root"
    return 0
  fi

  if sudo -n true 2>/dev/null; then
    SUDO_MODE="cached"
    ok "sudo 可用（凭据已缓存或 NOPASSWD）"
    return 0
  fi

  local st out i
  st="$(passwd -S "$TARGET_USER" 2>/dev/null | awk '{print $2}')"

  if [ "${st:-}" = "NP" ]; then
    warn "检测到 $TARGET_USER 尚未设置密码，而安装 root 服务需要 sudo 密码。"
    if [ "$ALLOW_TEMP_PASS" -eq 0 ]; then
      if ! ask_yes_no "是否临时把密码设置为 Decky!（安装结束会自动删除）？[y/N] " n; then
        die 4 "已取消。请先在 Konsole 运行 passwd 设置密码后重试（或加 --temp-password）"
      fi
    fi

    # 先登记，保证异常退出时也能清理
    TEMP_PASS=1
    SUDO_PASS='Decky!'
    out="$( { yes 'Decky!' 2>/dev/null || true; } | passwd "$TARGET_USER" 2>&1 )"
    if [ $? -ne 0 ]; then
      TEMP_PASS=0
      SUDO_PASS=""
      err "设置临时密码失败: $out"
      die 4 "请手动运行 passwd 设置密码后重试"
    fi
    if ! printf '%s\n' "$SUDO_PASS" | sudo -S -k -p '' true 2>/dev/null; then
      die 4 "临时密码无法通过 sudo 验证，请手动运行 passwd 设置密码后重试"
    fi
    SUDO_MODE="password"
    ok "已临时设置密码并获得 sudo 权限（脚本结束时会删除临时密码）"
    return 0
  fi

  for i in 1 2 3; do
    if [ ! -t 0 ]; then
      die 4 "需要输入 sudo 密码，但没有可用终端。请在 Konsole 中运行本脚本。"
    fi
    printf '请输入 %s 的 sudo 密码: ' "$TARGET_USER" >&2
    if ! read -r -s SUDO_PASS; then
      echo >&2
      die 4 "读取密码失败"
    fi
    echo >&2
    if printf '%s\n' "$SUDO_PASS" | sudo -S -k -p '' true 2>/dev/null; then
      SUDO_MODE="password"
      ok "sudo 验证成功"
      return 0
    fi
    warn "密码不正确，请重试（$i/3）"
  done
  die 4 "sudo 密码验证失败，已退出"
}

on_exit() {
  local rc=$?
  cleanup_temp_pass
  exit "$rc"
}

# ---------------------------------------------------------------------------
# 文件 / 服务操作
# ---------------------------------------------------------------------------
copy_file() {  # $1=src $2=dst $3=mode
  local src="$1" dst="$2" mode="$3"
  if command -v install >/dev/null 2>&1; then
    run_sudo install -m "$mode" "$src" "$dst"
  else
    run_sudo cp -f "$src" "$dst" && run_sudo chmod "$mode" "$dst"
  fi
}

stop_user_unit() {
  if [ "$EUID" -eq 0 ]; then
    local uid
    uid="$(id -u "$TARGET_USER" 2>/dev/null || true)"
    if [ -n "$uid" ]; then
      sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user stop plugin_loader >/dev/null 2>&1 || true
      sudo -u "$TARGET_USER" XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user disable plugin_loader >/dev/null 2>&1 || true
    fi
  else
    systemctl --user stop plugin_loader >/dev/null 2>&1 || true
    systemctl --user disable plugin_loader >/dev/null 2>&1 || true
  fi
  if [ -n "$TARGET_HOME" ]; then
    run_sudo rm -f "$TARGET_HOME/.config/systemd/user/plugin_loader.service" >/dev/null 2>&1 || true
  fi
}

ensure_marker() {
  local dir="$1" file
  if [ -z "$dir" ]; then
    warn "Steam 目录未知，跳过 CEF 标记"
    return 0
  fi
  if [ ! -d "$dir" ]; then
    warn "Steam 目录不存在: $dir"
    return 0
  fi
  file="$dir/.cef-enable-remote-debugging"
  if ! run_sudo touch "$file"; then
    warn "无法创建 $file"
    return 0
  fi
  run_sudo chown "$TARGET_USER:$TARGET_USER" "$file" >/dev/null 2>&1 || true
  ok "已创建 $file"
}

write_unit() {
  local tmp
  tmp="$(mktemp 2>/dev/null || true)"
  if [ -z "$tmp" ]; then
    die 5 "无法创建临时文件（mktemp 失败）"
  fi

  cat > "$tmp" <<EOF
[Unit]
Description=SteamDeck Plugin Loader
After=network.target

[Service]
Type=simple
User=root
Restart=always
KillMode=process
TimeoutStopSec=15
ExecStart=$SERVICES/PluginLoader
WorkingDirectory=$SERVICES
Environment=UNPRIVILEGED_PATH=$HOMEBREW
Environment=PRIVILEGED_PATH=$HOMEBREW
Environment=LOG_LEVEL=INFO

[Install]
WantedBy=multi-user.target
EOF

  if ! copy_file "$tmp" "$SYSTEM_UNIT" 0644; then
    rm -f "$tmp"
    die 5 "写入 $SYSTEM_UNIT 失败"
  fi
  rm -f "$tmp"
  run_sudo chown root:root "$SYSTEM_UNIT" >/dev/null 2>&1 || warn "无法把 $SYSTEM_UNIT 属主设为 root"
  run_sudo chmod 0644 "$SYSTEM_UNIT" >/dev/null 2>&1 || true
  ok "已写入 systemd 服务: $SYSTEM_UNIT"
}

show_service_debug() {
  run_sudo systemctl status --no-pager -l plugin_loader >&2 2>&1 || true
  run_sudo journalctl -u plugin_loader -n 80 --no-pager >&2 2>&1 || true
}

verify_install() {
  local i token=""

  step "校验服务状态"
  for ((i = 0; i < 20; i++)); do
    if run_sudo systemctl is-active --quiet plugin_loader; then
      break
    fi
    sleep 1
  done
  if ! run_sudo systemctl is-active --quiet plugin_loader; then
    err "plugin_loader 服务没有处于 active 状态"
    show_service_debug
    die 6 "服务启动失败，请把上面的日志反馈给脚本作者"
  fi
  ok "服务 plugin_loader 运行中"

  if command -v curl >/dev/null 2>&1; then
    for ((i = 0; i < 20; i++)); do
      token="$(curl -fsS -m 2 http://127.0.0.1:1337/auth/token 2>/dev/null || true)"
      [ -n "$token" ] && break
      sleep 1
    done
    if [ -z "$token" ]; then
      warn "后端 127.0.0.1:1337 暂未响应（可能仍在启动）"
      show_service_debug
      die 6 "后端接口未响应，请查看上面的日志"
    fi
    ok "后端接口正常（127.0.0.1:1337）"
  else
    warn "找不到 curl，跳过接口检查"
  fi
}

finalize_install() {
  step "修正权限"
  if ! run_sudo chown -R "$TARGET_USER:$TARGET_USER" "$HOMEBREW" >/dev/null 2>&1; then
    warn "无法调整 $HOMEBREW 的所有权（插件可能写入失败）；请手动执行:"
    warn "  sudo chown -R $TARGET_USER:$TARGET_USER $HOMEBREW"
  else
    ok "~/homebrew 归属: $TARGET_USER"
  fi
  run_sudo chown root:root "$SERVICES/PluginLoader" >/dev/null 2>&1 || true
  run_sudo chmod 0755 "$SERVICES/PluginLoader" >/dev/null 2>&1 || true

  if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
    if run_sudo chcon -t bin_t "$SERVICES/PluginLoader" >/dev/null 2>&1; then
      ok "SELinux: 已设置 bin_t"
    else
      warn "SELinux: chcon 失败（可能不影响运行）"
    fi
  fi
}

install_decky() {
  local stamp out_tmp

  step "停止旧服务"
  run_sudo systemctl stop plugin_loader >/dev/null 2>&1 || true
  run_sudo systemctl disable plugin_loader >/dev/null 2>&1 || true
  stop_user_unit
  ok "旧服务已停止（如存在）"

  step "准备目录 $HOMEBREW"
  if ! run_sudo mkdir -p "$HOMEBREW/plugins" "$SERVICES"; then
    die 5 "创建 $HOMEBREW 失败"
  fi
  run_sudo chown "$TARGET_USER:$TARGET_USER" "$HOMEBREW" "$HOMEBREW/plugins" "$SERVICES" >/dev/null 2>&1 || \
    warn "无法调整 ~/homebrew 所有权（继续）"
  ok "目录已就绪"

  if [ -f "$SERVICES/PluginLoader" ]; then
    stamp="$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)"
    if run_sudo cp -p "$SERVICES/PluginLoader" "$HOMEBREW/PluginLoader.bak.$stamp" 2>/dev/null; then
      ok "旧二进制已备份: $HOMEBREW/PluginLoader.bak.$stamp"
    else
      warn "备份旧二进制失败（继续）"
    fi
  fi

  step "安装 PluginLoader 二进制"
  if ! run_sudo rm -f "$SERVICES/PluginLoader"; then
    die 5 "无法删除旧二进制（Text file busy？请先确认服务已停止）"
  fi
  if ! copy_file "$BINARY_PATH" "$SERVICES/PluginLoader" 0755; then
    die 5 "安装二进制失败"
  fi
  ok "已安装: $SERVICES/PluginLoader"

  if [ -n "$DECKY_VERSION" ]; then
    out_tmp="$(mktemp 2>/dev/null || true)"
    if [ -n "$out_tmp" ]; then
      printf '%s\n' "$DECKY_VERSION" > "$out_tmp"
      if run_sudo cp -f "$out_tmp" "$SERVICES/.loader.version"; then
        run_sudo chmod 0644 "$SERVICES/.loader.version" >/dev/null 2>&1 || true
      else
        warn "写入 .loader.version 失败（不影响运行）"
      fi
      rm -f "$out_tmp"
    fi
  fi

  step "创建 Steam CEF 调试标记"
  ensure_marker "$STEAM_DIR"
  if [ -n "$FLATPAK_STEAM_DIR" ] && [ -d "$FLATPAK_STEAM_DIR" ]; then
    ensure_marker "$FLATPAK_STEAM_DIR"
  fi

  step "注册 systemd 服务"
  write_unit
  if ! run_sudo systemctl daemon-reload; then
    die 5 "systemctl daemon-reload 失败"
  fi
  if ! run_sudo systemctl enable --now plugin_loader; then
    show_service_debug
    die 5 "systemctl enable --now plugin_loader 失败"
  fi
  ok "服务已启用并启动（开机自启）"
}

maybe_restart_steam() {
  if ! command -v pgrep >/dev/null 2>&1; then
    return 0
  fi
  if ! pgrep -f steamwebhelper >/dev/null 2>&1; then
    if [ "$RESTART_STEAM" -eq 1 ]; then
      warn "Steam 当前未运行；直接打开 Steam 即可，Decky 会在启动时注入"
    fi
    return 0
  fi
  if [ "$EUID" -eq 0 ]; then
    warn "当前以 root 运行，请手动完全退出并重新打开 Steam"
    return 0
  fi
  if [ "$RESTART_STEAM" -eq 0 ]; then
    if ! ask_yes_no "检测到 Steam 正在运行。现在关闭 Steam（之后请手动重新打开）？[y/N] " n; then
      warn "请稍后手动完全退出并重新打开 Steam，Decky 才会注入"
      return 0
    fi
  fi
  if ! command -v steam >/dev/null 2>&1; then
    warn "找不到 steam 命令，请手动退出 Steam"
    return 0
  fi
  info "正在关闭 Steam ..."
  steam -shutdown >/dev/null 2>&1 || true
  local i
  for ((i = 0; i < 20; i++)); do
    pgrep -f steamwebhelper >/dev/null 2>&1 || break
    sleep 1
  done
  if pgrep -f steamwebhelper >/dev/null 2>&1; then
    warn "Steam 仍在运行，请手动完全退出 Steam"
  else
    ok "Steam 已关闭，请重新打开 Steam（或切回游戏模式）"
  fi
}

print_summary() {
  cat <<EOF

================ 安装完成 ================
 Decky Loader 已安装并设置为开机自启

   二进制 : $SERVICES/PluginLoader
   服务   : $SYSTEM_UNIT
   版本号 : ${DECKY_VERSION:-未指定（不影响运行）}
   SHA256 : ${BIN_SHA256:-未知}

 下一步:
   1) 完全退出并重新打开 Steam（或重启机器）
   2) 切回游戏模式（桌面上的 "Return to Gaming Mode"）
   3) 用 "..." 键打开快捷菜单(QAM)，左侧会出现 Decky 图标
      插件商店是 Decky 里的 "Store" 标签页，浏览/下载插件需要联网

 常用命令:
   查看状态 : systemctl status plugin_loader
   查看日志 : journalctl -u plugin_loader -b --no-pager -n 100
   升级     : bash $(basename "$0")
   卸载     : bash $(basename "$0") --uninstall [--wipe]
=========================================
EOF
}

# ---------------------------------------------------------------------------
# 卸载
# ---------------------------------------------------------------------------
uninstall_decky() {
  if [ -z "$HOMEBREW" ] || [ "$HOMEBREW" = "/" ]; then
    die 5 "路径校验失败，拒绝执行删除操作"
  fi

  step "停止并移除服务"
  run_sudo systemctl disable --now plugin_loader >/dev/null 2>&1 || true
  stop_user_unit
  if [ -f "$SYSTEM_UNIT" ]; then
    run_sudo rm -f "$SYSTEM_UNIT" || warn "删除 $SYSTEM_UNIT 失败"
  fi
  run_sudo systemctl daemon-reload >/dev/null 2>&1 || true
  ok "服务已移除"

  step "删除二进制与标记"
  if [ -f "$SERVICES/PluginLoader" ]; then
    run_sudo rm -f "$SERVICES/PluginLoader" || warn "删除 PluginLoader 失败"
  fi
  run_sudo rm -f "$SERVICES/.loader.version" >/dev/null 2>&1 || true
  run_sudo rm -rf /tmp/plugin_loader >/dev/null 2>&1 || true

  if [ -n "$STEAM_DIR" ] && [ -f "$STEAM_DIR/.cef-enable-remote-debugging" ]; then
    run_sudo rm -f "$STEAM_DIR/.cef-enable-remote-debugging" || warn "删除 CEF 标记失败"
  fi
  if [ -n "$FLATPAK_STEAM_DIR" ] && [ -f "$FLATPAK_STEAM_DIR/.cef-enable-remote-debugging" ]; then
    run_sudo rm -f "$FLATPAK_STEAM_DIR/.cef-enable-remote-debugging" || warn "删除 Flatpak CEF 标记失败"
  fi
  ok "已删除二进制与 CEF 标记"

  if [ "$DO_WIPE" -eq 1 ]; then
    if [ "$ASSUME_YES" -eq 0 ]; then
      if ! ask_yes_no "确认删除整个 ${HOMEBREW}（含所有插件与配置）？[y/N] " n; then
        warn "已跳过删除 ${HOMEBREW}（服务与二进制已卸载）"
        return 0
      fi
    fi
    if run_sudo rm -rf "$HOMEBREW"; then
      ok "已删除 $HOMEBREW"
    else
      die 5 "删除 $HOMEBREW 失败"
    fi
  else
    ok "已保留 ${HOMEBREW}（插件与配置）"
  fi

  ok "卸载完成。请重启 Steam 以移除注入。"
}

print_check_result() {
  printf '\n'
  if [ "$ERROR_COUNT" -gt 0 ]; then
    printf '[x] 预检发现 %s 个问题：\n%s' "$ERROR_COUNT" "$ERRORS"
    printf '[x] 结论: 暂时不能安装，请按上面的提示修正后重试。\n'
    exit 2
  fi
  ok "结论: 预检通过，可以安装。"
  exit 0
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  if [ "$SHOW_HELP" -eq 1 ]; then
    usage
    exit 0
  fi

  trap on_exit EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  info "install-decky.sh v$SCRIPT_VERSION"

  resolve_target
  check_system
  check_systemd
  check_encoding
  check_steam
  check_existing
  check_ports

  if [ "$DO_UNINSTALL" -eq 1 ]; then
    if [ "$ERROR_COUNT" -gt 0 ]; then
      printf '%s' "$ERRORS" >&2
      die 2 "预检失败，已中止卸载"
    fi
    acquire_sudo
    uninstall_decky
    cleanup_temp_pass
    exit 0
  fi

  check_sudo_status
  find_binary
  if [ -n "$BINARY_PATH" ]; then
    validate_binary
  fi

  if [ "$CHECK_ONLY" -eq 1 ]; then
    print_check_result
  fi

  if [ "$ERROR_COUNT" -gt 0 ]; then
    printf '%s' "$ERRORS" >&2
    die 2 "预检失败，请按上面的提示修正后重试"
  fi

  info "将写入 $SYSTEM_UNIT 并以 root 运行 plugin_loader 服务"
  if [ "$EXISTING" -eq 1 ] && [ "$ASSUME_YES" -eq 0 ]; then
    if ! ask_yes_no "检测到已有安装，继续升级/覆盖？[Y/n] " y; then
      info "已取消。"
      exit 0
    fi
  fi

  acquire_sudo
  install_decky
  verify_install
  finalize_install
  cleanup_temp_pass
  print_summary
  maybe_restart_steam

  exit 0
}

main "$@"
