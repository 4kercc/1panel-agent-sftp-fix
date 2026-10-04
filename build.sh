#!/usr/bin/env bash
# 从源码编译「打了 SFTP 并发写补丁」的 1panel-agent
#
# 用法:  ./build.sh [1Panel 版本 tag]        默认 v2.3.2
#        env GO_VERSION=... ./build.sh      仅用于提示所需 Go 版本
#
# 产物:  ./build/1panel-agent   (linux/amd64)
#        ./build/1panel-agent.sha256
#
# 说明:  agent 是纯 Go 且不内嵌前端，编译不需要 Node/前端（只有 core 需要）。
set -euo pipefail

VERSION="${1:-v2.3.2}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="${WORK:-$SCRIPT_DIR/.build}"
OUT="$SCRIPT_DIR/build"
SRC_FILE_REL="agent/utils/cloud_storage/client/sftp.go"

command -v git >/dev/null 2>&1 || { echo "错误: 找不到 git" >&2; exit 1; }
command -v go  >/dev/null 2>&1 || {
  echo "错误: 找不到 go。请先安装 Go（1Panel v2.3.2 需要 >= 1.26.6，见 agent/go.mod）" >&2
  echo "      https://go.dev/dl/" >&2
  exit 1
}
echo "==> $(go version)"

rm -rf "$WORK"
mkdir -p "$WORK" "$OUT"

echo "==> 克隆 1Panel $VERSION ..."
git clone --depth 1 --branch "$VERSION" https://github.com/1Panel-dev/1Panel.git "$WORK/src"

echo "==> 应用补丁 ..."
if git -C "$WORK/src" apply "$SCRIPT_DIR/patch/0001-sftp-concurrent-writes.patch" 2>/dev/null; then
  echo "    已应用 patch/0001-sftp-concurrent-writes.patch"
else
  echo "    patch 与 $VERSION 不完全匹配，改用按函数定位替换 ..."
  cat > "$WORK/patch.py" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text(encoding="utf-8")
if "UseConcurrentWrites" in s:
    print("    源码已是补丁状态，跳过")
    sys.exit(0)
m = re.search(
    r"(func \(s sftpClient\) Upload\(ctx context\.Context, src, target string\) \(bool, error\) \{)"
    r"(.*?)"
    r"(\n\}\n)",
    s, re.S)
if not m:
    sys.exit("错误: 找不到 Upload 函数，请手动应用 patch/ 内的补丁")
body = m.group(2)
body = body.replace("sftp.NewClient(sshClient)",
                    "sftp.NewClient(sshClient, sftp.UseConcurrentWrites(true))", 1)
body = body.replace(
    "if _, err := io.Copy(dstFile, srcFile); err != nil {",
    "// ReadFrom 使用 pkg/sftp 的管线化写路径；io.Copy 会走 os.File.WriteTo，\n"
    "\t// 每 ~32KB 同步等待确认，吞吐被限制为 packetSize/RTT。\n"
    "\twritten, err := dstFile.ReadFrom(srcFile)\n"
    "\tif err != nil {\n"
    "\t\t_ = dstFile.Truncate(written)\n", 1)
if "ReadFrom(srcFile)" not in body:
    sys.exit("错误: Upload 函数结构与预期不符，请手动应用 patch/ 内的补丁")
p.write_text(s[:m.start(2)] + body + s[m.end(2):], encoding="utf-8")
print("    已按函数定位完成替换")
PY
  python3 "$WORK/patch.py" "$WORK/src/$SRC_FILE_REL"
fi

grep -q "UseConcurrentWrites" "$WORK/src/$SRC_FILE_REL" \
  || { echo "错误: 补丁未生效" >&2; exit 1; }

echo "==> 编译 (GOOS=linux GOARCH=amd64 CGO_ENABLED=0) ..."
(
  cd "$WORK/src/agent"
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags '-s -w' -o "$OUT/1panel-agent" ./cmd/server
)

echo
echo "==> 完成: $OUT/1panel-agent"
ls -la "$OUT/1panel-agent"
( cd "$OUT" && sha256sum 1panel-agent | tee 1panel-agent.sha256 )
echo
echo "替换步骤见 README.md「用法一」的第 3-5 步。"
