# shadowsocks-rust-server-installer

用于在 Linux 服务器上安装和管理 `shadowsocks-rust` 服务端的交互式脚本。

脚本会自动下载官方 `shadowsocks-rust` release，校验压缩包 SHA256，生成服务端配置并安装 `systemd` 服务。安装后再次运行同一脚本，即可通过管理菜单维护服务。

## 主要功能

1. 安装 Shadowsocks Rust
2. 更新 Shadowsocks Rust
3. 卸载 Shadowsocks Rust
4. 启动、停止或重启服务
5. 修改配置信息
6. 查看配置信息
7. 查看运行状态
8. 切换脚本语言

更新程序时会保留现有配置；服务如果在更新前处于停止状态，更新后仍保持停止。修改配置也会保留原服务运行状态，并先备份现有配置。

## 一键安装

在服务器上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/clavulin/shadowsocks-rust-server-installer/main/install.sh -o /tmp/shadowsocks-rust-install.sh && sudo bash /tmp/shadowsocks-rust-install.sh
```

如果你想先审阅脚本再运行：

```bash
curl -fsSLO https://raw.githubusercontent.com/clavulin/shadowsocks-rust-server-installer/main/install.sh
chmod +x install.sh
sudo ./install.sh
```

## 脚本语言

脚本支持 English 和简体中文。交互运行时会先让你选择语言；检测到 `Asia/Shanghai`、`Shanghai` 或 `PRC` 时默认简体中文，其他时区默认 English。

也可以在命令行直接指定语言并跳过选择：

```bash
sudo ./install.sh --lang zh
sudo ./install.sh --lang en
```

## 运行要求

- Linux 服务器
- `systemd`
- root 权限
- 可访问 GitHub release
- 支持的包管理器之一：`apt-get`、`dnf`、`yum`、`zypper`、`pacman`

除 `sudo`/root 提权外，脚本会检查运行所需命令，并按当前包管理器自动补装缺失的最小依赖包，包括用于配置管理的 `jq`。

脚本会根据 CPU 架构选择官方 Linux 二进制包，支持常见的 `x86_64`、`aarch64/arm64`、`armv7`、`arm`、`i686`、`loongarch64`、`mips`、`mipsel`、`mips64el`、`riscv64`。

## 安装时会询问什么

- 安装版本：留空表示安装官方最新稳定版
- 监听地址：默认 `::`
- 服务端口：默认 `8388`
- 加密方法：可从常用方法菜单选择，也可以手动输入
- 密码/key：可输入自定义值；不合法时会提示重新输入，留空则使用 `ssservice genkey` 随机生成
- 流量模式：默认 `tcp_and_udp`
- 超时时间：默认 `300`
- 节点名称：用于生成最后的 `ss://` 链接
- 防火墙放行：检测到已启用的 `firewalld` 或 `ufw` 时可自动放行 TCP/UDP 端口

AEAD 2022 加密方法要求自定义 key 使用标准 Base64 编码，解码后的长度必须与方法匹配：`2022-blake3-aes-128-gcm` 为 16 字节，`2022-blake3-aes-256-gcm` 和 `2022-blake3-chacha20-poly1305` 为 32 字节。普通 AEAD 方法可以使用自定义非空密码。直接回车始终使用对应加密方法生成的安全随机值。

## 安装后

重新运行脚本即可进入管理菜单：

```bash
sudo ./install.sh
```

安装总结和“查看配置信息”默认都会将密码/key 显示为 `********`；只有再次确认后，脚本才会显示真实密码/key 和 `ss://` 分享链接。交互输入自定义密码/key 时不会在终端回显。

卸载默认只移除程序、systemd 服务和脚本记录的防火墙规则，配置及其备份保留在 `/etc/shadowsocks-rust`。如需完整清理，需在卸载过程中第二次确认删除配置和备份。若防火墙工具不可用或规则删除失败，脚本默认在删除程序前停止；你也可以再次确认继续卸载，未完成的清理记录会保留供以后重试。

也可以直接使用以下系统命令：

查看服务状态：

```bash
sudo systemctl status shadowsocks-rust --no-pager
```

查看日志：

```bash
sudo journalctl -u shadowsocks-rust -e --no-pager
```

重启服务：

```bash
sudo systemctl restart shadowsocks-rust
```

修改配置后需要重启服务：

```bash
sudo nano /etc/shadowsocks-rust/config.json
sudo systemctl restart shadowsocks-rust
```

## 安装位置

- 主程序：`/usr/local/bin/ssserver`
- 辅助程序：`/usr/local/bin/ssservice`
- 配置文件：`/etc/shadowsocks-rust/config.json`
- systemd 服务：`/etc/systemd/system/shadowsocks-rust.service`
- 安装器状态目录：`/var/lib/shadowsocks-rust-installer`

状态目录保存节点名称、脚本创建的服务账户标记和防火墙规则状态，权限为 `0700`。脚本只会自动删除已确认由自身成功添加的防火墙规则；firewalld 规则还会记录添加时的 zone，无法确认 zone 的旧记录会保留并停止自动清理。如果规则删除结果因中断而无法确认，脚本也只会保留记录并等待人工确认，不会再次自动删除后来出现的同端口规则。修改端口时会先完成新规则准备，再提交配置。写入已有配置或修改配置时，原文件会按时间戳备份；完整安装存在时请分别使用“更新”或“修改配置信息”，脚本不会直接覆盖重装。

## 示例配置

配置文件结构参考 [examples/server-config.json](./examples/server-config.json)。
