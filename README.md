# shadowsocks-rust-server-installer

Interactive Linux installer for `shadowsocks-rust` server mode. It downloads the official release tarball, verifies the checksum, writes a server config, and installs a `systemd` service.

## What it does

- Detects the latest stable upstream release from GitHub, or installs a version you specify.
- Selects a matching Linux asset for the current CPU architecture.
- Verifies the downloaded archive with the upstream `.sha256` file.
- Installs `ssserver` and `ssservice` into `/usr/local/bin`.
- Writes `/etc/shadowsocks-rust/config.json`.
- Creates and enables `shadowsocks-rust.service`.
- Optionally opens the port in `firewalld` or `ufw` if either is active.
- Prints a usable `ss://` link template at the end when public IP detection succeeds.

## Requirements

- A Linux host using `systemd`.
- Root access.
- Internet access to GitHub releases.
- One of these package managers if core tools are missing:
  - `apt-get`
  - `dnf`
  - `yum`
  - `zypper`
  - `pacman`

## Usage

```bash
cd ~/Developer/shadowsocks-rust-server-installer
chmod +x install.sh
sudo ./install.sh
```

The script will ask for:

- Release version, or blank for latest stable
- Bind address
- Server port
- Cipher method from a common-method menu, or manual input
- Password/key, or blank to auto-generate with `ssservice genkey`
- Traffic mode
- Timeout
- Optional firewall opening

## Installed paths

- Binary: `/usr/local/bin/ssserver`
- Helper: `/usr/local/bin/ssservice`
- Config: `/etc/shadowsocks-rust/config.json`
- Service: `/etc/systemd/system/shadowsocks-rust.service`

## Notes

- Existing config and service files are backed up with a timestamp suffix before being replaced.
- The installer shows a small menu of common ciphers first, and still lets you type an exact method manually.
- For AEAD 2022 methods, leaving the password blank is usually the safest option because the script delegates key generation to upstream `ssservice genkey`.
- The generated service runs as an unprivileged `shadowsocks` system user.

## Example config shape

See [examples/server-config.json](./examples/server-config.json).
