# Bedrock Linux for iSH-AOK

**Run 25+ Linux distributions simultaneously on iOS — from a single shell.**

Bedrock-AOK is a faithful port of [Bedrock Linux](https://bedrocklinux.org) 0.7.31 Poki for [iSH-AOK](https://github.com/emkey1/AOK-Filesystem-Tools) (aarch64), the enhanced fork of the original [iSH](https://github.com/ish-app/ish) Linux emulator for iOS. It reimplements Bedrock's multi-distro stratum system using only `chroot` and bind mounts — no FUSE, no kernel namespaces, no extended attributes — so it runs cleanly inside iSH-AOK's emulated Linux environment on iPhone and iPad.

Each distribution lives in its own **stratum**: an isolated root filesystem that shares the host's kernel, network, and device tree. Commands installed in any stratum are automatically wired into a unified `PATH` so you can mix packages freely across distros.

---

## Features

- **25+ distributions** available out of the box — Alpine, Debian, Ubuntu, Fedora, Arch, Kali, Gentoo, Void, openSUSE, and more
- **One-command fetch** — `brl fetch alpine` downloads, extracts, and configures a stratum in seconds
- **Cross-distro command access** — install `vim` in Debian, `htop` in Alpine, use both from anywhere
- **Streaming downloads** — rootfs tarballs are piped directly through the decompressor; no temp file, no second pass
- **Automatic dependency resolution** — detects the host package manager (apk, apt, pacman, dnf, ...) and installs missing tools
- **Mount namespace isolation** — when iSH-AOK exposes namespace support, strat sessions get private mounts that vanish on exit
- **Automatic DNS, TLS, and locale setup** — every stratum gets working name resolution, certificates, and a UTF-8 locale
- **Per-distro package manager fixes** — iSH-AOK-specific patches for pacman, apt, dnf, zypper, xbps, apk, opkg, and portage
- **AUR support** — Arch strata get `yay` installed automatically with an unprivileged builder user
- **Permanent and non-permanent editions** — choose whether Bedrock survives a reboot or stays session-only
- **Clean uninstaller** — the permanent edition ships a dedicated `brl-uninstall` script that fully restores the host

## Supported Distributions

| Category | Distributions |
|---|---|
| **Lightweight** | Alpine, BusyBox, OpenWrt, Chimera |
| **Debian family** | Debian, Ubuntu, Devuan, Kali, Parrot, Apertis |
| **Red Hat family** | Fedora, Rocky Linux, AlmaLinux, Oracle Linux, CentOS Stream, Amazon Linux, Springdale, openEuler |
| **Arch family** | Arch Linux (LXC), Arch Linux ARM (native) |
| **Independent** | openSUSE, Void, Gentoo, Funtoo, ALT Linux |

All distributions are fetched as aarch64 rootfs images from the [Linux Containers](https://images.linuxcontainers.org) image server or official distribution mirrors.

## Requirements

- [iSH-AOK](https://github.com/emkey1/AOK-Filesystem-Tools) running on iOS/iPadOS (aarch64)
- Root access (iSH-AOK runs as root by default)
- Internet connection for fetching strata
- ~8 MB for Alpine, ~50-300 MB per additional stratum depending on distro

## Installation

### Quick Start (Permanent Edition)

```sh
# Download and install
chmod +x brl-permanent
./brl-permanent hijack

# Fetch your first stratum
brl fetch alpine

# Enter it
brl shell alpine
```

### Non-Permanent Edition

```sh
# Download and run (does not persist across reboots)
chmod +x brl
./brl hijack

# Same usage from here
brl fetch alpine
brl shell alpine
```

## Usage

### Stratum Management

```sh
brl fetch <distro>            # Fetch and configure a new stratum
brl fetch --list              # List all available distributions
brl fetch-url <name> <url>    # Fetch a stratum from a custom rootfs URL
brl apply                     # Fetch every stratum in the catalog
brl list                      # List installed strata
brl list -e                   # List enabled strata only
brl status [stratum]          # Show stratum status
brl show <stratum>            # Show stratum details (distro, package manager, path)
brl remove <stratum>          # Remove a stratum
brl rename <old> <new>        # Rename a stratum
brl enable <stratum>          # Enable cross-command access
brl disable <stratum>         # Disable cross-command access
```

### Running Commands

```sh
brl shell <stratum>                   # Interactive shell inside a stratum
strat <stratum> <command> [args...]   # Run a single command in a stratum
strat -r <stratum> <command>          # Run restricted (no cross-distro PATH)
```

### Package Management

```sh
brl install <stratum> <pkg>...   # Install packages into a stratum from the host
brl update [stratum]             # Update packages (one stratum or all)
```

### System

```sh
brl report             # System health check (kernel, capabilities, mounts)
brl reload             # Rebuild cross-command wrappers
brl fix [stratum]      # Re-apply environment fixes to strata
brl update-urls        # Re-resolve all stratum source URLs from live mirrors
brl umount [stratum]   # Release stratum mounts
brl deps               # Check/install host dependencies
brl tutorial           # Quick-start tutorial
brl version            # Show version
```

### Copy Files Between Strata

```sh
brl copy <src-stratum> /path/to/file <dst-stratum> [dest-path]
```

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  iSH-AOK (iOS)                                      │
│                                                      │
│  ┌─────────────────────────────────────────────────┐ │
│  │  Host (Alpine / Debian / ...)                   │ │
│  │                                                 │ │
│  │  /bedrock/                                      │ │
│  │  ├── bin/         brl, strat, helper scripts    │ │
│  │  ├── cross/bin/   auto-generated command shims  │ │
│  │  ├── etc/         config, URL cache, os-release │ │
│  │  ├── run/         runtime state                 │ │
│  │  └── strata/                                    │ │
│  │      ├── alpine/     ← chroot rootfs            │ │
│  │      ├── debian/     ← chroot rootfs            │ │
│  │      ├── fedora/     ← chroot rootfs            │ │
│  │      └── ...                                    │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

**Cross-command wiring**: when a stratum is enabled, `brl reload` scans its `bin/` directories and generates small shell shims in `/bedrock/cross/bin/`. Each shim calls `strat <stratum> <command>`, transparently routing the execution into the correct chroot. This directory is prepended to `PATH` via `/etc/profile.d/bedrock.sh`.

**Mount isolation**: on iSH-AOK builds that support `unshare -m`, each `strat` invocation runs inside a private mount namespace. Pseudo-filesystems (`/proc`, `/sys`, `/dev`, `/run`) are mounted per-session and cleaned up automatically on exit. On older builds, mounts are shared globally and persist until `brl umount`.

## How It Differs from Upstream Bedrock

| Aspect | Upstream Bedrock Linux | Bedrock-AOK |
|---|---|---|
| **Implementation** | C + custom kernel module (crossfs, strat FUSE) | Pure POSIX shell |
| **Isolation** | Kernel namespaces, FUSE, xattrs | `chroot` + bind mounts |
| **Cross-filesystem** | FUSE-based crossfs | Shell shim scripts in `/bedrock/cross/bin/` |
| **Target** | Bare-metal / VM x86_64 | iSH-AOK aarch64 on iOS |
| **Init integration** | Hijacks PID 1 | No init modification |
| **Package sources** | Mirror-based with GPG | LXC image server + direct mirrors |

## Uninstalling (Permanent Edition)

The permanent edition provides a dedicated uninstaller:

```sh
./brl-uninstall              # Interactive — asks about keeping strata
./brl-uninstall --keep-strata  # Remove Bedrock, keep downloaded strata
./brl-uninstall --purge        # Remove everything, no prompts
```

The uninstaller safely unmounts all strata, restores `/etc/os-release`, removes shell integration, cleans up symlinks, and optionally deletes all strata data.

## Troubleshooting

**DNS not working in a stratum**
```sh
brl fix <stratum>
```
This re-applies DNS configuration, TLS certificates, and all package manager fixes.

**Package manager errors (GPG, signatures, sandbox)**
```sh
brl fix <stratum>
```
The fix command re-applies iSH-AOK-specific patches that disable sandboxing and signature checks that don't work in the chroot environment.

**"chroot: not found" or missing tools**
```sh
brl deps
```
This checks for required host tools and installs any that are missing.

**Strata mounts left behind after exit**
```sh
brl umount           # Unmount all
brl umount <stratum> # Unmount one
```

**Fetch fails / URL unresolved**
```sh
brl update-urls      # Re-resolve all source URLs from live mirrors
brl fetch <stratum>  # Retry
```

## Contributing

Contributions are welcome. This project is a community port — it is not affiliated with or endorsed by the upstream Bedrock Linux project.

1. Fork the repository
2. Create a feature branch
3. Test on iSH-AOK
4. Submit a pull request

## Acknowledgments

- [Bedrock Linux](https://bedrocklinux.org) by paradigm — the original project that makes multi-distro Linux possible
- [iSH-AOK](https://github.com/emkey1/AOK-Filesystem-Tools) by emkey1 — the enhanced iSH fork with aarch64 support, real filesystem tools, and expanded kernel compatibility
- [iSH](https://github.com/ish-app/ish) — the original x86 Linux emulator for iOS that started it all
- [Linux Containers](https://images.linuxcontainers.org) — the image server that provides rootfs tarballs for most supported distributions

## License

This project is licensed under the GNU General Public License v2.0. See [LICENSE](LICENSE) for the full text.

Bedrock Linux is originally created by [paradigm](https://bedrocklinux.org). This port is an independent reimplementation for iSH-AOK.
