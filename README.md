# shadowsocks-rust-server-installer

用于在 Linux 服务器上一键安装并配置 `shadowsocks-rust` 服务端的交互式脚本。

脚本会自动下载官方 `shadowsocks-rust` release，校验压缩包 SHA256，生成服务端配置，安装 `systemd` 服务，并在安装结束时输出可用于客户端导入的 `ss://` 链接。

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

## 运行要求

- Linux 服务器
- `systemd`
- root 权限
- 可访问 GitHub release
- 支持的包管理器之一：`apt-get`、`dnf`、`yum`、`zypper`、`pacman`

除 `sudo`/root 提权外，脚本会检查运行所需命令，并按当前包管理器自动补装缺失的最小依赖包。

脚本会根据 CPU 架构选择官方 Linux 二进制包，支持常见的 `x86_64`、`aarch64/arm64`、`armv7`、`arm`、`i686`、`loongarch64`、`mips`、`mipsel`、`mips64el`、`riscv64`。

## 安装时会询问什么

- 安装版本：留空表示安装官方最新稳定版
- 监听地址：默认 `::`
- 服务端口：默认 `8388`
- 加密方法：可从常用方法菜单选择，也可以手动输入
- 密码/key：留空时使用 `ssservice genkey` 自动生成
- 流量模式：默认 `tcp_and_udp`
- 超时时间：默认 `300`
- 节点名称：用于生成最后的 `ss://` 链接
- 防火墙放行：检测到已启用的 `firewalld` 或 `ufw` 时可自动放行 TCP/UDP 端口

## 安装后

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

重复运行安装脚本时，已有配置文件和服务文件会先按时间戳备份，再写入新文件。

## 示例配置

配置文件结构参考 [examples/server-config.json](./examples/server-config.json)。
