#!/usr/bin/env bash
#
# 1Panel Agent SFTP 加速补丁 —— 一键安装 / 回滚
#
# 安装（自动识别面板版本，从 GitHub Release 下载预编译的 agent 并替换）：
#   curl -fsSL https://raw.githubusercontent.com/4kercc/1panel-agent-sftp-fix/main/install.sh | bash
#
# 先看看会做什么（不实际修改系统）：
#   curl -fsSL .../install.sh | bash -s -- --dry-run
#
# 回滚到替换前的二进制：
#   curl -fsSL .../install.sh | bash -s -- --rollback
#
# 指定版本（默认自动读取 1pctl version）：
#   curl -fsSL .../install.sh | bash -s -- --version v2.3.2
#
# 说明：本脚本只替换 agent 二进制，并在替换前备份、启动失败时自动回滚。
#
set -euo pipefail

REPO="4kercc/1panel-agent-sftp-fix"
AGENT_BIN="/usr/local/bin/1panel-agent"
SERVICE="1panel-agent"
BACKUP_GLOB="/root/1panel-agent.backup-*"

DRY_RUN=0
DO_ROLLBACK=0
FORCE_VERSION=""

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: install.sh [选项]

  (无参数)              检测版本 → 下载 → 校验 → 备份 → 替换 → 重启
  --dry-run             只打印将要执行的操作，不修改系统
  --rollback            恢复到最近一次替换前的备份
  --version <vX.Y.Z>    手动指定要安装的面板版本（默认自动检测）
  -h, --help            显示本帮助
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --rollback) DO_ROLLBACK=1 ;;
    --version) [ $# -ge 2 ] || die "--version 需要一个版本号，例如 --version v2.3.2"; FORCE_VERSION="$2"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) warn "未知参数: $1"; usage; exit 1 ;;
  esac
  shift
done

# 在 dry-run 下只打印命令
run() {
  if [ "$DRY_RUN" = 1 ]; then printf '    [dry-run] %s\n' "$*"; else eval "$@"; fi
}

[ "$(id -u)" = "0" ] || die "请用 root 运行（需要替换 /usr/local/bin 下的二进制并重启 systemd 服务）"

# ---------------------------------------------------------------- 回滚
if [ "$DO_ROLLBACK" = 1 ]; then
  LATEST="$(ls -1t $BACKUP_GLOB 2>/dev/null | head -1 || true)"
  [ -n "$LATEST" ] || die "没找到备份文件（$BACKUP_GLOB），无法回滚"
  log "回滚到: $LATEST"
  run "systemctl stop $SERVICE" || true
  run "install -m755 '$LATEST' $AGENT_BIN"
  run "systemctl start $SERVICE"
  if [ "$DRY_RUN" = 0 ]; then
    sleep 8
    systemctl is-active --quiet "$SERVICE" \
      && log "✅ 回滚完成，当前版本文件: $LATEST" \
      || die "回滚后服务未启动，请检查 journalctl -u $SERVICE"
  fi
  exit 0
fi

# ---------------------------------------------------------------- 环境检测
command -v 1pctl >/dev/null 2>&1 || die "找不到 1pctl，这台机器看起来不是 1Panel 主机"
[ -f "$AGENT_BIN" ] || die "找不到 $AGENT_BIN"

DETECTED="$(1pctl version 2>/dev/null | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
[ -n "$DETECTED" ] || die "无法识别 1Panel 版本（1pctl version 没有输出 vX.Y.Z）"
VERSION="${FORCE_VERSION:-$DETECTED}"

ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] || die "仓库里的预编译二进制只支持 x86_64，当前架构是 $ARCH。
       请改用源码编译：https://github.com/$REPO#用法二自己编译任意版本"

log "1Panel 版本: $VERSION   架构: $ARCH"
[ "$VERSION" != "$DETECTED" ] && warn "你手动指定了 $VERSION，而面板检测到的是 $DETECTED —— 版本不一致会导致 agent 启动异常，请确认！"

# ---------------------------------------------------------------- 下载
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE="https://github.com/$REPO/releases/download/$VERSION"

log "从 GitHub Release 下载 ($VERSION) ..."
if ! curl -fsSL -o "$TMP/1panel-agent" "$BASE/1panel-agent"; then
  die "下载失败: $BASE/1panel-agent
       本仓库只提供编译过的若干版本。$VERSION 没有预编译产物时，请自行编译：
       https://github.com/$REPO#用法二自己编译任意版本"
fi
curl -fsSL -o "$TMP/1panel-agent.sha256" "$BASE/1panel-agent.sha256" \
  || die "下载校验文件失败: $BASE/1panel-agent.sha256"

# ---------------------------------------------------------------- 校验
log "校验 sha256 ..."
( cd "$TMP" && sha256sum -c 1panel-agent.sha256 ) || die "校验失败！下载的文件可能损坏或被篡改，已中止"

NEW_SHA="$(sha256sum "$TMP/1panel-agent" | cut -d' ' -f1)"
CUR_SHA="$(sha256sum "$AGENT_BIN" 2>/dev/null | cut -d' ' -f1 || echo '')"
log "当前 agent sha256: ${CUR_SHA:0:16}…"
log "待安装 sha256    : ${NEW_SHA:0:16}…"

if [ "$CUR_SHA" = "$NEW_SHA" ]; then
  log "当前已经就是这个版本，无需替换。退出。"
  exit 0
fi

# ---------------------------------------------------------------- 替换
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="/root/1panel-agent.backup-$STAMP"

log "备份当前二进制 → $BACKUP"
run "cp -a '$AGENT_BIN' '$BACKUP'"
log "停止 $SERVICE ..."
run "systemctl stop $SERVICE" || true
log "替换二进制 ..."
run "install -m755 '$TMP/1panel-agent' '$AGENT_BIN'"
log "启动 $SERVICE ..."
run "systemctl start $SERVICE"

if [ "$DRY_RUN" = 1 ]; then
  log "dry-run 结束，未做任何修改。"
  exit 0
fi

sleep 8
if systemctl is-active --quiet "$SERVICE"; then
  log "✅ 替换成功"
  1pctl status 2>&1 | grep -E 'Running|OK' | sed 's/^/    /' || true
  echo
  log "回滚命令: bash <(curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh) --rollback"
  log "备份文件: $BACKUP"
else
  printf '\033[1;31m服务启动失败，正在自动回滚...\033[0m\n'
  systemctl stop "$SERVICE" 2>/dev/null || true
  install -m755 "$BACKUP" "$AGENT_BIN"
  systemctl start "$SERVICE" || true
  sleep 5
  die "已回滚到替换前的二进制（当前服务状态: $(systemctl is-active "$SERVICE" 2>&1)）。
       请把 journalctl -u $SERVICE 的输出反馈到 https://github.com/$REPO/issues"
fi
