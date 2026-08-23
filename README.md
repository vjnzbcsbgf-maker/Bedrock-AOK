# Bedrock Linux for iSH-AOK

[![License: GPL v2](https://img.shields.io/badge/License-GPL_v2-blue.svg)](LICENSE)
[![POSIX Shell](https://img.shields.io/badge/Language-POSIX_Shell-4EAA25.svg)](#)
[![Platform: iOS | iPadOS](https://img.shields.io/badge/Platform-iOS_|_iPadOS-000000.svg?logo=apple&logoColor=white)](https://github.com/emkey1/AOK-Filesystem-Tools)
[![Version: 1.1.0](https://img.shields.io/badge/Version-1.1.0-E95420.svg)](#)
[![Strata: 29 distros](https://img.shields.io/badge/Strata-29_Distributions-2ea44f.svg)](#supported-distributions)
[![Status: In Development](https://img.shields.io/badge/Status-In_Development-FFDD57.svg?labelColor=555)](#development-status)
[![Arch: aarch64](https://img.shields.io/badge/Arch-aarch64-lightgrey.svg)](#)
[![Based on: Bedrock Linux](https://img.shields.io/badge/Based_on-Bedrock_Linux-7B42BC.svg)](https://bedrocklinux.org)
[![Website](https://img.shields.io/badge/Website-Bedrock--AOK-c4a574.svg)](https://vjnzbcsbgf-maker.github.io/Bedrock-AOK/)

> **Run 29 Linux distributions simultaneously on iOS — from a single shell.**
>
> **[Website](https://vjnzbcsbgf-maker.github.io/Bedrock-AOK/)** · **[Forum](https://vjnzbcsbgf-maker.github.io/Bedrock-AOK/#forum)** · **[Releases](https://vjnzbcsbgf-maker.github.io/Bedrock-AOK/#releases)** · **[GitHub](https://github.com/vjnzbcsbgf-maker/Bedrock-AOK)**

Bedrock-AOK is a faithful port of [Bedrock Linux](https://bedrocklinux.org) for [iSH-AOK](https://github.com/emkey1/AOK-Filesystem-Tools) (aarch64), the enhanced fork of the original [iSH](https://github.com/ish-app/ish) Linux emulator for iOS. It reimplements Bedrock's multi-distro stratum system using only `chroot` and bind mounts — no FUSE, no kernel namespaces, no extended attributes — so it runs cleanly inside iSH-AOK's emulated Linux environment on iPhone and iPad.

Each distribution lives in its own **stratum**: an isolated root filesystem that shares the host's kernel, network, and device tree. Commands installed in any stratum are automatically wired into a unified `PATH` so you can mix packages freely across distros.

> [!NOTE]
> **Active Development** — This project is under active development. Some iSH-AOK kernel capabilities (certain namespace types, cgroup v2, seccomp filters) may not be detected or fully functional depending on your iSH-AOK build version. The capability detection system (`brl capabilities`) reports what works on your specific build, and features degrade gracefully when a capability is unavailable.

---

## Table of Contents

- [Features](#features)
- [Supported Distributions](#supported-distributions)
- [Requirements](#requirements)
- [Installation](#installation)
- [Editions](#editions)
- [Usage](#usage)
- [Architecture](#architecture)
- [How It Differs from Upstream Bedrock](#how-it-differs-from-upstream-bedrock)
- [Uninstalling](#uninstalling)
- [Troubleshooting](#troubleshooting)
- [Development Status](#development-status)
- [Contributing](#contributing)
- [Acknowledgments](#acknowledgments)
- [Copyright and Attribution](#copyright-and-attribution)
- [License](#license)

---

## Features

### Core

- **29 distributions** available out of the box — Alpine, Debian, Ubuntu, Fedora, Arch, Kali, Gentoo, Void, openSUSE, and [more](#supported-distributions)
- **One-command fetch** — `brl fetch alpine` downloads, extracts, and configures a stratum in seconds
- **Cross-distro command access** — install `vim` in Debian, `htop` in Alpine, use both from anywhere
- **Streaming downloads** — rootfs tarballs are piped directly through the decompressor; no temp file, no second pass
- **aria2c acceleration** — when available, downloads use 8 parallel connections for significantly faster fetches
- **Automatic dependency resolution** — detects the host package manager (apk, apt, pacman, dnf, ...) and installs missing tools

### Environment

- **Mount namespace isolation** — when iSH-AOK exposes namespace support, `strat` sessions get private mounts that vanish on exit
- **Automatic DNS, TLS, and locale setup** — every stratum gets working name resolution, certificates, and a UTF-8 locale
- **Per-distro package manager fixes** — iSH-AOK-specific patches for pacman, apt, dnf, zypper, xbps, apk, opkg, and portage
- **AUR support** — Arch strata get `yay` installed automatically with an unprivileged `builder` user
- **Service suppression** — `policy-rc.d` and a no-op `systemctl` shim prevent service starts inside chroots

### Editions & Lifecycle

- **Five editions** — non-permanent (`brl`), permanent (`brl-permanent`), permanent-integrated (`brl-permanent-integrated`), permanent-all (`brl-permanent-all`), and unified installer (`bedrockport.sh`)
- **Full integration layer** — all editions now include capability detection, structured logging, and the integration functions
- **Clean uninstaller** — all permanent editions ship a dedicated `brl-uninstall` script that fully restores the host

### Integration Layer (all editions)

- **Runtime capability detection** — probes what the iSH-AOK kernel actually supports (namespaces, cgroups, filesystems) and adapts
- **Self-test suite** — `brl test` runs a full regression suite covering environment, structure, namespaces, and strat round-trips
- **Health checks with auto-repair** — `brl health` verifies each stratum can exec and auto-repairs broken ones
- **Integrity verification** — `brl verify` checks the Bedrock directory structure with optional `--repair`
- **Rollback points** — snapshot and restore Bedrock configuration to undo bad changes
- **systemd boot integration** — optional init service and target so `/bedrock` comes up at boot without touching PID 1 (integrated/all/unified editions)
- **AOK roots registration** — auto-discovers `/AOK/roots` and registers them as Bedrock strata
- **Structured logging** — journald when available, file fallback at `/bedrock/var/log/bedrock.log`

---

## Supported Distributions

| Category | Distributions |
|:---|:---|
| **Lightweight** | Alpine, BusyBox, OpenWrt, Chimera |
| **Debian family** | Debian, Ubuntu, Devuan, Kali, Parrot, Apertis |
| **Red Hat family** | Fedora, Rocky Linux, AlmaLinux, Oracle Linux, CentOS Stream, Amazon Linux, Springdale, openEuler |
| **Arch family** | Arch Linux (LXC), Arch Linux ARM (native aarch64) |
| **Independent** | openSUSE, Void, Gentoo, Funtoo, ALT Linux |

**29 distributions** in total. All are fetched as aarch64 rootfs images from the [Linux Containers](https://images.linuxcontainers.org) image server or official distribution mirrors. Custom rootfs URLs are supported via `brl fetch-url`.

---

## Requirements

| Requirement | Details |
|:---|:---|
| **Runtime** | [iSH-AOK](https://github.com/emkey1/AOK-Filesystem-Tools) on iOS / iPadOS (aarch64) |
| **Privileges** | Root access (iSH-AOK runs as root by default) |
| **Network** | Internet connection for fetching strata |
| **Storage** | ~8 MB for Alpine; ~50–300 MB per additional stratum depending on distro |

---

## Installation

### Quick Start

```sh
chmod +x brl-permanent
./brl-permanent hijack

brl fetch alpine
brl shell alpine
```

Three lines. You now have Alpine Linux running as a stratum inside iSH-AOK.

### Choosing an Edition

| Edition | Script | Persists | Integration | Boot Integration | Uninstall |
|:---|:---|:---:|:---:|:---:|:---|
| **Non-Permanent** | `brl` | No | Yes | — | `brl unhijack` |
| **Permanent** | `brl-permanent` | Yes | Yes | — | `brl-uninstall` |
| **Permanent Integrated** | `brl-permanent-integrated` | Yes | Yes | systemd | `brl-uninstall` |
| **Permanent All** | `brl-permanent-all` | Yes | Yes | Full | `brl-uninstall` |
| **Unified Installer** | `bedrockport.sh` | Yes | Yes | Full | `brl-uninstall` |

All editions now include the integration layer (capability detection, AOK roots registration, structured logging).

#### Non-Permanent Edition

```sh
chmod +x brl
./brl hijack
```

Does not persist across reboots. Fully reversible with `brl unhijack`.

#### Permanent Edition

```sh
chmod +x brl-permanent
./brl-permanent hijack
```

Survives reboots. Use the dedicated `brl-uninstall` script to remove.

#### Permanent Integrated Edition

```sh
chmod +x brl-permanent-integrated
./brl-permanent-integrated hijack
```

Everything in the permanent edition plus systemd boot integration, AOK roots registration, health checks, and rollback.

#### Permanent All Edition

```sh
chmod +x brl-permanent-all
./brl-permanent-all hijack
```

Maximum integration. All features enabled including full capability suite and structured logging.

#### Unified Installer (Recommended)

```sh
chmod +x bedrockport.sh
./bedrockport.sh --hijack
```

Single-file deployment combining `brl` + `strat` + installer. All integration features. Supports `--hijack`, `--update`, `--force-update`, and `--restat`.

---

## Usage

### Stratum Management

```sh
brl fetch <distro>              # Fetch and configure a new stratum
brl fetch --list                # List all available distributions
brl fetch-url <name> <url>      # Fetch a stratum from a custom rootfs URL
brl apply                       # Fetch every stratum in the catalog
brl list                        # List installed strata
brl list -e                     # List enabled strata only
brl status [stratum]            # Show stratum status
brl show <stratum>              # Show stratum details (distro, package manager, path)
brl remove <stratum>            # Remove a stratum
brl rename <old> <new>          # Rename a stratum
brl enable <stratum>            # Enable cross-command access
brl disable <stratum>           # Disable cross-command access
```

### Running Commands

```sh
brl shell <stratum>                     # Interactive shell inside a stratum
strat <stratum> <command> [args...]     # Run a single command in a stratum
strat -r <stratum> <command>            # Run restricted (no cross-distro PATH)
```

### Package Management

```sh
brl install <stratum> <pkg>...   # Install packages into a stratum from the host
brl update [stratum]             # Update packages (one stratum or all)
```

### File Operations

```sh
brl copy <src> /path/to/file <dst> [dest-path]   # Copy a file between strata
```

### System

```sh
brl report               # System health check (kernel, capabilities, mounts)
brl reload               # Rebuild cross-command wrappers
brl fix [stratum]        # Re-apply environment fixes to strata
brl update-urls          # Re-resolve all stratum source URLs from live mirrors
brl umount [stratum]     # Release stratum mounts
brl deps                 # Check/install host dependencies
brl tutorial             # Quick-start tutorial
brl version              # Show version
```

### Advanced Commands

Available in all editions (some features require integrated/all/unified editions):

```sh
brl capabilities [--json]       # Show detected iSH-AOK kernel capabilities
brl test                        # Run full self-test / regression suite
brl health [stratum]            # Health check strata (auto-repairs failures)
brl verify [--repair]           # Integrity check on Bedrock directory structure
brl rollback list               # List saved rollback points
brl rollback create [label]     # Create a named rollback point
brl rollback restore <id>       # Restore a previous rollback point
brl integrate                   # Full integration setup (caps + verify + units + AOK roots)
brl register-aok                # Discover and register /AOK/roots as strata
```

---

## Architecture

```
┌───────────────────────────────────────────────────────────┐
│  iSH-AOK (iOS / iPadOS)                                  │
│                                                           │
│  ┌──────────────────────────────────────────────────────┐ │
│  │  Host (Alpine / Debian / ...)                        │ │
│  │                                                      │ │
│  │  /bedrock/                                           │ │
│  │  ├── bin/          brl, strat, helper scripts        │ │
│  │  ├── cross/bin/    auto-generated command shims      │ │
│  │  ├── etc/          config, URL cache, capabilities   │ │
│  │  ├── run/          runtime state, enabled list       │ │
│  │  ├── var/log/      structured log output             │ │
│  │  └── strata/                                         │ │
│  │      ├── alpine/      ← chroot rootfs                │ │
│  │      ├── debian/      ← chroot rootfs                │ │
│  │      ├── fedora/      ← chroot rootfs                │ │
│  │      └── ...          (29 distros available)         │ │
│  └──────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────┘
```

### How It Works

**Cross-command wiring** — When a stratum is enabled, `brl reload` scans its `bin/` directories and generates small shell shims in `/bedrock/cross/bin/`. Each shim calls `strat <stratum> <command>`, transparently routing execution into the correct chroot. This directory is prepended to `PATH` via `/etc/profile.d/bedrock.sh`.

**Mount isolation** — On iSH-AOK builds that support `unshare -m`, each `strat` invocation runs inside a private mount namespace. Pseudo-filesystems (`/proc`, `/sys`, `/dev`, `/run`) are mounted per-session and cleaned up automatically on exit. On older builds, mounts are shared globally and persist until `brl umount`.

**Capability detection** *(integrated edition)* — At hijack time, `bedrockport.sh` probes every kernel feature: each namespace type (`mount`, `pid`, `uts`, `ipc`, `net`, `user`, `cgroup`), filesystem support (`procfs`, `sysfs`, `tmpfs`, `devpts`), `bind_mount`, `seccomp`, `FUSE`, `cgroup v2`, and AOK-specific roots. Each is classified as `native`, `emulated`, or `unavailable`. Results are saved to `/bedrock/etc/capabilities.conf` and drive runtime decisions throughout the script.

**Service suppression** — Package post-install scripts that try to start services via systemd or sysvinit are neutralized inside chroots. Debian-family strata get `policy-rc.d`; all families with systemd get a no-op `/usr/local/sbin/systemctl` shim. Package installs never fail due to missing init.

---

## How It Differs from Upstream Bedrock

| Aspect | Upstream Bedrock Linux | Bedrock-AOK |
|:---|:---|:---|
| **Language** | C + custom kernel module | Pure POSIX shell |
| **Isolation** | Kernel namespaces, FUSE, xattrs | `chroot` + bind mounts |
| **Cross-filesystem** | FUSE-based `crossfs` | Shell shim scripts in `/bedrock/cross/bin/` |
| **Target platform** | Bare-metal / VM x86_64 | iSH-AOK aarch64 on iOS |
| **Init integration** | Hijacks PID 1 | Optional systemd service (PID 1 untouched) |
| **Package sources** | Mirror-based with GPG verification | LXC image server + direct mirrors |
| **Capability model** | Assumes full kernel support | Probes and adapts to available features |
| **Self-diagnostics** | — | `brl test`, `brl health`, `brl verify` |

---

## Uninstalling

### Permanent Editions

All permanent editions ship a dedicated uninstaller:

```sh
./brl-uninstall                # Interactive — asks about keeping strata
./brl-uninstall --keep-strata  # Remove Bedrock, keep downloaded strata
./brl-uninstall --purge        # Remove everything, no prompts
```

The uninstaller safely unmounts all strata, restores `/etc/os-release`, removes shell integration, cleans up symlinks, and optionally deletes all strata data.

### Non-Permanent Edition

```sh
brl unhijack
```

---

## Troubleshooting

| Problem | Fix |
|:---|:---|
| DNS not working in a stratum | `brl fix <stratum>` — re-applies DNS, TLS certificates, and package manager patches |
| Package manager errors (GPG, signatures, sandbox) | `brl fix <stratum>` — re-applies iSH-AOK-specific patches for the stratum's package manager |
| `chroot: not found` or missing tools | `brl deps` — checks for required host tools and installs any that are missing |
| Strata mounts left behind after exit | `brl umount` (all) or `brl umount <stratum>` (one) |
| Fetch fails / URL unresolved | `brl update-urls` then retry `brl fetch <stratum>` |
| Stratum won't enter or exec fails | `brl health <stratum>` *(integrated edition)* — diagnoses and auto-repairs |
| Bedrock directory structure damaged | `brl verify --repair` *(integrated edition)* |
| Bad config change, need to revert | `brl rollback list` then `brl rollback restore <id>` *(integrated edition)* |

---

## Development Status

This project is under active development. The capability detection system adapts to what your iSH-AOK kernel build actually supports — features degrade gracefully when a capability is unavailable.

| Feature | Status | Notes |
|:---|:---:|:---|
| Core stratum system (fetch, shell, strat) | ![Stable](https://img.shields.io/badge/-Stable-2ea44f) | All editions |
| Cross-command wiring (crossfs shims) | ![Stable](https://img.shields.io/badge/-Stable-2ea44f) | All editions |
| 29-distro catalog with live URL resolution | ![Stable](https://img.shields.io/badge/-Stable-2ea44f) | All editions |
| Streaming downloads + aria2c acceleration | ![Stable](https://img.shields.io/badge/-Stable-2ea44f) | All editions |
| Per-distro package manager fixes | ![Stable](https://img.shields.io/badge/-Stable-2ea44f) | 9 package managers |
| Rollback / integrity verification | ![Stable](https://img.shields.io/badge/-Stable-2ea44f) | Integrated edition |
| Self-test suite | ![Stable](https://img.shields.io/badge/-Stable-2ea44f) | 20+ regression tests |
| Mount namespace isolation | ![Working](https://img.shields.io/badge/-Working-blue) | Depends on iSH-AOK build |
| PID / UTS / IPC / Net namespace isolation | ![In Progress](https://img.shields.io/badge/-In_Progress-FFDD57) | Depends on iSH-AOK kernel |
| User namespace support | ![In Progress](https://img.shields.io/badge/-In_Progress-FFDD57) | Depends on iSH-AOK kernel |
| cgroup v2 integration | ![In Progress](https://img.shields.io/badge/-In_Progress-FFDD57) | Depends on iSH-AOK kernel |
| seccomp filter detection | ![In Progress](https://img.shields.io/badge/-In_Progress-FFDD57) | Depends on iSH-AOK kernel |
| systemd boot integration | ![Experimental](https://img.shields.io/badge/-Experimental-orange) | Integrated edition |
| AOK roots auto-registration | ![Experimental](https://img.shields.io/badge/-Experimental-orange) | Integrated edition |

---

## Contributing

Contributions are welcome. This project is a community port — it is not affiliated with or endorsed by the upstream Bedrock Linux project.

1. Fork the repository
2. Create a feature branch
3. Test on iSH-AOK
4. Submit a pull request

All contributions must be compatible with the GPLv2 license.

---

## Acknowledgments

- [**Bedrock Linux**](https://bedrocklinux.org) by paradigm — the original project that makes multi-distro Linux possible
- [**iSH-AOK**](https://github.com/emkey1/AOK-Filesystem-Tools) by emkey1 — the enhanced iSH fork with aarch64 support, real filesystem tools, and expanded kernel compatibility
- [**iSH**](https://github.com/ish-app/ish) — the original x86 Linux emulator for iOS that started it all
- [**Linux Containers**](https://images.linuxcontainers.org) — the image server that provides rootfs tarballs for most supported distributions

---

## Copyright and Attribution

- **Linux** is a registered trademark of Linus Torvalds. The Linux kernel is released under the GNU General Public License v2.0. This project runs on top of Linux and would not exist without the open-source ecosystem Linus Torvalds created.
- **Bedrock Linux**, its name, logo, documentation, and website content are copyright &copy; [paradigm](https://bedrocklinux.org). Bedrock-AOK is an independent community port and is not affiliated with or endorsed by the upstream Bedrock Linux project.
- **iSH** is copyright &copy; the [iSH contributors](https://github.com/ish-app/ish). **iSH-AOK** is copyright &copy; [emkey1](https://github.com/emkey1/AOK-Filesystem-Tools) and contributors.

All upstream trademarks, logos, and copyrights remain the property of their respective owners.

---

## Open-Source Requirement

This project is licensed under the **GNU General Public License v2.0** — a copyleft license. Under its terms:

- Any fork, derivative work, or redistribution of this project **must** be released under the same GPLv2 license.
- Any substantial contribution incorporated into this project is subject to the GPLv2 and must remain open source.
- Modified versions **must** carry prominent notices stating what was changed and the date of each change.
- You **may not** distribute this software, or any work based on it, under proprietary or closed-source terms.

If you fork this project or build upon it, you are legally required to make your source code available under the GPLv2. See [LICENSE](LICENSE) for the full license text.

---

## License

This project is licensed under the **GNU General Public License v2.0**. See [LICENSE](LICENSE) for the full text.

Bedrock Linux is originally created by [paradigm](https://bedrocklinux.org). This port is an independent reimplementation for iSH-AOK.
