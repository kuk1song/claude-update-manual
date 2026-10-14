# claude-update-manual

[English](README.md) | **中文**

在网速慢或不稳定的网络上更新 Claude Code。

Claude Code 自带的更新器会一次性下载整个新版本，10 分钟下不完就放弃。网速慢或走代理时，它可能永远更新不成功。这个脚本下载的是同样的官方文件，网络断了能从断点接着下，并且在切换到新版本之前先核对 Anthropic 的签名。

> [!NOTE]
> 非官方工具，与 Anthropic 无关。这是在 [anthropics/claude-code#85046](https://github.com/anthropics/claude-code/issues/85046) 修好之前的临时办法。如果你是用 Homebrew、apt 或 dnf 装的 Claude Code，就不需要它。
>
> 本文是 README.md 的中文版，两者不一致时以英文版为准。

<p align="center">
  <img src="docs/demo.png" alt="claude-update-manual 的终端输出：签名通过，下载在 79 MiB 中的 55 MiB 处中断后续传到 100%，校验值通过，试运行通过，2.1.288 切换到 2.1.299" width="760">
</p>
<p align="center"><sub>2026-10-14 的一次真实运行。网速约 65 KB/s，下载用了 21 分钟，是自带更新器 10 分钟上限的两倍多。为了模拟断网，我在 55 MiB 时手动停掉了 curl（所以显示 <code>curl exit 143</code>，shell 因此打印的一行提示没有放进图里），之后它从断点接着下完。</sub></p>

## 快速开始

1. 从 [最新发布](https://github.com/kuk1song/claude-update-manual/releases/latest) 下载 `claude-update-manual` 和 `SHA256SUMS`，然后：

   ```bash
   shasum -a 256 -c SHA256SUMS        # Linux 上用：sha256sum -c SHA256SUMS
   install -m 755 claude-update-manual ~/.local/bin/
   ```

2. 让自带更新器不再反复重试。在 `~/.claude/settings.json` 里加上：

   ```json
   { "env": { "DISABLE_AUTOUPDATER": "1" } }
   ```

3. 更新：

   ```bash
   claude-update-manual
   ```

   随时可以按 Ctrl-C，再运行一次就接着下。更新完重启 Claude Code 才会用上新版本。

## 你需要它吗

| 你是怎么装的 Claude Code | 下载中断后能续传吗 | 要用这个工具吗 |
|---|---|---|
| `curl -fsSL https://claude.ai/install.sh \| bash`（官方的 Native Install） | 不能，而且 10 分钟就停 | 更新总失败的话，要 |
| Homebrew | 能，再运行一次 `brew upgrade` | 不用 |
| apt 或 dnf | 能 | 不用 |
| npm | 不能，但只有下载卡住时才会超时 | 一般不用 |

## 它是怎么工作的

```mermaid
flowchart LR
    A["下载官方文件<br/>（断了接着下）"] --> B{"5 项检查"}
    B -- 全部通过 --> C["切换到新版本"]
    B -- 有一项不过 --> D["什么都不改"]
    C -. 有问题？ .-> E["--rollback<br/>回到之前的版本"]
```

5 项检查，依次是：

1. 文件清单带有 Anthropic 的签名（需要 `gpgv`）。
2. 清单对应的正是你要的版本。
3. 下载的文件和清单上的校验值一致。
4. 在 macOS 上，程序带有 Anthropic 的 Developer ID 签名。
5. 新程序能启动，并报出预期的版本号。

旧版本都留在磁盘上，所以 `--rollback` 不联网也能用。这个工具不删除任何东西。

## 常用命令

| 命令 | 作用 |
|---|---|
| `claude-update-manual` | 更新到最新版本 |
| `claude-update-manual stable` | 更新到 stable 渠道，通常比最新版晚一周左右 |
| `claude-update-manual 2.1.299` | 安装指定版本 |
| `claude-update-manual --rollback` | 回到之前用的版本 |
| `claude-update-manual --check` | 查看本机版本和可用版本 |

## 更多细节

<details>
<summary><b>走代理时</b></summary>

curl 会读 `HTTPS_PROXY` 或 `ALL_PROXY` 环境变量，例如 `export HTTPS_PROXY=http://127.0.0.1:7890`。代理开了 TUN 模式就不用设。
</details>

<details>
<summary><b>有新版本时提示一句</b></summary>

在 `~/.claude/settings.json` 里加上下面这段，有新版本时会在会话开始时提示一行。它最多每天联网查一次，每次最多等 3 秒，并跟随你的 `autoUpdatesChannel` 设置。

```json
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "$HOME/.local/bin/claude-update-manual --hook", "timeout": 8 } ] }
    ]
  }
}
```
</details>

<details>
<summary><b>需要装哪些东西</b></summary>

macOS 或 Linux，bash 3.2 或更新，`curl` 和 `python3`。建议再装：

- `zstd`：下载压缩包。以 2.1.299 的 Apple Silicon 版为例，83 MB，完整程序是 248 MB。
- `gpgv`：核对签名。Debian、Ubuntu 一般自带；macOS 可以 `brew install gnupg`。

没有 `gpgv` 时，macOS 仍会做 Developer ID 检查（第 4 项）；Linux 就只靠 HTTPS 和校验值，和 Anthropic 官方安装脚本一样。
</details>

<details>
<summary><b>它遵守哪些设置</b></summary>

设了 `DISABLE_UPDATES` 时它不运行。它遵守 `~/.claude/settings.json` 和 `managed-settings.json` 里的 `minimumVersion`、`requiredMinimumVersion`、`requiredMaximumVersion`，读不懂这些文件就停下。它不读 `managed-settings.d/`、MDM 配置和服务器下发的设置。

它只动官方安装脚本建的那个启动链接（`~/.local/bin/claude`，指向 `~/.local/share/claude/versions/` 里的某个版本）。自定义的启动方式它不碰。同一时间只允许运行一个。
</details>

<details>
<summary><b>磁盘空间</b></summary>

`~/.local/share/claude/versions/` 里每个版本大约 250 MB。旧版本可以删，但别删 `~/.local/bin/claude` 正指向的那个。注意 `claude update` 会自己删旧版本：只保留最新的两个和正在用的那个。
</details>

<details>
<summary><b>核对你下载的这个工具</b></summary>

每次发布都附有 `SHA256SUMS`。每次发布还带有构建证明，可以用 `gh attestation verify claude-update-manual --repo kuk1song/claude-update-manual` 核对。
</details>

<details>
<summary><b>技术说明</b></summary>

- 续传用的是 HTTP 范围请求。只有连续 5 次都没有进展才停，所以代理每隔几秒掐一次长连接也没问题。
- 签名公钥用指纹固定：`31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`，来自 [Anthropic 的安装文档](https://code.claude.com/docs/en/setup)。2.1.89 起的版本才有签名。
- 新程序先复制到最终位置旁边，在那里检查，再用重命名放到位；切换启动链接也用重命名。
</details>

<details>
<summary><b>测试</b></summary>

```bash
tests/run.sh    # 用本地模拟服务器跑 44 项检查（没有 gpg 时 39 项），只在临时目录里操作
tests/live.sh   # 只读：核对真实的最新签名和你本机装的程序
```

`run.sh` 覆盖下载中断和卡住、校验值与签名错误、清单版本不对、程序起不来、回滚、并发锁、上面这些设置和会话提示。CI 在 Ubuntu 和 macOS 上运行，包括 macOS 自带的 bash 3.2。
</details>

## 许可证

MIT
