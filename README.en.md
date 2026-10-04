# 1Panel Agent — SFTP Upload Speed Fix (patched build)

Fixes the extremely slow **SFTP backup upload** in 1Panel: on the same target host, throughput goes
from **0.25 MB/s to 16–30 MB/s (~100x)**.

- Upstream PR: **https://github.com/1Panel-dev/1Panel/pull/13976**
- This repo ships: a **prebuilt `1panel-agent` (v2.3.2 / linux amd64)**, a one-command build script, and the patch.

---

## Symptom

Uploading a website backup to an SFTP account was limited to **0.2–0.4 MB/s** — a 439MB backup took 29 minutes.

The network was never the problem:

- server egress measured at **40+ MB/s**
- RTT 35–68ms, **0% packet loss** to the targets
- TCP during the transfer: `bytes_retrans 0/29`, `send-q 0`, cwnd far below the window limit
- the stock `sftp` client pushes the same file to the same target at **19 MB/s**

In other words: not SFTP, not the link, not the remote server — **it is 1Panel's own SFTP client implementation.**

## Root cause

`agent/utils/cloud_storage/client/sftp.go` uploaded with:

```go
if _, err := io.Copy(dstFile, srcFile); err != nil {
```

`srcFile` is an `*os.File`, which implements `io.WriterTo`, so `io.Copy` takes the `os.File.WriteTo` branch:
**one synchronous SFTP WRITE per ~32KB packet, waiting for the server reply every time.** Throughput is
therefore bounded by `packetSize / RTT` instead of the link capacity.

`pkg/sftp` (already a dependency) provides a pipelined write path — `File.ReadFrom` plus
`UseConcurrentWrites`, bounded by `MaxConcurrentRequestsPerFile` (default 64). It just was not enabled.

### Same 96MiB file, same host, 68ms RTT

| client | protocol | time | throughput |
| --- | --- | --- | --- |
| 1Panel (stock) | SFTP | 6m40s | **0.25 MB/s** |
| **1Panel (this patch)** | SFTP (pipelined) | **~6s** | **16 MB/s** |
| rclone | SFTP | 6s | 16 MB/s |
| OpenSSH `sftp` | SFTP | 5s | 19 MB/s |

### Real backup job

| | before | after |
| --- | --- | --- |
| single 439MB site | ~29 min | **~17 s** |
| 3 sites, ~950MB total | ~2h40m | **2m04s** |

All uploaded archives pass `gzip -t` when streamed back from the remote — no holes, no corruption.

## What the patch changes

```go
// 1) enable pkg/sftp's concurrent writes for uploads
client, err := sftp.NewClient(sshClient, sftp.UseConcurrentWrites(true))

// 2) use the pipelined ReadFrom instead of io.Copy
//    (truncate to the number of bytes actually written on failure, to avoid holes)
written, err := dstFile.ReadFrom(srcFile)
if err != nil {
    _ = dstFile.Truncate(written)
    ...
}
```

Only the SFTP **upload** path is touched. The download path is unchanged (there the source is an
`*sftp.File`, whose `WriteTo` already uses concurrent reads by default).

---

## Version must match

`1panel-agent` is tied to the panel version (it runs database migrations on startup).
**The binary in `bin/` only fits 1Panel `v2.3.2` (linux/amd64).** For any other version, build it yourself
with `build.sh` — do not swap binaries across versions.

## Usage A — one-command installer (recommended)

The script detects your panel version, downloads the matching binary from the GitHub Release, verifies
its sha256, backs up the current file, replaces it and restarts the agent — **and rolls back
automatically if the service fails to start**.

```bash
# dry run first: print what it would do, change nothing
curl -fsSL https://raw.githubusercontent.com/4kercc/1panel-agent-sftp-fix/main/install.sh | bash -s -- --dry-run

# install
curl -fsSL https://raw.githubusercontent.com/4kercc/1panel-agent-sftp-fix/main/install.sh | bash
```

Roll back to the previous binary:

```bash
curl -fsSL https://raw.githubusercontent.com/4kercc/1panel-agent-sftp-fix/main/install.sh | bash -s -- --rollback
```

> x86_64 only. If your version has no prebuilt asset yet, the script tells you to use Usage C instead.

## Usage B — manual replacement (1Panel v2.3.2)

The prebuilt binary lives in [Releases](https://github.com/4kercc/1panel-agent-sftp-fix/releases), so the
repository itself does not carry an 80MB blob.

```bash
# 1) check version and architecture
1pctl version        # expect: version: v2.3.2
uname -m             # expect: x86_64

# 2) download and verify
curl -fLO https://github.com/4kercc/1panel-agent-sftp-fix/releases/download/v2.3.2/1panel-agent
curl -fLO https://github.com/4kercc/1panel-agent-sftp-fix/releases/download/v2.3.2/1panel-agent.sha256
sha256sum -c 1panel-agent.sha256        # expect: 1panel-agent: OK

# 3) back up the official binary
cp -a /usr/local/bin/1panel-agent /root/1panel-agent.orig

# 4) replace and restart (a few seconds of downtime)
systemctl stop 1panel-agent
install -m755 1panel-agent /usr/local/bin/1panel-agent
systemctl start 1panel-agent

# 5) verify
1pctl status                            # Core / Agent should both be Running
```

> `/usr/bin/1panel-agent` is usually a symlink to `/usr/local/bin/1panel-agent`; replace the real file.

### Manual rollback

```bash
systemctl stop 1panel-agent
install -m755 /root/1panel-agent.orig /usr/local/bin/1panel-agent
systemctl start 1panel-agent
1pctl status
```

## Usage C — build it yourself (any version)

Requires Go **>= 1.26.6** (adjust to the `go` directive in `agent/go.mod` for other versions):

```bash
./build.sh v2.3.2          # pass your panel version tag
# output: ./build/1panel-agent
```

The script clones the matching tag, applies the patch, and cross-compiles the agent for linux/amd64.

Note: the **agent is pure Go and does not embed the frontend, so no Node/frontend build is required**
(only the core needs that) — the build takes a couple of minutes even on a small VPS.

Then follow steps 3–5 of Usage A.

## Caveats

- **A 1Panel upgrade overwrites `/usr/local/bin/1panel-agent`** — re-apply the patch (or the prebuilt binary) afterwards.
- The fix has been submitted upstream (see the PR link at the top). Once a release contains it, this repo is no longer needed.
- Always back up the official binary first and make sure you know the rollback steps.

## License & credits

- The binary and patch are derived from [1Panel](https://github.com/1Panel-dev/1Panel), which is licensed under
  **GPL-3.0**. This repository is distributed under the same license — see [LICENSE](LICENSE).
- The change is in [patch/0001-sftp-concurrent-writes.patch](patch/0001-sftp-concurrent-writes.patch) and was
  submitted upstream as [PR #13976](https://github.com/1Panel-dev/1Panel/pull/13976).
- 1Panel is a great open-source project; this repository only fixes its SFTP upload performance.
