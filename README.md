# 1Panel Agent SFTP 加速补丁版

修复 **1Panel 网站备份上传 SFTP 极慢**的问题：同一台目标机，从 **0.25 MB/s 提升到 16–30 MB/s（约 100 倍）**。

- 上游 PR：**https://github.com/1Panel-dev/1Panel/pull/13976**
- 本仓库提供：**已编译好的 `1panel-agent`（v2.3.2 / linux amd64）** + 一键编译脚本 + 补丁源码

---

## 问题现象

用 1Panel 的「网站备份」上传到 SFTP 远端时，速度只有 **0.2–0.4 MB/s**，几百 MB 要传半小时（实测 439MB 用了 29 分钟）。

但网络本身完全没问题：

- 服务器出口带宽实测 **40+ MB/s**
- 到目标机 RTT 35–68ms、**0% 丢包**
- 传输中的 TCP：`bytes_retrans 0/29`、`send-q 0`、cwnd 远未打满
- 系统自带的 `sftp` 传同一个文件到同一台目标：**19 MB/s**

也就是说：**慢的不是 SFTP、不是链路、不是目标服务器，而是 1Panel 内置的 SFTP 客户端实现。**

## 根因

`agent/utils/cloud_storage/client/sftp.go` 的上传逻辑：

```go
if _, err := io.Copy(dstFile, srcFile); err != nil {
```

`srcFile` 是 `*os.File`，它实现了 `io.WriterTo`，所以 `io.Copy` 会走 `os.File.WriteTo` 这条分支 —— **每读约 32KB 就同步写一次并等待服务端确认**。吞吐因此被锁死为 `包大小 / RTT`，与链路容量无关。

而 `pkg/sftp`（1Panel 已有的依赖）本身提供了管线化写路径：`File.ReadFrom` + `UseConcurrentWrites`，并发上限 `MaxConcurrentRequestsPerFile`（默认 64）。这里没有启用。

### 对照实测（同一个 96MiB 文件、同一台目标机、RTT 68ms）

| 客户端 | 协议 | 耗时 | 速率 |
| --- | --- | --- | --- |
| 1Panel（原版） | SFTP | 6分40秒 | **0.25 MB/s** |
| **1Panel（本补丁）** | SFTP（管线化） | **约 6 秒** | **16 MB/s** |
| rclone | SFTP | 6 秒 | 16 MB/s |
| OpenSSH `sftp` | SFTP | 5 秒 | 19 MB/s |

### 实际备份任务效果

| | 修改前 | 修改后 |
| --- | --- | --- |
| 单站 439MB 上传 | 约 29 分钟 | **约 17 秒** |
| 三站点合计 ~950MB | 约 2 小时 40 分 | **2 分 04 秒** |

上传后的备份包全部通过 `gzip -t` 流式校验，无空洞、无损坏。

## 补丁做了什么

```go
// 1) 上传时启用 pkg/sftp 的并发写
client, err := sftp.NewClient(sshClient, sftp.UseConcurrentWrites(true))

// 2) 用管线化的 ReadFrom 替代 io.Copy（失败时截断到实际写入长度，避免留下空洞）
written, err := dstFile.ReadFrom(srcFile)
if err != nil {
    _ = dstFile.Truncate(written)
    ...
}
```

只动了 SFTP **上传**这一处；下载路径未改（下载侧源对象是 `*sftp.File`，其 `WriteTo` 默认已用并发读）。

---

## ⚠️ 版本必须匹配

`1panel-agent` 与面板版本是绑定的（启动时会做数据库结构迁移）。
**`bin/` 里的二进制只适用于 1Panel `v2.3.2`（linux/amd64）**，其他版本请用下面的 `build.sh` 自行编译，不要跨版本替换。

## 用法一：一键安装（推荐）

脚本会自动识别面板版本 → 从 Release 下载对应二进制 → 校验 sha256 → 备份 → 替换 → 重启，**启动失败会自动回滚**。

```bash
# 先看看会做什么（不修改系统）
curl -fsSL https://raw.githubusercontent.com/4kercc/1panel-agent-sftp-fix/main/install.sh | bash -s -- --dry-run

# 正式安装
curl -fsSL https://raw.githubusercontent.com/4kercc/1panel-agent-sftp-fix/main/install.sh | bash
```

回滚（恢复到替换前的二进制）：

```bash
curl -fsSL https://raw.githubusercontent.com/4kercc/1panel-agent-sftp-fix/main/install.sh | bash -s -- --rollback
```

> 脚本只支持 x86_64。如果你的版本还没有预编译产物，它会明确提示你改用「用法三」自行编译。

## 用法二：手动替换（适用于 1Panel v2.3.2）

预编译二进制放在 [Releases](https://github.com/4kercc/1panel-agent-sftp-fix/releases) 里（这样仓库本身不用背 80MB 的大文件）。

```bash
# 1) 先确认版本和架构
1pctl version        # 应输出 version: v2.3.2
uname -m             # 应为 x86_64

# 2) 下载并校验完整性
curl -fLO https://github.com/4kercc/1panel-agent-sftp-fix/releases/download/v2.3.2/1panel-agent
curl -fLO https://github.com/4kercc/1panel-agent-sftp-fix/releases/download/v2.3.2/1panel-agent.sha256
sha256sum -c 1panel-agent.sha256        # 应输出 1panel-agent: OK

# 3) 备份官方原版（回滚用）
cp -a /usr/local/bin/1panel-agent /root/1panel-agent.orig

# 4) 替换并重启（会有几秒中断）
systemctl stop 1panel-agent
install -m755 1panel-agent /usr/local/bin/1panel-agent
systemctl start 1panel-agent

# 5) 验证
1pctl status                            # Core / Agent 都应为 Running
```

> `/usr/bin/1panel-agent` 通常是指向 `/usr/local/bin/1panel-agent` 的软链接，替换真实文件即可。

### 手动回滚

```bash
systemctl stop 1panel-agent
install -m755 /root/1panel-agent.orig /usr/local/bin/1panel-agent
systemctl start 1panel-agent
1pctl status
```

## 用法三：自己编译（任意版本）

需要 Go **>= 1.26.6**（其他版本请对照 `agent/go.mod` 的 `go` 指令调整）：

```bash
./build.sh v2.3.2          # 参数填你的面板版本 tag
# 产物在 ./build/1panel-agent
```

脚本会：克隆对应 tag 的源码 → 打上补丁 → 编译 linux/amd64 的 agent。

小提示：**agent 是纯 Go 且不内嵌前端，编译不需要 Node/前端**（只有 core 需要），这一步几分钟就好，在普通 VPS 上也能编。

编译完成后同样按「用法二」的第 3–5 步替换。

## 注意事项

- **1Panel 升级会覆盖 `/usr/local/bin/1panel-agent`**，升级后需要重新替换或重新编译。
- 本仓库只是把上游的一处实现问题打好补丁，已提交 PR 到上游（见顶部链接）；如果 PR 被合并，升级到包含该修复的版本后就不再需要本仓库了。
- 建议替换前先备份官方二进制，并确认你清楚回滚步骤。

## 许可证与致谢

- 本仓库的二进制与补丁基于 [1Panel](https://github.com/1Panel-dev/1Panel) 修改，项目采用 **GPL-3.0** 许可证，本仓库遵循同一许可证，完整许可证文本见 [LICENSE](LICENSE)。
- 修改内容见 [patch/0001-sftp-concurrent-writes.patch](patch/0001-sftp-concurrent-writes.patch)，已提交上游 PR [#13976](https://github.com/1Panel-dev/1Panel/pull/13976)。
- 1Panel 是一个优秀的开源项目，本项目仅修复其 SFTP 上传性能问题。
