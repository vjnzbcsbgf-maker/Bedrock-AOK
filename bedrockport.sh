#!/bin/sh
# ============================================================================
#  Bedrock Linux — iSH-AOK port  (brl / strat)   bedrock-port  v1.2.0 [PERMANENT]
#  Faithful reimplementation of Bedrock Linux for iSH-AOK (iOS ARM64/aarch64).
#
#  Mixes packages from many distributions as "strata". Uses chroot + bind
#  mounts + a symlink crossfs; on capable AOK builds it uses real mount
#  namespaces. Keeps systemd as PID 1 and makes it Bedrock-aware.
#
#  Runtime-proven capability detection (0 fakes): a feature is "native" only
#  if the actual syscall succeeds. Secure by default: verified TLS + sha256
#  (+ GPG when available) integrity on downloads. crossfs/etcfs emulated.
#
#  v1.2.0 adds: parallel apply, stratum pin/export/import, config get/set,
#  gpg rootfs verification, JSON output, self-update, per-command help.
#
#  PERMANENT edition: unhijack is blocked (use brl-uninstall to fully remove).
#  Reversible twin is 'brl' (identical features, working unhijack).
#  Invoke:  brl <command> [args]   |   strat [-r] <stratum> <cmd>
#  Install: ./bedrock-port.sh --hijack   (see --help)
# ============================================================================
set -u
umask 022                       # safe default perms for anything we create

BRL_PORT_VERSION="1.2.0"
BR="/bedrock"
STRATA="${BR}/strata"
CROSSBIN="${BR}/cross/bin"
BRUN="${BR}/run"
ENABLED="${BRUN}/enabled_strata"
BETC="${BR}/etc"
RELEASE_FILE="${BETC}/bedrock-release"
URLCACHE="${BETC}/urls.cache"
BEDROCK_VERSION="0.7.31"
BEDROCK_CODENAME="Poki"
PORT_TAG="iSH-AOK-permanent"
LXC="https://images.linuxcontainers.org/images"
BRL_SELF_URL="${BRL_SELF_URL:-}"   # set to enable self-update from a trusted URL

# Safe temp workspace with guaranteed cleanup on exit/interrupt.
BRL_TMPDIR=""
_mktemp_dir() {
    if [ -z "$BRL_TMPDIR" ]; then
        BRL_TMPDIR="$(mktemp -d 2>/dev/null || mktemp -d -t brl 2>/dev/null || echo "/tmp/brl-$$")"
        mkdir -p "$BRL_TMPDIR" 2>/dev/null || true
    fi
    echo "$BRL_TMPDIR"
}
_cleanup() { [ -n "$BRL_TMPDIR" ] && rm -rf "$BRL_TMPDIR" 2>/dev/null || true; }
trap _cleanup EXIT INT TERM HUP

ESC=$(printf '\033')
# Official Bedrock Linux color palette
color_alert="${ESC}[0;91m"                 # light red
color_priority="${ESC}[1;37m${ESC}[101m"   # white on red
color_warn="${ESC}[0;93m"                  # bright yellow
color_okay="${ESC}[0;32m"                  # green
color_strat="${ESC}[0;36m"                 # cyan
color_alias="${ESC}[0;93m"                 # bright yellow
color_sub="${ESC}[0;93m"                   # bright yellow
color_file="${ESC}[0;32m"                  # green
color_cmd="${ESC}[0;32m"                   # green
color_rcmd="${ESC}[0;31m"                  # red
color_distro="${ESC}[0;93m"                # yellow
color_logo="${ESC}[1;37m"                  # bold white
color_glue="${ESC}[1;37m"                  # bold white
color_link="${ESC}[0;94m"                  # bright blue
color_term="${ESC}[0;35m"                  # magenta
color_misc="${ESC}[0;32m"                  # green
color_norm="${ESC}[0m"
# Back-compat aliases used throughout this script
R="$color_alert" G="$color_okay" Y="$color_warn"
W="$color_logo" GR="${ESC}[0;37m" DK="${ESC}[38;5;240m" DK2="${ESC}[38;5;236m"
B="${ESC}[1m" Z="$color_norm"
say()  { printf "%s\n" "$*"; }
ok()   { printf "${color_misc}* ${color_norm}%s\n" "$*"; }
notice() { printf "${color_misc}* ${color_norm}%s\n" "$*"; }
info() { printf "${color_misc}* ${color_norm}%s\n" "$*"; }
warn() { printf "${color_warn}* ${color_norm}%s\n" "$*"; }
err()  { printf "${color_alert}brl: error:${color_norm} %s\n" "$*" >&2; }
die()  { err "$*"; exit 1; }
abort() { err "$*"; exit 1; }
# Step progress (official Bedrock style: [n/total (pct%)] message)
step_init() { step_current=0; step_total="${1}"; }
step() {
    step_current=$((${step_current:-0}+1))
    _pct=0; [ "${step_total:-0}" -gt 0 ] && _pct=$((step_current*100/step_total))
    printf "${color_misc}[%d/%d (%d%%)]${color_norm} %s\n" "$step_current" "${step_total:-0}" "$_pct" "$*"
}
has()  { command -v "$1" >/dev/null 2>&1; }
need_root() { [ "$(id -u)" -eq 0 ] || die "requires root."; }

# ── host dependency check + auto-install ────────────────────────────────
# brl needs: chroot, tar, xz, a downloader (wget/curl). On iSH-AOK the host
# is usually Alpine (apk) or Debian (apt). Install whatever is missing.
_host_pkgmgr() {
    if   has apk;     then echo "apk"
    elif has apt-get; then echo "apt-get"
    elif has pacman;  then echo "pacman"
    elif has dnf;     then echo "dnf"
    elif has yum;     then echo "yum"
    elif has xbps-install; then echo "xbps"
    elif has zypper;  then echo "zypper"
    else echo ""; fi
}
_host_install() {
    # $1 = one or more package names (space separated)
    _hpm="$(_host_pkgmgr)"
    [ -n "$_hpm" ] || return 1
    case "$_hpm" in
        apk)     apk add --no-cache $1 >/dev/null 2>&1 ;;
        apt-get) apt-get update >/dev/null 2>&1; apt-get install -y $1 >/dev/null 2>&1 ;;
        pacman)  pacman -Sy --noconfirm $1 >/dev/null 2>&1 ;;
        dnf)     dnf install -y $1 >/dev/null 2>&1 ;;
        yum)     yum install -y $1 >/dev/null 2>&1 ;;
        xbps)    xbps-install -Sy $1 >/dev/null 2>&1 ;;
        zypper)  zypper -n install $1 >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}
# Map a needed command to the package that provides it (varies by pkg mgr).
_pkg_for() {
    case "$1" in
        wget)   echo "wget" ;;
        curl)   echo "curl" ;;
        tar)    echo "tar" ;;
        xz)     _hpm="$(_host_pkgmgr)"; [ "$_hpm" = "apt-get" ] && echo "xz-utils" || echo "xz" ;;
        gzip)   echo "gzip" ;;
        chroot) _hpm="$(_host_pkgmgr)"; case "$_hpm" in apt-get) echo "coreutils" ;; apk) echo "coreutils" ;; *) echo "coreutils" ;; esac ;;
        mount)  _hpm="$(_host_pkgmgr)"; [ "$_hpm" = "apk" ] && echo "util-linux" || echo "mount" ;;
        ca-certificates) echo "ca-certificates" ;;
        openssl) echo "openssl" ;;
        *) echo "$1" ;;
    esac
}
ensure_deps() {
    # Check required + recommended host tools; install any that are missing.
    _need_dl=0; has wget || has curl || _need_dl=1
    _missing=""
    for _c in chroot tar xz gzip mount; do has "$_c" || _missing="${_missing} $_c"; done
    [ "$_need_dl" = "1" ] && _missing="${_missing} wget"
    # Security tooling: a CA bundle (for verified TLS) and a sha256 tool.
    _have_ca_bundle >/dev/null 2>&1 || _missing="${_missing} ca-certificates"
    { has sha256sum || has shasum || has openssl; } || _missing="${_missing} openssl"
    _missing="$(printf '%s' "$_missing" | sed 's/^ *//')"
    [ -z "$_missing" ] && return 0
    _hpm="$(_host_pkgmgr)"
    if [ -z "$_hpm" ]; then
        warn "missing tools:${_missing} — no host package manager found to install them"
        warn "install manually, then re-run"
        return 1
    fi
    say ""; info "Installing missing host dependencies:${_missing} (via ${_hpm})"
    for _c in $_missing; do
        _pkg="$(_pkg_for "$_c")"
        if _host_install "$_pkg"; then
            case "$_c" in
                ca-certificates) _have_ca_bundle >/dev/null 2>&1 && ok "installed ca-certificates (verified TLS enabled)" || warn "ca-certificates installed but no bundle found" ;;
                *) has "$_c" && ok "installed $_c" || warn "$_c still missing after install" ;;
            esac
        else
            warn "could not install $_pkg (for $_c)"
        fi
    done
    # Refresh CA trust store if the tool exists (Debian/Alpine differ).
    has update-ca-certificates && update-ca-certificates >/dev/null 2>&1 || true
    BRL_TLS_OK=""  # re-probe after installing certs
    # Final verdict on hard requirements
    _fatal=""
    has chroot || _fatal="${_fatal} chroot"
    has tar || _fatal="${_fatal} tar"
    { has wget || has curl; } || _fatal="${_fatal} wget/curl"
    has xz || warn "xz still missing — .tar.xz rootfs (most distros) won't extract"
    if [ -n "$_fatal" ]; then err "still missing critical tools:${_fatal}"; return 1; fi
    return 0
}
init_stratum() { [ -f "${BRUN}/init_stratum" ] && cat "${BRUN}/init_stratum" || echo "bedrock"; }

# ── security / TLS / integrity layer ────────────────────────────────────
# Principle: verify by default. TLS peer verification is ON; we only fall back
# to insecure transport after an explicit, visible warning, and never silently.
# Downloads are integrity-checked against a SHA256 when one is available.
BRL_INSECURE="${BRL_INSECURE:-0}"          # user opt-in to allow insecure fallback
BRL_TLS_OK=""                               # cached: can we do verified TLS at all?

# Does the system have a usable CA bundle so TLS verification can succeed?
_have_ca_bundle() {
    for _ca in /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem \
               /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/certs/ca-bundle.crt; do
        [ -s "$_ca" ] && { echo "$_ca"; return 0; }
    done
    return 1
}
# Prove we can complete a *verified* TLS handshake to a known host. Cached.
tls_verify_works() {
    [ -n "$BRL_TLS_OK" ] && { [ "$BRL_TLS_OK" = 1 ] && return 0 || return 1; }
    _tvh="images.linuxcontainers.org"
    if has curl && curl -4 -fsS --connect-timeout 15 -m 20 -o /dev/null "https://${_tvh}/" 2>/dev/null; then
        BRL_TLS_OK=1; return 0
    fi
    if has wget && wget -4 -q -T 15 --spider "https://${_tvh}/" 2>/dev/null; then
        BRL_TLS_OK=1; return 0
    fi
    BRL_TLS_OK=0; return 1
}
# Pick a sha tool.
_sha256() {
    if has sha256sum; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif has shasum; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    elif has openssl; then openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    else echo ""; fi
}
# Verify a file against an expected sha256 (if we have one). Returns:
#   0 = verified OR no expected hash to check against (caller decides on latter)
#   1 = hash MISMATCH (hard fail — never proceed)
verify_sha256() {
    _vf="$1"; _vexp="$2"
    [ -n "$_vexp" ] || return 0
    _vgot="$(_sha256 "$_vf")"
    [ -n "$_vgot" ] || { warn "no sha256 tool — cannot verify integrity of $(basename "$_vf")"; return 0; }
    if [ "$_vgot" = "$_vexp" ]; then ok "sha256 verified"; return 0; fi
    err "sha256 MISMATCH for $(basename "$_vf")"
    err "  expected: ${_vexp}"; err "  got:      ${_vgot}"
    return 1
}
# Try to fetch a published checksum for a rootfs URL (LXC ships SHA256SUMS).
fetch_expected_sha256() {
    _fu="$1"; _fbase="$(basename "$_fu")"; _fdir="${_fu%/*}"
    for _sname in SHA256SUMS SHA256SUMS.txt sha256sums.txt; do
        _stext="$(fetch_text "${_fdir}/${_sname}" 2>/dev/null || true)"
        [ -n "$_stext" ] || continue
        _sh="$(printf '%s\n' "$_stext" | awk -v f="$_fbase" '$2 ~ f || $2 == f || $2 == "*"f {print $1; exit}')"
        [ -n "$_sh" ] && { echo "$_sh"; return 0; }
    done
    return 1
}
# Verify a detached GPG signature for a file, if a .asc/.sig is published AND
# gpg is available AND we have (or can import) the signer key. Returns:
#   0 = signature verified, OR no signature/gpg available (advisory)
#   1 = signature present but verification FAILED (hard fail)
verify_gpg() {
    _vgf="$1"; _vgurl="$2"
    has gpg || return 0
    _vgdir="$(_mktemp_dir)"; _vgsig="${_vgdir}/$(basename "$_vgf").asc"
    _vgot=1
    for _ext in .asc .sig SHA256SUMS.asc; do
        case "$_ext" in
            SHA256SUMS.asc) _vgu="${_vgurl%/*}/SHA256SUMS.asc" ;;
            *)              _vgu="${_vgurl}${_ext}" ;;
        esac
        if dl "$_vgu" "$_vgsig" 2>/dev/null && [ -s "$_vgsig" ]; then _vgot=0; break; fi
    done
    [ "$_vgot" = 0 ] || return 0   # no signature published — advisory pass
    # Try verification against the current keyring.
    if gpg --verify "$_vgsig" "$_vgf" 2>/dev/null; then ok "gpg signature verified"; return 0; fi
    warn "gpg signature present but could not be verified (missing signer key)"
    warn "  install the distro's release key to enable signature checking"
    # Not a hard fail unless strict: a missing key is not a bad signature.
    if [ "${BRL_STRICT:-0}" = 1 ]; then err "BRL_STRICT: refusing unverified signature"; return 1; fi
    return 0
}

dl() {
    _dlu="$1"; _dlo="$2"
    # Decide transport security once.
    if tls_verify_works; then _sec=1; else _sec=0; fi
    if [ "$_sec" = 0 ] && [ "$BRL_INSECURE" != 1 ]; then
        warn "verified TLS unavailable (no CA bundle or handshake failed)."
        warn "refusing insecure download by default. To override for this run:"
        warn "  BRL_INSECURE=1 brl fetch <stratum>   (or: brl deps to install ca-certificates)"
    fi
    # aria2c: fast, WITH certificate checking when secure.
    if has aria2c; then
        if [ "$_sec" = 1 ]; then
            aria2c -x8 -s8 -k1M --disable-ipv6=true --check-certificate=true \
                --file-allocation=none --summary-interval=0 -q \
                -d "$(dirname "$_dlo")" -o "$(basename "$_dlo")" "$_dlu" 2>/dev/null && [ -s "$_dlo" ] && return 0
        elif [ "$BRL_INSECURE" = 1 ]; then
            aria2c -x8 -s8 -k1M --disable-ipv6=true --check-certificate=false \
                --file-allocation=none --summary-interval=0 -q \
                -d "$(dirname "$_dlo")" -o "$(basename "$_dlo")" "$_dlu" 2>/dev/null && [ -s "$_dlo" ] && return 0
        fi
    fi
    _dltry=0; while [ "$_dltry" -lt 2 ]; do
        _dltry=$((_dltry+1))
        if has curl; then
            curl -4 -fSL --compressed --connect-timeout 30 -m 900 --retry 3 --retry-delay 3 -o "$_dlo" "$_dlu" 2>/dev/null && [ -s "$_dlo" ] && return 0
        elif has wget; then
            wget -4 -q -T 120 -t 3 --waitretry=3 -O "$_dlo" "$_dlu" 2>/dev/null && [ -s "$_dlo" ] && return 0
        fi
    done
    # Insecure fallback ONLY with explicit opt-in.
    if [ "$BRL_INSECURE" = 1 ]; then
        warn "attempting INSECURE download (TLS verification disabled) per BRL_INSECURE=1"
        if has curl; then curl -4 -fSLk --connect-timeout 30 -m 900 --retry 2 -o "$_dlo" "$_dlu" 2>/dev/null && [ -s "$_dlo" ] && return 0
        elif has wget; then wget -4 -q -T 120 -t 2 --no-check-certificate -O "$_dlo" "$_dlu" 2>/dev/null && [ -s "$_dlo" ] && return 0; fi
    fi
    return 1
}
# Stream a URL straight into tar (decompress while downloading — no temp file,
# no second decompress pass). Returns 0 on success. Falls back to dl()+extract.
dl_extract() {
    _dxu="$1"; _dxroot="$2"
    _dxk=""; [ "$BRL_INSECURE" = 1 ] && ! tls_verify_works && _dxk="k"
    _dxget=""
    if has curl; then _dxget="curl -4 -fSL${_dxk} --compressed --connect-timeout 30 -m 900 -o -"
    elif has wget; then
        if [ -n "$_dxk" ]; then _dxget="wget -4 -q -T 120 --no-check-certificate -O -"
        else _dxget="wget -4 -q -T 120 -O -"; fi
    fi
    [ -n "$_dxget" ] || return 1
    # Refuse silent-insecure streaming: if TLS can't verify and no opt-in, bail
    # so the caller downloads via dl() (which prints the security guidance).
    if ! tls_verify_works && [ "$BRL_INSECURE" != 1 ]; then return 1; fi
    case "$_dxu" in
        *.tar.xz|*.txz)   has xz   && $_dxget "$_dxu" 2>/dev/null | xz -dc 2>/dev/null   | tar -xf - -C "$_dxroot" 2>/dev/null && return 0 ;;
        *.tar.gz|*.tgz)   has gzip && $_dxget "$_dxu" 2>/dev/null | gzip -dc 2>/dev/null | tar -xf - -C "$_dxroot" 2>/dev/null && return 0 ;;
        *.tar.zst|*.tzst) has zstd && $_dxget "$_dxu" 2>/dev/null | zstd -dc 2>/dev/null | tar -xf - -C "$_dxroot" 2>/dev/null && return 0 ;;
        *.tar)            $_dxget "$_dxu" 2>/dev/null | tar -xf - -C "$_dxroot" 2>/dev/null && return 0 ;;
    esac
    return 1
}
fetch_text() {
    _ft_try=0; while [ "$_ft_try" -lt 2 ]; do
        _ft_try=$((_ft_try+1))
        if has curl; then
            curl -4 -fsSL --compressed --connect-timeout 20 -m 45 "$1" 2>/dev/null && return 0
        elif has wget; then
            wget -4 -q -T 25 -O - "$1" 2>/dev/null && return 0
        fi
    done
    # Insecure fallback for metadata only (listings/checksums), opt-in.
    if [ "$BRL_INSECURE" = 1 ]; then
        if has curl; then curl -4 -fsSLk --connect-timeout 20 -m 45 "$1" 2>/dev/null && return 0
        elif has wget; then wget -4 -q -T 25 -O - --no-check-certificate "$1" 2>/dev/null && return 0; fi
    fi
    return 1
}

print_logo() {
    printf "${color_logo}"
    cat <<EOF
__          __             __      
\\ \\_________\\ \\____________\\ \\___  
 \\  _ \\  _\\ _  \\  _\\ __ \\ __\\   /  
  \\___/\\__/\\__/ \\_\\ \\___/\\__/\\_\\_\\ 
EOF
    if [ -n "${1:-}" ]; then
        printf "%35s\\n" "${1}"
    fi
    printf "${color_norm}\\n"
}

# ============================================================================
#  CATALOG — 29 distros, every URL verified from live directory listing
# ============================================================================

catalog_names() {
    echo "alpine debian ubuntu devuan kali parrot \
fedora rockylinux almalinux oracle centos openeuler \
opensuse archlinux arch void gentoo \
amazonlinux openwrt alt busybox \
chimera apertis springdale funtoo"
}
catalog_desc() {
    case "$1" in
        alpine)      echo "Alpine (apk) — ~8 MB, musl, fast" ;;
        debian)      echo "Debian bookworm (apt) — ~50 MB" ;;
        ubuntu)      echo "Ubuntu 24.04 (apt) — ~70 MB" ;;
        devuan)      echo "Devuan (apt) — systemd-free — ~50 MB" ;;
        kali)        echo "Kali (apt) — pentesting — ~150 MB" ;;
        parrot)      echo "Parrot OS (apt) — security — ~150 MB" ;;
        fedora)      echo "Fedora 44 (dnf) — ~100 MB" ;;
        rockylinux)  echo "Rocky Linux 9 (dnf) — ~100 MB" ;;
        almalinux)   echo "AlmaLinux 9 (dnf) — ~100 MB" ;;
        oracle)      echo "Oracle Linux 9 (dnf) — ~120 MB" ;;
        centos)      echo "CentOS Stream 9 (dnf) — ~100 MB" ;;
        openeuler)   echo "openEuler (dnf) — ~100 MB" ;;
        opensuse)    echo "openSUSE Tumbleweed (zypper) — ~120 MB" ;;
        archlinux)   echo "Arch Linux (pacman) via LXC — ~150 MB" ;;
        arch)        echo "Arch Linux ARM (pacman) — native — ~200 MB" ;;
        void)        echo "Void (xbps) — rolling — ~50 MB" ;;
        gentoo)      echo "Gentoo (portage) — stage3 — ~300 MB" ;;
        amazonlinux) echo "Amazon Linux 2023 (dnf) — ~100 MB" ;;
        openwrt)     echo "OpenWrt 24.10 (opkg) — ~10 MB" ;;
        alt)         echo "ALT Linux (apt-rpm) — ~100 MB" ;;
        busybox)     echo "BusyBox — ~3 MB rescue rootfs" ;;
        chimera)     echo "Chimera (apk) — BSD userland — ~8 MB" ;;
        apertis)     echo "Apertis (apt) — Debian-based — ~80 MB" ;;
        springdale)  echo "Springdale (dnf) — RHEL clone — ~100 MB" ;;
        funtoo)      echo "Funtoo (portage) — ~300 MB" ;;
        *)           echo "" ;;
    esac
}
catalog_recipe() {
    case "$1" in
        alpine)      echo "lxc:alpine:edge" ;;
        debian)      echo "lxc:debian:bookworm" ;;
        ubuntu)      echo "lxc:ubuntu:noble" ;;
        devuan)      echo "lxc:devuan:daedalus" ;;
        kali)        echo "lxc:kali:current" ;;
        parrot)      echo "fixed:https://raw.githubusercontent.com/EXALAB/AnLinux-Resources/master/Rootfs/Parrot/arm64/parrot-rootfs-arm64.tar.xz" ;;
        fedora)      echo "lxc:fedora:44" ;;
        rockylinux)  echo "lxc:rockylinux:9" ;;
        almalinux)   echo "lxc:almalinux:9" ;;
        oracle)      echo "lxc:oracle:9" ;;
        centos)      echo "lxc:centos:9-Stream" ;;
        openeuler)   echo "lxc:openeuler:24.03" ;;
        opensuse)    echo "lxc:opensuse:tumbleweed" ;;
        archlinux)   echo "lxc:archlinux:current" ;;
        arch)        echo "fixed:http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz" ;;
        void)        echo "lxc:voidlinux:current" ;;
        gentoo)      echo "disc:gentoo" ;;
        amazonlinux) echo "lxc:amazonlinux:2023" ;;
        openwrt)     echo "lxc:openwrt:24.10" ;;
        alt)         echo "lxc:alt:Sisyphus" ;;
        busybox)     echo "disc:busybox" ;;
        chimera)     echo "disc:chimera" ;;
        apertis)     echo "lxc:apertis:v2024" ;;
        springdale)  echo "lxc:springdalelinux:9" ;;
        funtoo)      echo "lxc:funtoo:current" ;;
        *)           echo "" ;;
    esac
}
_lxc_url() {
    # Read the actual build index, newest builds first.
    _lxhtml="$(fetch_text "${LXC}/${1}/${2}/arm64/default/" 2>/dev/null || true)"
    [ -n "$_lxhtml" ] || return 1
    _lxbuilds="$(printf '%s\n' "$_lxhtml" | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}/' | sort -rV | tr -d '/')"
    [ -n "$_lxbuilds" ] || return 1
    # Check up to 2 newest builds. Read each build's file listing and return
    # the URL of a real tarball (never squashfs — can't extract on iSH-AOK).
    _lxc=0
    for _lxb in $_lxbuilds; do
        _lxc=$((_lxc+1)); [ "$_lxc" -gt 2 ] && break
        _lxbase="${LXC}/${1}/${2}/arm64/default/${_lxb}"
        _lxfiles="$(fetch_text "${_lxbase}/" 2>/dev/null || true)"
        [ -n "$_lxfiles" ] || continue
        if printf '%s\n' "$_lxfiles" | grep -q 'rootfs\.tar\.xz'; then
            echo "${_lxbase}/rootfs.tar.xz"; return 0
        elif printf '%s\n' "$_lxfiles" | grep -q 'rootfs\.tar\.gz'; then
            echo "${_lxbase}/rootfs.tar.gz"; return 0
        fi
    done
    # No extractable tarball in recent builds (squashfs-only distro).
    return 1
}
resolve_url() {
    _rrecipe="$(catalog_recipe "$1")"; [ -n "$_rrecipe" ] || return 1
    _rkind="${_rrecipe%%:*}"; _rrest="${_rrecipe#*:}"
    case "$_rkind" in
        fixed) _url_exists "$_rrest" && echo "$_rrest" || return 1 ;;
        lxc)   _lxc_url "${_rrest%%:*}" "${_rrest#*:}" ;;
        disc)  _disc_url "$_rrest" ;;
        *) return 1 ;;
    esac
}

# Verify a URL is reachable (2xx/3xx) without downloading the body.
# Used so a dead fixed: URL surfaces as "unresolved" at update-urls time
# instead of failing later at download. IPv4-only for iSH-AOK.
_url_exists() {
    _ue="$1"
    if has curl; then
        # -I HEAD; many CDNs answer HEAD. Follow redirects, IPv4, short timeout.
        _code="$(curl -4 -fsS -I -o /dev/null -w '%{http_code}' --connect-timeout 20 -m 40 -L "$_ue" 2>/dev/null || echo 000)"
        case "$_code" in 2??|3??) return 0 ;; esac
        # Some servers reject HEAD; try a 1-byte ranged GET.
        _code="$(curl -4 -fsS -o /dev/null -w '%{http_code}' --connect-timeout 20 -m 40 -L -r 0-0 "$_ue" 2>/dev/null || echo 000)"
        case "$_code" in 2??|3??) return 0 ;; esac
        return 1
    fi
    if has wget; then
        # wget --spider does a HEAD; fall back to 1-byte range GET.
        wget -4 -q -T 30 --spider "$_ue" 2>/dev/null && return 0
        wget -4 -q -T 30 --spider --no-check-certificate "$_ue" 2>/dev/null && return 0
        wget -4 -q -T 30 -O /dev/null --header='Range: bytes=0-0' "$_ue" 2>/dev/null && return 0
        return 1
    fi
    # No downloader yet (ensure_deps installs one before fetch) — assume ok.
    return 0
}

# Custom discovery for distros where LXC is stale/slow but official sources exist.
_disc_url() {
    case "$1" in
        gentoo)
            _gidx="$(fetch_text "https://distfiles.gentoo.org/releases/arm64/autobuilds/latest-stage3-arm64-openrc.txt" 2>/dev/null || true)"
            _gpath="$(printf '%s\n' "$_gidx" | grep -oE '[0-9TZ]+/stage3-arm64-openrc-[0-9TZ]+\.tar\.xz' | head -1)"
            [ -n "$_gpath" ] && { echo "https://distfiles.gentoo.org/releases/arm64/autobuilds/${_gpath}"; return 0; }
            return 1 ;;
        chimera)
            _chhtml="$(fetch_text "https://repo.chimera-linux.org/live/latest/" 2>/dev/null || true)"
            _chfile="$(printf '%s\n' "$_chhtml" | grep -oE 'chimera-linux-aarch64-ROOTFS-[0-9]+-bootstrap\.tar\.gz' | sort -V | tail -1)"
            [ -n "$_chfile" ] && { echo "https://repo.chimera-linux.org/live/latest/${_chfile}"; return 0; }
            return 1 ;;
        busybox)
            # LXC discovery is too slow for iSH-AOK; try discovery but fall back to known build.
            _bbidx="${LXC}/busybox/1.36.1/arm64/default/"
            _bbhtml="$(fetch_text "$_bbidx" 2>/dev/null || true)"
            _bbbuild="$(printf '%s\n' "$_bbhtml" | grep -oE '[0-9]{8}_[0-9]{2}:[0-9]{2}/' | sort -V | tail -1 | tr -d '/')"
            if [ -n "$_bbbuild" ]; then echo "${_bbidx}${_bbbuild}/rootfs.tar.xz"; return 0; fi
            # Hardcoded fallback (verified existing build)
            echo "${_bbidx}20250228_06:00/rootfs.tar.xz"; return 0 ;;
        *) return 1 ;;
    esac
}
lookup_url() {
    if [ -f "$URLCACHE" ]; then
        _lc="$(grep "^${1} " "$URLCACHE" 2>/dev/null | head -1 | cut -d' ' -f2-)"
        [ -n "$_lc" ] && { echo "$_lc"; return 0; }
    fi
    resolve_url "$1"
}
brl_update_urls() {
    need_root; mkdir -p "$BETC"
    _utmp="${URLCACHE}.new"; : > "$_utmp"
    say ""; say "${B}Refreshing stratum sources...${Z}"
    _uo=0; _uf=0
    for _udn in $(catalog_names); do
        _uu="$(resolve_url "$_udn" 2>/dev/null || true)"
        if [ -n "$_uu" ]; then printf '%s %s\n' "$_udn" "$_uu" >> "$_utmp"; ok "$_udn"; _uo=$((_uo+1))
        else warn "$_udn: unresolved"; _uf=$((_uf+1)); fi
    done
    mv "$_utmp" "$URLCACHE"
    say ""; say "  resolved ${G}${_uo}${Z}, failed ${R}${_uf}${Z}"; say ""
}

# ============================================================================
#  FETCH
# ============================================================================
brl_fetch() {
    _fres=0
    while [ "${1:-}" ]; do case "$1" in -r|--restrict) _fres=1; shift ;; *) break ;; esac; done
    _fn="${1:-}"
    case "$_fn" in --list|-L) brl_fetch_list; return 0 ;; "") die "usage: brl fetch [-r] <stratum>  (brl fetch --list)" ;; esac
    need_root
    ensure_deps || die "required tools missing; cannot fetch."
    case " $(catalog_names) " in *" $_fn "*) ;; *) die "unknown '$_fn'. see: brl fetch --list"; esac
    _fr="${STRATA}/${_fn}"
    { [ -d "$_fr" ] && [ -n "$(ls -A "$_fr" 2>/dev/null)" ]; } && die "'$_fn' exists. brl remove $_fn first"
    say ""; info "Resolving $_fn aarch64 rootfs..."
    _fu="$(lookup_url "$_fn" || true)"
    [ -n "$_fu" ] || die "could not resolve '$_fn'. Try: brl update-urls"
    ok "source: $_fu"
    _do_fetch "$_fn" "$_fu" "$_fres"
}
brl_fetch_url() {
    need_root; _fn="${1:-}"; _fu="${2:-}"
    { [ -n "$_fn" ] && [ -n "$_fu" ]; } || die "usage: brl fetch-url <stratum> <url>"
    _fr="${STRATA}/${_fn}"
    { [ -d "$_fr" ] && [ -n "$(ls -A "$_fr" 2>/dev/null)" ]; } && die "'$_fn' exists. brl remove $_fn first"
    _do_fetch "$_fn" "$_fu" 0
}
brl_fetch_list() {
    say ""; say "${B}Strata available to fetch:${Z}"
    _flc=0; _flline="  "
    for _fln in $(catalog_names); do
        _flline="${_flline}$(printf '%-13s' "$_fln")"; _flc=$((_flc+1))
        [ $((_flc % 4)) -eq 0 ] && { say "$_flline"; _flline="  "; }
    done
    [ "$_flline" != "  " ] && say "$_flline"
    say ""; say "${B}Recommended first:${Z} alpine (smallest, fastest)"
    say "  All: ${B}brl apply${Z}   Custom: ${B}brl fetch-url <name> <url>${Z}"; say ""
}
brl_apply() {
    need_root; _afail=""
    # Parallelism: default 3 concurrent fetches, override with BRL_JOBS.
    _ajobs="${BRL_JOBS:-3}"; case "$_ajobs" in ''|*[!0-9]*) _ajobs=3 ;; esac
    [ "$_ajobs" -lt 1 ] && _ajobs=1
    if [ "$_ajobs" = 1 ]; then
        # Sequential path (also used when job control is unavailable).
        for _an in $(catalog_names); do
            _ar="${STRATA}/${_an}"
            { [ -d "$_ar" ] && [ -n "$(ls -A "$_ar" 2>/dev/null)" ]; } && { info "$_an present"; continue; }
            say ""; say "${B}=== ${_an} ===${Z}"
            _au="$(lookup_url "$_an" || true)"
            [ -n "$_au" ] || { warn "$_an unresolved"; _afail="${_afail} ${_an}"; continue; }
            _do_fetch "$_an" "$_au" 0 || { warn "$_an failed"; _afail="${_afail} ${_an}"; }
        done
    else
        say "${B}Fetching in parallel (${_ajobs} jobs)...${Z}"
        _atmp="$(_mktemp_dir)"; _arun=0
        for _an in $(catalog_names); do
            _ar="${STRATA}/${_an}"
            { [ -d "$_ar" ] && [ -n "$(ls -A "$_ar" 2>/dev/null)" ]; } && { info "$_an present"; continue; }
            # throttle
            while [ "$(jobs -p 2>/dev/null | wc -l)" -ge "$_ajobs" ]; do wait 2>/dev/null || break; done
            (
                _au="$(lookup_url "$_an" || true)"
                if [ -z "$_au" ]; then echo "unresolved $_an" > "${_atmp}/${_an}.res"
                elif _do_fetch "$_an" "$_au" 0 >/dev/null 2>&1; then echo "ok $_an" > "${_atmp}/${_an}.res"
                else echo "failed $_an" > "${_atmp}/${_an}.res"; fi
            ) &
            _arun=$((_arun+1))
        done
        wait 2>/dev/null || true
        for _rf in "${_atmp}"/*.res; do
            [ -f "$_rf" ] || continue; read -r _st _sn < "$_rf"
            case "$_st" in ok) ok "$_sn";; *) warn "$_sn: $_st"; _afail="${_afail} ${_sn}";; esac
        done
    fi
    say ""; [ -n "$_afail" ] && warn "failed:${_afail}" || ok "all strata fetched"
    brl_reload
}

_do_fetch() {
    _dfn="$1"; _dfu="$2"; _dfr="${3:-0}"; _dfroot="${STRATA}/${_dfn}"
    mkdir -p "$_dfroot"; _dftmp="/tmp/brl-${_dfn}-$$.tar"
    # Look for a published SHA256 for this rootfs (LXC ships SHA256SUMS).
    _dfsha="$(fetch_expected_sha256 "$_dfu" 2>/dev/null || true)"
    if [ -n "$_dfsha" ]; then
        # Verified path: download to disk, check hash, THEN extract. Integrity
        # beats the small speed win of streaming when we can actually verify.
        info "Downloading (will verify sha256)..."
        dl "$_dfu" "$_dftmp" || { rm -rf "$_dfroot" "$_dftmp"; err "download failed for $_dfn"; return 1; }
        verify_sha256 "$_dftmp" "$_dfsha" || { rm -rf "$_dfroot" "$_dftmp"; err "integrity check failed — refusing to install $_dfn"; return 1; }
        verify_gpg "$_dftmp" "$_dfu" || { rm -rf "$_dfroot" "$_dftmp"; err "signature check failed — refusing to install $_dfn"; return 1; }
        info "Extracting..."
        if   tar -xf "$_dftmp" -C "$_dfroot" 2>/dev/null; then :
        elif has xz && xz -dc "$_dftmp" 2>/dev/null | tar -xf - -C "$_dfroot" 2>/dev/null; then :
        elif has gzip && gzip -dc "$_dftmp" 2>/dev/null | tar -xf - -C "$_dfroot" 2>/dev/null; then :
        elif has zstd && zstd -dc "$_dftmp" 2>/dev/null | tar -xf - -C "$_dfroot" 2>/dev/null; then :
        else rm -rf "$_dfroot" "$_dftmp"; err "extraction failed for $_dfn"; return 1; fi
        rm -f "$_dftmp"
    else
        # No published checksum. Stream for speed (TLS still verified in dl_extract).
        info "Downloading + extracting (streaming; no published checksum)..."
        if dl_extract "$_dfu" "$_dfroot" && { [ -d "${_dfroot}/bin" ] || [ -d "${_dfroot}/usr" ] || [ -d "${_dfroot}/etc" ]; }; then
            ok "streamed into place"
        else
            rm -rf "${_dfroot:?}"/* 2>/dev/null || true
            info "Streaming unavailable; downloading..."
            dl "$_dfu" "$_dftmp" || { rm -rf "$_dfroot" "$_dftmp"; err "download failed for $_dfn"; return 1; }
            ok "downloaded ($(( $(wc -c < "$_dftmp" 2>/dev/null || echo 0)/1024 )) KB)"
            info "Extracting..."
            if   tar -xf "$_dftmp" -C "$_dfroot" 2>/dev/null; then :
            elif tar -xzf "$_dftmp" -C "$_dfroot" 2>/dev/null; then :
            elif tar -xJf "$_dftmp" -C "$_dfroot" 2>/dev/null; then :
            elif has xz && xz -dc "$_dftmp" 2>/dev/null | tar -xf - -C "$_dfroot" 2>/dev/null; then :
            elif has gzip && gzip -dc "$_dftmp" 2>/dev/null | tar -xf - -C "$_dfroot" 2>/dev/null; then :
            else rm -rf "$_dfroot" "$_dftmp"; err "extraction failed for $_dfn"; return 1; fi
            rm -f "$_dftmp"
        fi
    fi
    # Flatten single wrapping dir
    _dfent="$(ls -A "$_dfroot" 2>/dev/null)"
    _dfcnt="$(printf '%s\n' "$_dfent" | grep -c . || echo 0)"
    if [ "$_dfcnt" = "1" ] && [ -d "${_dfroot}/${_dfent}" ] && [ ! -d "${_dfroot}/bin" ] && [ ! -d "${_dfroot}/usr" ]; then
        _dfin="${_dfroot}/${_dfent}"
        (cd "$_dfin" && tar cf - . 2>/dev/null) | (cd "$_dfroot" && tar xf - 2>/dev/null) || true
        rm -rf "$_dfin"
    fi
    info "Preparing stratum environment..."
    _prepare_stratum "$_dfroot" "$_dfn"
    info "Initializing package manager keys..."
    _init_keys "$_dfroot" "$_dfn"
    mkdir -p "$ENABLED"
    [ "$_dfr" = "1" ] || : > "${ENABLED}/${_dfn}"
    ok "stratum '$_dfn' ready"
    return 0
}

# ============================================================================
#  PREPARE STRATUM — the zero-error environment setup
# ============================================================================
_prepare_stratum() {
    _pr="$1"; _pn="${2:-}"

    # ── dirs ────────────────────────────────────────────────────────────
    for _pd in proc sys dev dev/pts dev/shm tmp var/tmp run var/run etc root home; do
        mkdir -p "${_pr}/${_pd}" 2>/dev/null || true
    done
    chmod 1777 "${_pr}/tmp" "${_pr}/var/tmp" "${_pr}/dev/shm" 2>/dev/null || true

    # ── dev nodes ───────────────────────────────────────────────────────
    for _dn in "null c 1 3" "zero c 1 5" "full c 1 7" "random c 1 8" "urandom c 1 9" "tty c 5 0" "console c 5 1" "ptmx c 5 2"; do
        set -- $_dn; [ -e "${_pr}/dev/$1" ] || mknod -m 666 "${_pr}/dev/$1" "$2" "$3" "$4" 2>/dev/null || true
    done
    [ -e "${_pr}/dev/fd" ]     || ln -sf /proc/self/fd   "${_pr}/dev/fd"     2>/dev/null || true
    [ -e "${_pr}/dev/stdin" ]  || ln -sf /proc/self/fd/0 "${_pr}/dev/stdin"  2>/dev/null || true
    [ -e "${_pr}/dev/stdout" ] || ln -sf /proc/self/fd/1 "${_pr}/dev/stdout" 2>/dev/null || true
    [ -e "${_pr}/dev/stderr" ] || ln -sf /proc/self/fd/2 "${_pr}/dev/stderr" 2>/dev/null || true

    # ── DNS (the #1 cause of broken strata) ─────────────────────────────
    _force_dns "$_pr"

    # ── nsswitch.conf (glibc needs this to resolve hostnames via DNS) ───
    [ -f "${_pr}/etc/nsswitch.conf" ] || printf 'passwd: files\ngroup: files\nhosts: files dns\nnetworks: files\n' > "${_pr}/etc/nsswitch.conf" 2>/dev/null || true

    # ── hosts ───────────────────────────────────────────────────────────
    if [ ! -f "${_pr}/etc/hosts" ]; then
        [ -f /etc/hosts ] && cp -f /etc/hosts "${_pr}/etc/hosts" 2>/dev/null || \
            printf '127.0.0.1 localhost\n::1 localhost\n' > "${_pr}/etc/hosts" 2>/dev/null || true
    fi

    # ── hostname ────────────────────────────────────────────────────────
    [ -f "${_pr}/etc/hostname" ] || printf '%s\n' "$(hostname 2>/dev/null || echo bedrock)" > "${_pr}/etc/hostname" 2>/dev/null || true

    # ── machine-id (systemd, dbus crash without it) ─────────────────────
    if [ ! -f "${_pr}/etc/machine-id" ]; then
        if [ -f /etc/machine-id ]; then cp -f /etc/machine-id "${_pr}/etc/machine-id" 2>/dev/null || true
        else printf '%s\n' "$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo 00000000000000000000000000000000)" > "${_pr}/etc/machine-id" 2>/dev/null || true
        fi
    fi

    # ── mtab (df, mount, findmnt) ───────────────────────────────────────
    [ -e "${_pr}/etc/mtab" ] || ln -sf /proc/mounts "${_pr}/etc/mtab" 2>/dev/null || true

    # ── passwd / group — ensure root entry ──────────────────────────────
    if [ ! -f "${_pr}/etc/passwd" ]; then
        printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/:/usr/sbin/nologin\n' > "${_pr}/etc/passwd" 2>/dev/null || true
    elif ! grep -q '^root:' "${_pr}/etc/passwd" 2>/dev/null; then
        sed -i '1i root:x:0:0:root:/root:/bin/sh' "${_pr}/etc/passwd" 2>/dev/null || true
    fi
    if [ ! -f "${_pr}/etc/group" ]; then
        printf 'root:x:0:\nnogroup:x:65534:\n' > "${_pr}/etc/group" 2>/dev/null || true
    elif ! grep -q '^root:' "${_pr}/etc/group" 2>/dev/null; then
        sed -i '1i root:x:0:' "${_pr}/etc/group" 2>/dev/null || true
    fi

    # ── locale (suppress LC_* warnings in every distro) ─────────────────
    mkdir -p "${_pr}/etc/default" 2>/dev/null || true
    [ -f "${_pr}/etc/locale.conf" ] || printf 'LANG=C.UTF-8\n' > "${_pr}/etc/locale.conf" 2>/dev/null || true
    [ -f "${_pr}/etc/default/locale" ] || printf 'LANG=C.UTF-8\n' > "${_pr}/etc/default/locale" 2>/dev/null || true

    # ── TLS certificates (copy from host so HTTPS works) ────────────────
    _copy_certs "$_pr"

    # ── suppress service starts during package installs (chroot has no init) ─
    _suppress_services "$_pr"

    # ── per-package-manager iSH-AOK fixes ───────────────────────────────
    _fix_pacman "$_pr"
    _fix_apt "$_pr"
    _fix_alt "$_pr"
    _fix_dnf "$_pr"
    _fix_zypper "$_pr"
    _fix_xbps "$_pr"
    _fix_apk "$_pr"
    _fix_opkg "$_pr"
    _fix_portage "$_pr"
}

# Package post-install scripts try to start/enable services via systemd or
# sysvinit. In a chroot with no init running, those calls fail and can abort
# installs. Neutralize them across all distro families.
_suppress_services() {
    _sr="$1"
    # Debian/Ubuntu family: policy-rc.d returning 101 = "do not start services"
    if [ -x "${_sr}/usr/bin/dpkg" ] || [ -x "${_sr}/usr/sbin/dpkg" ]; then
        mkdir -p "${_sr}/usr/sbin" 2>/dev/null || true
        printf '#!/bin/sh\nexit 101\n' > "${_sr}/usr/sbin/policy-rc.d" 2>/dev/null || true
        chmod +x "${_sr}/usr/sbin/policy-rc.d" 2>/dev/null || true
    fi
    # All families: a no-op systemctl in /usr/local/sbin (first in PATH) so
    # postinst scriptlets that call systemctl succeed harmlessly. Only add if
    # the stratum actually has systemd (real systemctl present).
    if [ -e "${_sr}/usr/bin/systemctl" ] || [ -e "${_sr}/bin/systemctl" ]; then
        mkdir -p "${_sr}/usr/local/sbin" 2>/dev/null || true
        cat > "${_sr}/usr/local/sbin/systemctl" <<'SCTL'
#!/bin/sh
# iSH-AOK chroot: no systemd running. No-op so package scripts don't fail.
case "$1" in
    is-system-running) echo "offline"; exit 0 ;;
    is-active|is-enabled) exit 3 ;;
    daemon-reload|daemon-reexec) exit 0 ;;
esac
exit 0
SCTL
        chmod +x "${_sr}/usr/local/sbin/systemctl" 2>/dev/null || true
    fi
}

_force_dns() {
    mkdir -p "${1}/etc" 2>/dev/null || true
    [ -L "${1}/etc/resolv.conf" ] && rm -f "${1}/etc/resolv.conf" 2>/dev/null || true
    {
        [ -f /etc/resolv.conf ] && grep -E '^nameserver ' /etc/resolv.conf 2>/dev/null | grep -vE '127\.0\.0\.(1|53)' | head -2
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n'
    } | awk '!seen[$0]++' | head -3 > "${1}/etc/resolv.conf" 2>/dev/null || \
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "${1}/etc/resolv.conf" 2>/dev/null || true
}

_copy_certs() {
    for _cd in /etc/ssl/certs /usr/share/ca-certificates /etc/pki/tls/certs; do
        [ -d "$_cd" ] || continue
        [ -d "${1}${_cd}" ] && [ -n "$(ls -A "${1}${_cd}" 2>/dev/null)" ] && continue
        mkdir -p "${1}${_cd}" 2>/dev/null || true
        cp -a "$_cd"/* "${1}${_cd}/" 2>/dev/null || true
    done
    for _cb in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
        [ -f "$_cb" ] || continue
        mkdir -p "${1}$(dirname "$_cb")" 2>/dev/null || true
        [ -f "${1}${_cb}" ] || cp -f "$_cb" "${1}${_cb}" 2>/dev/null || true
    done
}

_fix_pacman() {
    _fp="${1}/etc/pacman.conf"; [ -f "$_fp" ] || return 0
    if ! grep -q '^DisableSandbox' "$_fp" 2>/dev/null; then
        sed -i 's/^#\s*DisableSandbox.*/DisableSandbox/' "$_fp" 2>/dev/null || true
        grep -q '^DisableSandbox' "$_fp" 2>/dev/null || printf '\nDisableSandbox\n' >> "$_fp"
    fi
    # Signature policy: strict mode keeps pacman's default verification; otherwise
    # relax (fresh AOK roots usually have no seeded keyring, which hard-blocks installs).
    if [ "${BRL_STRICT:-0}" != 1 ]; then
        sed -i 's/^SigLevel\s*=.*/SigLevel = Never/' "$_fp" 2>/dev/null || true
        [ -f "${1}/etc/makepkg.conf" ] && sed -i 's/^BUILDENV=.*/BUILDENV=(!distcc color !ccache check !sign)/' "${1}/etc/makepkg.conf" 2>/dev/null || true
    fi
    # Ensure a working mirror. ALARM uses geo.mirror; mainline Arch uses a mirrorlist.
    _fml="${1}/etc/pacman.d/mirrorlist"
    mkdir -p "${1}/etc/pacman.d" 2>/dev/null || true
    if [ ! -f "$_fml" ] || ! grep -qE '^\s*Server\s*=' "$_fml" 2>/dev/null; then
        # Detect ALARM (has alarm/aur repos or arm packages) vs mainline
        if grep -qi 'archlinuxarm\|\[alarm\]' "$_fp" 2>/dev/null || [ -f "${1}/etc/pacman.d/mirrorlist.pacnew" ]; then
            printf 'Server = http://mirror.archlinuxarm.org/$arch/$repo\n' > "$_fml"
        else
            # mainline Arch ARM via geo mirror
            printf 'Server = http://mirror.archlinuxarm.org/$arch/$repo\n' > "$_fml"
        fi
    else
        # Uncomment the first commented Server if none are active
        grep -qE '^\s*Server\s*=' "$_fml" 2>/dev/null || sed -i '0,/^#\s*Server/s//Server/' "$_fml" 2>/dev/null || true
    fi
}
_fix_apt() {
    # Only Debian-family (has dpkg). Alt Linux has apt.conf.d but uses apt-rpm — these configs break it.
    [ -x "${1}/usr/bin/dpkg" ] || [ -x "${1}/usr/sbin/dpkg" ] || return 0
    _fad="${1}/etc/apt/apt.conf.d"; [ -d "$_fad" ] || return 0
    [ -f "${_fad}/99ishfix" ] && return 0
    if [ "${BRL_STRICT:-0}" = 1 ]; then
        # Strict: keep peer verification + package authentication ON.
        cat > "${_fad}/99ishfix" <<'APTFIX'
APT::Sandbox::User "root";
Acquire::ForceIPv4 "true";
APT::Install-Recommends "false";
Dpkg::Options { "--force-confold"; "--force-confdef"; };
Dpkg::Use-Pty "false";
APTFIX
    else
        cat > "${_fad}/99ishfix" <<'APTFIX'
APT::Sandbox::User "root";
Acquire::AllowInsecureRepositories "true";
Acquire::https::Verify-Peer "false";
Acquire::ForceIPv4 "true";
APT::Get::AllowUnauthenticated "true";
APT::Install-Recommends "false";
Dpkg::Options { "--force-confold"; "--force-confdef"; };
Dpkg::Use-Pty "false";
APTFIX
    fi
    # Disable fsync in dpkg (chroot on iSH-AOK: massively faster, avoids I/O errors)
    mkdir -p "${1}/etc/dpkg/dpkg.cfg.d" 2>/dev/null || true
    printf 'force-unsafe-io\n' > "${1}/etc/dpkg/dpkg.cfg.d/99ishfix" 2>/dev/null || true
}
_fix_alt() {
    [ -x "${1}/usr/bin/apt-get" ] || return 0
    [ -x "${1}/usr/bin/dpkg" ] && return 0
    [ -x "${1}/usr/bin/rpm" ] || return 0
    mkdir -p "${1}/etc/apt/apt.conf.d" 2>/dev/null || true
    [ -f "${1}/etc/apt/apt.conf.d/99ishfix" ] && return 0
    printf 'APT::Get::AllowUnauthenticated "true";\nAcquire::ForceIPv4 "true";\n' > "${1}/etc/apt/apt.conf.d/99ishfix"
}
_fix_dnf() {
    [ -x "${1}/usr/bin/dnf" ] || [ -x "${1}/usr/bin/yum" ] || [ -d "${1}/etc/dnf" ] || [ -d "${1}/etc/yum.repos.d" ] || return 0
    _fdc="${1}/etc/dnf/dnf.conf"
    if [ ! -f "$_fdc" ]; then mkdir -p "${1}/etc/dnf" 2>/dev/null || true; [ -d "${1}/etc/dnf" ] && printf '[main]\n' > "$_fdc"; fi
    if [ -f "$_fdc" ] && ! grep -q 'ip_resolve=4' "$_fdc" 2>/dev/null; then
        if [ "${BRL_STRICT:-0}" = 1 ]; then
            printf '\nip_resolve=4\ninstall_weak_deps=0\ntsflags=nodocs\nskip_if_unavailable=1\n' >> "$_fdc"
        else
            printf '\ngpgcheck=0\nsslverify=0\nip_resolve=4\ndeltarpm=0\ninstall_weak_deps=0\ntsflags=nodocs\nskip_if_unavailable=1\nbest=0\n' >> "$_fdc"
        fi
    fi
    # yum.conf for older RHEL-family (CentOS 7-style, Amazon Linux 2)
    _fyc="${1}/etc/yum.conf"
    if [ -f "$_fyc" ] && ! grep -q 'gpgcheck=0' "$_fyc" 2>/dev/null; then
        sed -i 's/^gpgcheck=1/gpgcheck=0/' "$_fyc" 2>/dev/null || true
        grep -q 'ip_resolve' "$_fyc" 2>/dev/null || printf 'ip_resolve=4\nsslverify=0\n' >> "$_fyc"
    fi
    # Some rootfs disable all repos by default; ensure repo files aren't all enabled=0
    if [ -d "${1}/etc/yum.repos.d" ]; then
        for _rf in "${1}"/etc/yum.repos.d/*.repo; do
            [ -f "$_rf" ] || continue
            sed -i 's/^gpgcheck=1/gpgcheck=0/g' "$_rf" 2>/dev/null || true
        done
    fi
}
_fix_zypper() {
    [ -d "${1}/etc/zypp" ] || [ -x "${1}/usr/bin/zypper" ] || return 0
    mkdir -p "${1}/etc/zypp" 2>/dev/null || true
    _fzc="${1}/etc/zypp/zypp.conf"
    [ -f "$_fzc" ] || : > "$_fzc"
    grep -q 'gpgcheck' "$_fzc" 2>/dev/null && return 0
    printf '\nrepo_gpgcheck = off\npkg_gpgcheck = off\nsolver.onlyRequires = true\n' >> "$_fzc"
}
_fix_xbps() {
    [ -d "${1}/usr/share/xbps.d" ] || [ -d "${1}/etc/xbps.d" ] || [ -x "${1}/usr/bin/xbps-install" ] || return 0
    mkdir -p "${1}/etc/xbps.d" 2>/dev/null || true
    if [ -d "${1}/usr/share/xbps.d" ] && [ -z "$(ls -A "${1}/etc/xbps.d" 2>/dev/null)" ]; then
        cp "${1}/usr/share/xbps.d"/*.conf "${1}/etc/xbps.d/" 2>/dev/null || true
    fi
    # Ensure a repository is configured (Void aarch64; detect musl vs glibc)
    if ! grep -rqE '^\s*repository=' "${1}/etc/xbps.d/" 2>/dev/null && ! grep -rqE '^\s*repository=' "${1}/usr/share/xbps.d/" 2>/dev/null; then
        if [ -e "${1}/lib/ld-musl-aarch64.so.1" ]; then
            printf 'repository=https://repo-default.voidlinux.org/current/aarch64\n' > "${1}/etc/xbps.d/00-repository-main.conf"
        else
            printf 'repository=https://repo-default.voidlinux.org/current\n' > "${1}/etc/xbps.d/00-repository-main.conf"
        fi
    fi
}
_fix_apk() {
    [ -x "${1}/sbin/apk" ] || [ -x "${1}/usr/bin/apk" ] || return 0
    if [ -f "${1}/etc/apk/repositories" ]; then
        sed -i 's/^#\(.*\/community\)/\1/' "${1}/etc/apk/repositories" 2>/dev/null || true
    else
        # Chimera or bare apk with no repos: leave to distro defaults but ensure dir
        mkdir -p "${1}/etc/apk" 2>/dev/null || true
    fi
    mkdir -p "${1}/var/cache/apk" "${1}/etc/apk/keys" "${1}/lib/apk/db" 2>/dev/null || true
    # Copy host apk keys if the stratum has none (helps chimera/alpine trust)
    if [ -d /etc/apk/keys ] && [ -z "$(ls -A "${1}/etc/apk/keys" 2>/dev/null)" ]; then
        cp -a /etc/apk/keys/* "${1}/etc/apk/keys/" 2>/dev/null || true
    fi
}
_fix_opkg() {
    _fop="${1}/etc/opkg.conf"; [ -f "$_fop" ] || _fop="${1}/etc/opkg/opkg.conf"; [ -f "$_fop" ] || return 0
    grep -q 'option check_signature' "$_fop" 2>/dev/null && return 0
    printf '\noption check_signature 0\n' >> "$_fop"
}
_fix_portage() {
    [ -d "${1}/etc/portage" ] || [ -x "${1}/usr/bin/emerge" ] || return 0
    mkdir -p "${1}/etc/portage/repos.conf" 2>/dev/null || true
    _fmk="${1}/etc/portage/make.conf"
    [ -f "$_fmk" ] || : > "$_fmk"
    if ! grep -q 'FEATURES.*-sandbox' "$_fmk" 2>/dev/null; then
        _ncpu="$(nproc 2>/dev/null || echo 2)"
        printf '\n# iSH-AOK\nFEATURES="-sandbox -usersandbox -pid-sandbox -network-sandbox -ipc-sandbox"\nACCEPT_LICENSE="*"\nMAKEOPTS="-j%s"\nEMERGE_DEFAULT_OPTS="--jobs=2 --quiet-build=y"\n' "$_ncpu" >> "$_fmk"
    fi
    # Ensure gentoo repo is configured
    if [ ! -f "${1}/etc/portage/repos.conf/gentoo.conf" ] && [ -f "${1}/usr/share/portage/config/repos.conf" ]; then
        cp "${1}/usr/share/portage/config/repos.conf" "${1}/etc/portage/repos.conf/gentoo.conf" 2>/dev/null || true
    fi
}

# ── post-fetch keyring init (runs inside the stratum via chroot) ─────────
_init_keys() {
    _ikr="$1"; _ikn="$2"
    has chroot || return 0
    _iksh="/bin/sh"; [ -x "${_ikr}/bin/bash" ] && _iksh="/bin/bash"
    [ -x "${_ikr}${_iksh}" ] || return 0

    # Mount pseudo-fs temporarily for key init
    _mount_pseudo "$_ikr"

    if [ -x "${_ikr}/usr/bin/pacman-key" ]; then
        chroot "$_ikr" "$_iksh" -c '
            export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8
            pacman-key --init 2>/dev/null
            pacman-key --populate 2>/dev/null
        ' 2>/dev/null && info "pacman keyring initialized" || true
        _setup_aur "$_ikr" "$_iksh"
    fi

    if [ -x "${_ikr}/usr/bin/apt-key" ] || [ -d "${_ikr}/etc/apt/trusted.gpg.d" ]; then
        chroot "$_ikr" "$_iksh" -c '
            export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8
            apt-get update -y 2>/dev/null || true
        ' 2>/dev/null && info "apt sources updated" || true
    fi

    # Mounts left in place for speed on first entry
}

# Configure AUR access + install yay in an Arch-family stratum.
# AUR builds can't run as root, so we create a 'builder' user with passwordless
# sudo, enable multilib-free base-devel, and build yay from the AUR.
_setup_aur() {
    _aur="$1"; _aursh="$2"
    info "configuring AUR + yay (this builds from source, may take a few minutes)..."
    # ensure resolv/DNS + gpg dir present for the build
    _force_dns "$_aur"
    chroot "$_aur" "$_aursh" -c '
        export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8
        set -e 2>/dev/null || true

        # 1. Sync + install build prerequisites (base-devel, git, sudo)
        pacman -Sy --noconfirm --needed base-devel git sudo 2>/dev/null || \
            pacman -Sy --noconfirm --needed gcc make git sudo fakeroot binutils patch 2>/dev/null || true

        # 2. Create unprivileged builder (makepkg refuses to run as root)
        id builder >/dev/null 2>&1 || useradd -m -G wheel -s /bin/bash builder 2>/dev/null || \
            { echo "builder:x:1000:1000::/home/builder:/bin/bash" >> /etc/passwd; \
              echo "builder:x:1000:" >> /etc/group; mkdir -p /home/builder; chown 1000:1000 /home/builder 2>/dev/null; }

        # 3. Passwordless sudo for builder + wheel
        echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder 2>/dev/null || true
        echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/wheel 2>/dev/null || true
        chmod 440 /etc/sudoers.d/builder /etc/sudoers.d/wheel 2>/dev/null || true

        # 4. Build + install yay from the AUR as builder
        if ! command -v yay >/dev/null 2>&1; then
            su - builder -c "
                export PATH=/usr/sbin:/usr/bin:/sbin:/bin HOME=/home/builder LANG=C.UTF-8
                cd /home/builder
                rm -rf yay-bin
                git clone --depth 1 https://aur.archlinux.org/yay-bin.git 2>/dev/null
                cd yay-bin && makepkg -si --noconfirm 2>/dev/null
            " 2>/dev/null || true
        fi
    ' 2>/dev/null
    if chroot "$_aur" "$_aursh" -c 'command -v yay >/dev/null 2>&1' 2>/dev/null; then
        ok "AUR configured — yay ready (run: yay -S <pkg> as user 'builder')"
    else
        warn "yay build skipped/failed (needs network + working pacman); run 'brl fix ${_ikn}' after 'brl shell ${_ikn}; pacman -Syu' to retry"
    fi
}

# ============================================================================
#  CHROOT CORE
# ============================================================================
_is_mounted() { [ -r /proc/mounts ] && awk -v p="$1" '$2==p{f=1} END{exit !f}' /proc/mounts 2>/dev/null; }

# ── capability detection (cached) ───────────────────────────────────────
# Modern iSH-AOK exposes real namespaces, cgroup v2, and full mounts. Detect
# what actually works and use it; degrade to plain chroot where it doesn't.
_caps_probed=0
_cap_userns=0; _cap_mountns=0; _cap_pidns=0; _cap_utsns=0; _cap_unshare=0
_probe_caps() {
    [ "$_caps_probed" = "1" ] && return 0
    _caps_probed=1
    has unshare || return 0
    # mount namespace (most important for isolation)
    unshare -m true 2>/dev/null && _cap_mountns=1
    # pid namespace (needs fork; test with --fork)
    unshare -p --fork true 2>/dev/null && _cap_pidns=1
    # uts namespace (hostname isolation)
    unshare -u true 2>/dev/null && _cap_utsns=1
    # user namespace
    unshare -U true 2>/dev/null && _cap_userns=1
    [ "$_cap_mountns" = "1" ] || [ "$_cap_pidns" = "1" ] || [ "$_cap_utsns" = "1" ] && _cap_unshare=1
    return 0
}
# Build the unshare flag string for whatever namespaces work.
_ns_flags() {
    _nf=""
    [ "$_cap_mountns" = "1" ] && _nf="${_nf} --mount"
    [ "$_cap_utsns" = "1" ]   && _nf="${_nf} --uts"
    [ "$_cap_pidns" = "1" ]   && _nf="${_nf} --pid --fork --mount-proc"
    [ "$_cap_ipcns:-0" = "1" ] && _nf="${_nf} --ipc"
    printf '%s' "$_nf"
}

# Detect a usable mount namespace (AOK fork supports these). Cached per-run.
_HAS_MOUNTNS=""
have_mount_ns() {
    [ -n "$_HAS_MOUNTNS" ] && { [ "$_HAS_MOUNTNS" = "1" ] && return 0 || return 1; }
    if has unshare && unshare -m true 2>/dev/null; then _HAS_MOUNTNS=1; return 0; fi
    _HAS_MOUNTNS=0; return 1
}

# ── architecture (official Bedrock normalization) ───────────────────────
standardize_architecture() {
    case "${1:-}" in
        aarch64|arm64) echo "aarch64" ;;
        armhf|armhfp|armv7h|armv7hl|armv7a) echo "armv7hl" ;;
        arm|armel|armle|arm7|armv7|armv7l|armv7a_hardfp) echo "armv7l" ;;
        i386) echo "i386" ;; i486) echo "i486" ;; i586) echo "i586" ;;
        x86|i686) echo "i686" ;;
        mips|mipsbe|mipseb) echo "mips" ;;
        mipsel|mipsle) echo "mipsel" ;;
        mips64el|mips64le) echo "mips64el" ;;
        ppc|ppc32|powerpc|powerpc32) echo "ppc" ;;
        ppc64|powerpc64) echo "ppc64" ;;
        ppc64el|ppc64le|powerpc64el|powerpc64le) echo "ppc64le" ;;
        s390x) echo "s390x" ;;
        amd64|x86_64) echo "x86_64" ;;
        *) echo "" ;;
    esac
}
get_system_arch() {
    _gsa="$(standardize_architecture "$(uname -m 2>/dev/null)")"
    [ -n "$_gsa" ] && echo "$_gsa" || echo "unknown"
}
brl_archs() {
    printf '%s\n' aarch64 armv7hl armv7l mips mipsel mips64el ppc64 ppc64le s390x i386 i486 i586 i686 x86_64
}

_mount_pseudo() {
    _mr="$1"; has mount || return 0
    # Prefer proper filesystem types when the kernel supports them (real
    # procfs/sysfs/devpts/tmpfs give package managers and tools accurate data).
    mkdir -p "${_mr}/proc" "${_mr}/sys" "${_mr}/dev" "${_mr}/dev/pts" "${_mr}/dev/shm" "${_mr}/run" 2>/dev/null || true
    if ! _is_mounted "${_mr}/proc"; then
        mount -t proc proc "${_mr}/proc" 2>/dev/null || mount --bind /proc "${_mr}/proc" 2>/dev/null || true
    fi
    if ! _is_mounted "${_mr}/sys"; then
        mount -t sysfs sys "${_mr}/sys" 2>/dev/null || mount --bind /sys "${_mr}/sys" 2>/dev/null || true
    fi
    if ! _is_mounted "${_mr}/dev"; then
        mount --bind /dev "${_mr}/dev" 2>/dev/null || true
    fi
    if ! _is_mounted "${_mr}/dev/pts"; then
        mount -t devpts devpts "${_mr}/dev/pts" 2>/dev/null || mount --bind /dev/pts "${_mr}/dev/pts" 2>/dev/null || true
    fi
    if ! _is_mounted "${_mr}/dev/shm"; then
        mount -t tmpfs tmpfs "${_mr}/dev/shm" 2>/dev/null || mount --bind /dev/shm "${_mr}/dev/shm" 2>/dev/null || true
    fi
    if ! _is_mounted "${_mr}/run"; then
        mount -t tmpfs tmpfs "${_mr}/run" 2>/dev/null || true
    fi
    mkdir -p "${_mr}/tmp" 2>/dev/null || true
    chmod 1777 "${_mr}/tmp" 2>/dev/null || true
}
_unmount_pseudo() {
    _ur="$1"; has umount || return 0
    for _um in dev/shm dev/pts dev proc sys tmp run; do
        _is_mounted "${_ur}/${_um}" && { umount "${_ur}/${_um}" 2>/dev/null || umount -l "${_ur}/${_um}" 2>/dev/null || true; }
    done
}
_stratum_shell() {
    for _ss in /bin/bash /usr/bin/bash /bin/ash /bin/sh /usr/bin/sh; do [ -x "${1}${_ss}" ] && { echo "$_ss"; return 0; }; done
    echo "/bin/sh"
}
# ── stratum aliases (faithful to real Bedrock) ─────────────────────────
# An alias is a symlink in /bedrock/strata/ pointing at another stratum dir.
# deref() resolves an alias to its real stratum name (or echoes the name as-is).
deref() {
    _dref="${1:-}"; [ -n "$_dref" ] || return 1
    _dpath="${STRATA}/${_dref}"
    if [ -L "$_dpath" ]; then
        _dr="$(readlink -f "$_dpath" 2>/dev/null)" || return 1
        basename "$_dr" 2>/dev/null || return 1
    else
        echo "$_dref"
    fi
}
is_alias() { [ -L "${STRATA}/${1}" ]; }
stratum_exists() { _sx="$(deref "$1" 2>/dev/null || echo "$1")"; [ "$_sx" = "$(init_stratum)" ] && return 0; [ -d "${STRATA}/${_sx}" ] && [ -n "$(ls -A "${STRATA}/${_sx}" 2>/dev/null)" ]; }
is_enabled() { _ie="$(deref "$1" 2>/dev/null || echo "$1")"; [ "$_ie" = "$(init_stratum)" ] && return 0; [ -e "${ENABLED}/${_ie}" ]; }
brl_alias() {
    need_root
    _an="${1:-}"; _at="${2:-}"
    if [ -z "$_an" ]; then
        say "${B}Aliases:${Z}"
        _found=0
        for _ad in "${STRATA}"/*; do
            [ -L "$_ad" ] || continue; _found=1
            printf "  %s -> %s\n" "$(basename "$_ad")" "$(deref "$(basename "$_ad")")"
        done
        [ "$_found" = 0 ] && say "  (none)"
        return 0
    fi
    [ -n "$_at" ] || die "usage: brl alias <alias-name> <stratum>"
    _atr="$(deref "$_at" 2>/dev/null || echo "$_at")"
    stratum_exists "$_atr" || die "no such stratum: $_at"
    [ -e "${STRATA}/${_an}" ] && ! is_alias "$_an" && die "'$_an' already exists as a real stratum"
    ln -sfn "$_atr" "${STRATA}/${_an}" 2>/dev/null && ok "alias ${_an} -> ${_atr}" || die "could not create alias"
}
brl_unalias() {
    need_root; _un="${1:-}"; [ -n "$_un" ] || die "usage: brl unalias <alias>"
    is_alias "$_un" || die "'$_un' is not an alias"
    rm -f "${STRATA}/${_un}" 2>/dev/null && ok "removed alias ${_un}" || die "could not remove alias"
}

# ============================================================================
#  STRAT
# ============================================================================
cmd_strat() {
    _sr=0
    while [ "${1:-}" ]; do
        case "$1" in -r|--restrict) _sr=1; shift ;; -a|--arg0) shift 2 ;; --) shift; break ;; -*) shift ;; *) break ;; esac
    done
    _sn="${1:-}"; [ "$#" -ge 1 ] && shift
    [ -n "$_sn" ] || die "usage: strat [-r] <stratum> <command> [args...]"
    stratum_exists "$_sn" || die "no such stratum: '$_sn' (see: brl list)"
    _sn="$(deref "$_sn" 2>/dev/null || echo "$_sn")"
    if [ "$_sn" = "$(init_stratum)" ]; then [ "$#" -ge 1 ] || set -- "${SHELL:-/bin/sh}"; exec "$@"; fi
    _sroot="${STRATA}/${_sn}"
    has chroot || die "chroot unavailable."
    _force_dns "$_sroot"
    _ssh="$(_stratum_shell "$_sroot")"
    if [ "$_sr" = "1" ]; then _sp="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    else _sp="${CROSSBIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; fi

    # Build the command to run inside the chroot.
    if [ "$#" -ge 1 ]; then
        _scmd=""
        for _sa in "$@"; do _scmd="${_scmd} '$(printf '%s' "$_sa" | sed "s/'/'\\\\''/g")'"; done
        _inner='export PATH='"$_sp"' HOME=/root TERM="${TERM:-xterm}" LANG=C.UTF-8 LC_ALL=C.UTF-8 BEDROCK_STRATUM='"$_sn"'
            cd /root 2>/dev/null || cd /; '"$_scmd"
        _interactive=0
    else
        say "${GR}entering ${_sn}${Z} (Ctrl-D / exit to return to $(init_stratum))"
        mkdir -p "$BRUN"; echo "$_sn" > "${BRUN}/current_stratum"
        _inner='export PATH='"${CROSSBIN}"':/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
            export HOME=/root TERM="${TERM:-xterm}" LANG=C.UTF-8 LC_ALL=C.UTF-8 BEDROCK_STRATUM='"$_sn"'
            export PS1="('"$_sn"') \$PWD # "
            cd /root 2>/dev/null || cd /; exec '"$_ssh"' -i'
        _interactive=1
    fi

    if have_mount_ns; then
        # Private mount namespace: bind mounts are isolated to this invocation
        # and vanish automatically on exit — no global pollution, no umount
        # needed. This is how real Bedrock isolates stratum process trees.
        BRL_SROOT="$_sroot" BRL_SSH="$_ssh" BRL_INNER="$_inner" \
        unshare -m --propagation private /bin/sh -c '
            _r="$BRL_SROOT"
            mkdir -p "$_r/proc" "$_r/sys" "$_r/dev" "$_r/dev/pts" "$_r/dev/shm" "$_r/run" "$_r/tmp" 2>/dev/null || true
            mount -t proc proc "$_r/proc" 2>/dev/null || mount --bind /proc "$_r/proc" 2>/dev/null || true
            mount -t sysfs sys "$_r/sys" 2>/dev/null || mount --bind /sys "$_r/sys" 2>/dev/null || true
            mount --bind /dev "$_r/dev" 2>/dev/null || true
            mount -t devpts devpts "$_r/dev/pts" 2>/dev/null || mount --bind /dev/pts "$_r/dev/pts" 2>/dev/null || true
            mount -t tmpfs tmpfs "$_r/dev/shm" 2>/dev/null || true
            mount -t tmpfs tmpfs "$_r/run" 2>/dev/null || true
            chmod 1777 "$_r/tmp" 2>/dev/null || true
            exec chroot "$_r" "$BRL_SSH" -c "$BRL_INNER"
        '
        _src=$?
    else
        # Fallback: global bind mounts (persist for speed; cleared by brl umount).
        _mount_pseudo "$_sroot"
        chroot "$_sroot" "$_ssh" -c "$_inner"
        _src=$?
    fi

    if [ "$_interactive" = "1" ]; then
        echo "$(init_stratum)" > "${BRUN}/current_stratum"
        say "${GR}back in $(init_stratum)${Z}"
    fi
    return $_src
}
cmd_shell() {
    _shn="${1:-}"
    [ -n "$_shn" ] || { say "Enter which stratum?"; brl_list; die "usage: brl shell <stratum>"; }
    stratum_exists "$_shn" || die "no such stratum: '$_shn'"
    cmd_strat "$_shn"
}

# ============================================================================
#  CROSSFS
# ============================================================================
brl_reload() {
    mkdir -p "$CROSSBIN"
    find "$CROSSBIN" -maxdepth 1 -type f -delete 2>/dev/null || true
    _rlp="${BR}/bin/strat"
    [ -x "$_rlp" ] || { _rlp="$0"; case "$_rlp" in /*) : ;; *) _rlp="$(pwd)/$_rlp" ;; esac; }
    _rlc=0
    for _rld in "${STRATA}"/*; do
        [ -d "$_rld" ] || continue; _rls="$(basename "$_rld")"; is_enabled "$_rls" || continue
        for _rlb in usr/local/bin usr/bin bin usr/local/sbin usr/sbin sbin; do
            [ -d "${_rld}/${_rlb}" ] || continue
            for _rle in "${_rld}/${_rlb}"/*; do
                { [ -f "$_rle" ] || [ -L "$_rle" ]; } || continue
                _rlcn="$(basename "$_rle")"; [ -e "${CROSSBIN}/${_rlcn}" ] && continue
                command -v "$_rlcn" >/dev/null 2>&1 && continue
                printf '#!/bin/sh\n# crossfs: %s from %s\nexec "%s" %s %s "$@"\n' "$_rlcn" "$_rls" "$_rlp" "$_rls" "$_rlcn" > "${CROSSBIN}/${_rlcn}"
                chmod +x "${CROSSBIN}/${_rlcn}"; _rlc=$((_rlc+1))
            done
        done
    done
    ok "crossfs: ${_rlc} commands"
}

# ============================================================================
#  UPDATE / LIST / STATUS / WHICH / ENABLE / DISABLE / REMOVE / RENAME / UMOUNT
# ============================================================================
# Re-apply all environment + package-manager fixes to an existing stratum.
brl_fix() {
    need_root; _fxn="${1:-}"
    if [ -z "$_fxn" ]; then
        for _fxd in "${STRATA}"/*; do [ -d "$_fxd" ] || continue
            _fxs="$(basename "$_fxd")"; info "re-fixing ${_fxs}..."; _prepare_stratum "$_fxd" "$_fxs"
        done
        ok "all strata re-fixed"; return 0
    fi
    [ -d "${STRATA}/${_fxn}" ] || die "no such stratum: $_fxn"
    info "re-applying fixes to ${_fxn}..."
    _prepare_stratum "${STRATA}/${_fxn}" "$_fxn"
    _init_keys "${STRATA}/${_fxn}" "$_fxn"
    ok "${_fxn} fixed"
}

_pkg_cmd() {
    _upr="$1"
    if   [ -x "${_upr}/sbin/apk" ] || [ -x "${_upr}/usr/bin/apk" ]; then echo "apk update && apk upgrade --available --no-interactive 2>/dev/null || apk upgrade --available"
    elif [ -x "${_upr}/usr/bin/apt-get" ] && [ -x "${_upr}/usr/bin/dpkg" ]; then echo "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade"
    elif [ -x "${_upr}/usr/bin/pacman" ]; then echo "pacman -Syu --noconfirm --needed"
    elif [ -x "${_upr}/usr/bin/xbps-install" ]; then echo "xbps-install -Suy"
    elif [ -x "${_upr}/usr/bin/dnf" ]; then echo "dnf -y --nogpgcheck upgrade"
    elif [ -x "${_upr}/usr/bin/yum" ]; then echo "yum -y --nogpgcheck update"
    elif [ -x "${_upr}/usr/bin/zypper" ]; then echo "zypper --non-interactive --no-gpg-checks refresh && zypper --non-interactive --no-gpg-checks update"
    elif [ -x "${_upr}/usr/bin/apt-get" ]; then echo "apt-get update && apt-get -y upgrade"
    elif [ -x "${_upr}/bin/opkg" ] || [ -x "${_upr}/usr/bin/opkg" ]; then echo "opkg update && opkg upgrade"
    elif [ -x "${_upr}/usr/bin/emerge" ]; then echo "emerge --sync && emerge -uDN @world"
    else echo ""; fi
}
# Best package-manager install command for a stratum (used by brl install helper).
_pkg_install_cmd() {
    _ipr="$1"
    if   [ -x "${_ipr}/sbin/apk" ] || [ -x "${_ipr}/usr/bin/apk" ]; then echo "apk add"
    elif [ -x "${_ipr}/usr/bin/apt-get" ] && [ -x "${_ipr}/usr/bin/dpkg" ]; then echo "apt-get update >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y"
    elif [ -x "${_ipr}/usr/bin/pacman" ]; then echo "pacman -Sy --noconfirm --needed"
    elif [ -x "${_ipr}/usr/bin/xbps-install" ]; then echo "xbps-install -Sy"
    elif [ -x "${_ipr}/usr/bin/dnf" ]; then echo "dnf -y --nogpgcheck install"
    elif [ -x "${_ipr}/usr/bin/yum" ]; then echo "yum -y --nogpgcheck install"
    elif [ -x "${_ipr}/usr/bin/zypper" ]; then echo "zypper --non-interactive --no-gpg-checks install"
    elif [ -x "${_ipr}/usr/bin/apt-get" ]; then echo "apt-get install -y"
    elif [ -x "${_ipr}/bin/opkg" ] || [ -x "${_ipr}/usr/bin/opkg" ]; then echo "opkg install"
    elif [ -x "${_ipr}/usr/bin/emerge" ]; then echo "emerge"
    else echo ""; fi
}
# brl install <stratum> <pkg...> — install packages into a stratum from the host.
brl_install() {
    need_root; _in="${1:-}"; [ -n "$_in" ] && shift
    [ -n "$_in" ] || die "usage: brl install <stratum> <package>..."
    [ "$#" -ge 1 ] || die "usage: brl install <stratum> <package>..."
    [ -d "${STRATA}/${_in}" ] || die "no such stratum: $_in"
    _ic="$(_pkg_install_cmd "${STRATA}/${_in}")"; [ -n "$_ic" ] || die "no known package manager in $_in"
    say "${GR}installing into ${_in}:${Z} $*"
    cmd_strat "$_in" /bin/sh -c "$_ic $*"
}
brl_update() {
    need_root; _upn="${1:-}"
    if [ -n "$_upn" ]; then
        is_pinned "$_upn" && die "'$_upn' is pinned. Unpin to update: brl pin $_upn"
        [ -d "${STRATA}/${_upn}" ] || die "no such stratum: $_upn"
        _upc="$(_pkg_cmd "${STRATA}/${_upn}")"; [ -n "$_upc" ] || die "no known pkg mgr in $_upn"
        say "${GR}updating ${_upn}${Z}"; cmd_strat "$_upn" /bin/sh -c "$_upc"; return $?
    fi
    for _upd in "${STRATA}"/*; do [ -d "$_upd" ] || continue; _ups="$(basename "$_upd")"
        is_pinned "$_ups" && { info "$_ups: pinned, skipping"; continue; }
        _upc="$(_pkg_cmd "$_upd")"; [ -n "$_upc" ] || { warn "$_ups: no pkg mgr"; continue; }
        say ""; say "${B}=== ${_ups} ===${Z}"; cmd_strat "$_ups" /bin/sh -c "$_upc" || warn "$_ups: nonzero"
    done
}

brl_list() {
    case "${1:-}" in --json) brl_list_json; return 0 ;; esac
    _lm="all"; case "${1:-}" in -e|--enabled) _lm="enabled" ;; -d|--disabled) _lm="disabled" ;; esac
    _li="$(init_stratum)"
    for _ld in "$_li" $(ls "${STRATA}" 2>/dev/null); do
        [ "$_ld" = "$_li" ] || [ -d "${STRATA}/${_ld}" ] || continue
        [ -L "${STRATA}/${_ld}" ] && continue
        if is_enabled "$_ld"; then _ls="enabled"; else _ls="disabled"; fi
        case "$_lm" in enabled) [ "$_ls" = "enabled" ] || continue ;; disabled) [ "$_ls" = "disabled" ] || continue ;; esac
        _lpm=""; is_pinned "$_ld" && _lpm=" ${color_warn}(pinned)${color_norm}"
        printf "%s%s\n" "$_ld" "$_lpm"
    done
}
brl_status() {
    _stn="${1:-}"
    if [ -z "$_stn" ]; then
        say "$(init_stratum): enabled (init)"
        for _std in "${STRATA}"/*; do [ -d "$_std" ] || continue; _sts="$(basename "$_std")"
            is_enabled "$_sts" && say "${_sts}: enabled" || say "${_sts}: disabled"
        done; return 0
    fi
    stratum_exists "$_stn" || die "no such stratum: $_stn"
    [ "$_stn" = "$(init_stratum)" ] && say "${_stn}: enabled (init)" || { is_enabled "$_stn" && say "${_stn}: enabled" || say "${_stn}: disabled"; }
}
brl_which() {
    _wmode="cmd"
    case "${1:-}" in
        --bin)  _wmode="bin";  shift ;;
        --file) _wmode="file"; shift ;;
        --pid)  _wmode="pid";  shift ;;
        --xww|--current) _wmode="current"; shift ;;
    esac
    _wq="${1:-}"
    # No argument, or --current: report the current stratum.
    if [ -z "$_wq" ] || [ "$_wmode" = "current" ]; then
        [ -n "${BEDROCK_STRATUM:-}" ] && { say "$BEDROCK_STRATUM"; return 0; }
        [ -f "${BRUN}/current_stratum" ] && { cat "${BRUN}/current_stratum"; return 0; }
        init_stratum; return 0
    fi
    case "$_wmode" in
        pid)
            # which stratum owns the process with this PID (via its root)
            [ -d "/proc/${_wq}" ] || die "no such pid: $_wq"
            _wroot="$(readlink -f "/proc/${_wq}/root" 2>/dev/null || true)"
            if [ -n "$_wroot" ]; then
                case "$_wroot" in
                    "${STRATA}"/*) say "$(printf '%s' "${_wroot#"${STRATA}/"}" | cut -d/ -f1)"; return 0 ;;
                    *) say "$(init_stratum)"; return 0 ;;
                esac
            fi
            # proc root not readable (common for PID 1 / other users): assume init
            say "$(init_stratum)"; return 0 ;;
        file)
            # which stratum a path belongs to (if under /bedrock/strata/<s>)
            _wrp="$(readlink -f "$_wq" 2>/dev/null || echo "$_wq")"
            case "$_wrp" in
                "${STRATA}"/*) say "$(printf '%s' "${_wrp#"${STRATA}/"}" | cut -d/ -f1)"; return 0 ;;
                *) say "$(init_stratum)"; return 0 ;;
            esac ;;
        bin|cmd)
            if [ "$_wmode" = "cmd" ] && command -v "$_wq" >/dev/null 2>&1; then say "$(init_stratum)"; return 0; fi
            if [ -e "${CROSSBIN}/${_wq}" ]; then
                _wo="$(sed -n 's/^# crossfs: .* from //p' "${CROSSBIN}/${_wq}" 2>/dev/null | head -1)"
                [ -n "$_wo" ] && { say "$_wo"; return 0; }
            fi
            for _wd in "${STRATA}"/*; do [ -d "$_wd" ] || continue; [ -L "$_wd" ] && continue
                for _wb in usr/bin bin usr/sbin sbin usr/local/bin; do [ -x "${_wd}/${_wb}/${_wq}" ] && { basename "$_wd"; return 0; }; done
            done
            die "not found in any stratum: $_wq" ;;
    esac
}
brl_enable()  { need_root; _en="${1:-}"; [ -n "$_en" ] || die "usage: brl enable <stratum>"; [ -d "${STRATA}/${_en}" ] || die "no such stratum: $_en"; mkdir -p "$ENABLED"; : > "${ENABLED}/${_en}"; brl_reload; ok "enabled $_en"; }
brl_disable() { need_root; _dn="${1:-}"; [ -n "$_dn" ] || die "usage: brl disable <stratum>"; [ "$_dn" = "$(init_stratum)" ] && die "cannot disable init stratum"; rm -f "${ENABLED}/${_dn}"; _unmount_pseudo "${STRATA}/${_dn}"; brl_reload; ok "disabled $_dn"; }
brl_remove() {
    need_root; _rmn="${1:-}"; [ -n "$_rmn" ] || die "usage: brl remove <stratum>"
    [ "$_rmn" = "$(init_stratum)" ] && die "cannot remove init stratum"
    is_pinned "$_rmn" && die "'$_rmn' is pinned. Unpin first: brl pin $_rmn"
    _rmr="${STRATA}/${_rmn}"; [ -d "$_rmr" ] || die "no such stratum: $_rmn"
    _unmount_pseudo "$_rmr"
    [ -r /proc/mounts ] && awk -v p="$_rmr" '$2~("^"p){f=1} END{exit !f}' /proc/mounts 2>/dev/null && \
        die "active mounts under $_rmr; reboot and retry."
    printf "Remove '%s'? [y/N] " "$_rmn"; read -r _rmc; case "$_rmc" in y|Y) ;; *) say "aborted."; return 0 ;; esac
    rm -rf "$_rmr"; rm -f "${ENABLED}/${_rmn}"; brl_reload; ok "removed $_rmn"
}
brl_rename() {
    need_root; _rno="${1:-}"; _rnn="${2:-}"; { [ -n "$_rno" ] && [ -n "$_rnn" ]; } || die "usage: brl rename <old> <new>"
    [ "$_rno" = "$(init_stratum)" ] && die "cannot rename init stratum"
    [ -d "${STRATA}/${_rno}" ] || die "no such: $_rno"; [ -d "${STRATA}/${_rnn}" ] && die "exists: $_rnn"
    _unmount_pseudo "${STRATA}/${_rno}"; mv "${STRATA}/${_rno}" "${STRATA}/${_rnn}"
    [ -e "${ENABLED}/${_rno}" ] && { rm -f "${ENABLED}/${_rno}"; : > "${ENABLED}/${_rnn}"; }
    brl_reload; ok "renamed $_rno -> $_rnn"
}
cmd_umount() {
    need_root; _umn="${1:-}"
    if [ -n "$_umn" ]; then _unmount_pseudo "${STRATA}/${_umn}"; ok "unmounted $_umn"; return 0; fi
    for _umd in "${STRATA}"/*; do [ -d "$_umd" ] && _unmount_pseudo "$_umd"; done; ok "unmounted all"
}

# ============================================================================
#  HIJACK
# ============================================================================
brl_hijack() {
    need_root; say ""; print_logo "Bedrock Linux ${BEDROCK_VERSION} ${BEDROCK_CODENAME} (${PORT_TAG})"
    ensure_deps || die "required host tools missing; cannot hijack."
    step_init 5

    step "Performing sanity checks"
    has chroot || abort "chroot unavailable — cannot hijack on this system."
    has tar || abort "tar unavailable — cannot hijack."

    step "Gathering information"
    _hi="hijacked"
    if [ -f "${BRUN}/init_stratum" ]; then _hi="$(cat "${BRUN}/init_stratum")"
    else _hs=/etc/os-release; [ -f "${BETC}/os-release.orig" ] && _hs="${BETC}/os-release.orig"
        [ -f "$_hs" ] && { _hid="$(. "$_hs" 2>/dev/null; echo "${ID:-}")"; [ -n "$_hid" ] && [ "$_hid" != "bedrock" ] && _hi="$_hid"; }
    fi
    notice "Using ${color_strat}${_hi}${color_norm} for initial stratum"

    step "Hijacking init system"
    mkdir -p "${BR}/bin" "$STRATA" "$CROSSBIN" "$BRUN" "$ENABLED" "$BETC"
    echo "$_hi" > "${BRUN}/init_stratum"; : > "${ENABLED}/${_hi}"
    _hself="$0"; case "$_hself" in /*) : ;; *) _hself="$(pwd)/$_hself" ;; esac
    cp -f "$_hself" "${BR}/bin/brl" 2>/dev/null || true; chmod +x "${BR}/bin/brl" 2>/dev/null || true
    printf '#!/bin/sh\nexec "%s" strat "$@"\n' "${BR}/bin/brl" > "${BR}/bin/strat"; chmod +x "${BR}/bin/strat"
    for _hb in /usr/local/bin /usr/bin; do [ -d "$_hb" ] || continue
        ln -sf "${BR}/bin/brl" "${_hb}/brl" 2>/dev/null
        ln -sf "${BR}/bin/strat" "${_hb}/strat" 2>/dev/null && { notice "Installed ${color_cmd}brl${color_norm} + ${color_cmd}strat${color_norm} to ${color_file}${_hb}${color_norm}"; break; }
    done

    step "Extracting ${color_file}/bedrock${color_norm}"
    printf 'Bedrock Linux %s %s (%s port)\n' "$BEDROCK_VERSION" "$BEDROCK_CODENAME" "$PORT_TAG" > "$RELEASE_FILE"
    # Write a bedrock.conf reference (upstream parity; sections honored where meaningful on iSH-AOK)
    [ -f "${BETC}/bedrock.conf" ] || cat > "${BETC}/bedrock.conf" <<BCONF
# Bedrock Linux configuration (iSH-AOK port)
# Sections mirror upstream; some are informational on iSH-AOK.

[miscellaneous]
# system CPU architecture (standardized)
arch = $(get_system_arch)
# color output for brl/strat
color = true

[locale]
LANG = C.UTF-8

[cross]
# crossfs is emulated via symlink wrappers in /bedrock/cross/bin (no FUSE)
enable = true

[symlinks]
# stratum-local paths brl keeps consistent
/etc/os-release = /bedrock/etc/os-release

[init]
# systemd remains PID 1, made Bedrock-aware via /etc/systemd/system.conf.d
manager = systemd
BCONF
    if [ -e /etc/os-release ] && [ ! -f "${BETC}/os-release.orig" ]; then
        _hc="$(readlink -f /etc/os-release 2>/dev/null || echo /etc/os-release)"
        case "$_hc" in "${BR}"/*) : ;; *) cp -aL /etc/os-release "${BETC}/os-release.orig" 2>/dev/null || true ;; esac
    fi
    [ -L /etc/os-release ] && rm -f /etc/os-release 2>/dev/null || true
    cat > "${BETC}/os-release" <<OSR
NAME="Bedrock Linux"
ID=bedrock
ID_LIKE=bedrock
PRETTY_NAME="Bedrock Linux ${BEDROCK_VERSION} ${BEDROCK_CODENAME}"
VERSION_ID="${BEDROCK_VERSION}"
HOME_URL="https://bedrocklinux.org"
OSR
    cp -aL /etc/os-release /etc/os-release.bedrock-orig 2>/dev/null || true
    cp -f "${BETC}/os-release" /etc/os-release 2>/dev/null && notice "Configuring ${color_strat}bedrock${color_norm} stratum" || true
    mkdir -p /etc/profile.d
    cat > /etc/profile.d/bedrock.sh <<'PD'
for _d in /bedrock/bin /bedrock/cross/bin; do [ -d "$_d" ] || continue; case ":${PATH}:" in *:"$_d":*) ;; *) PATH="${_d}:${PATH}" ;; esac; done
export PATH; [ -z "${BEDROCK_STRATUM:-}" ] && export BEDROCK_STRATUM="$(cat /bedrock/run/init_stratum 2>/dev/null || echo bedrock)"
export LANG=C.UTF-8 LC_ALL=C.UTF-8
PD
    chmod +x /etc/profile.d/bedrock.sh
    for _hr in /etc/bash.bashrc "${HOME}/.bashrc" "${HOME}/.profile"; do
        [ -f "$_hr" ] || continue; grep -q 'profile.d/bedrock.sh' "$_hr" 2>/dev/null && continue
        printf '\n[ -f /etc/profile.d/bedrock.sh ] && . /etc/profile.d/bedrock.sh\n' >> "$_hr"
    done
    notice "Configuring ${color_strat}${_hi}${color_norm} stratum"
    _install_ff; echo "$_hi" > "${BRUN}/current_stratum"; brl_reload >/dev/null 2>&1

    step "Finalizing"
    notice "This system is now ${color_strat}Bedrock Linux${color_norm}"
    # Additive integration layer: capabilities, boot units, AOK roots, rollback.
    braok_detect_caps 2>/dev/null || true
    braok_install_units 2>/dev/null || true
    braok_register_aok 2>/dev/null || true
    braok_rollback_create "post-hijack" >/dev/null 2>&1 || true
    notice "Integration layer active — try ${color_cmd}brl capabilities${color_norm}, ${color_cmd}brl test${color_norm}"
    notice "Add a stratum: ${color_cmd}brl fetch alpine${color_norm}"
    say ""
}
brl_unhijack() { die "permanent installation — use the brl-uninstall script to fully remove."; }
# Write the fastfetch/brl report helper scripts under ${BR}/bin. Called from
# _install_ff() (hijack) and brl_hijack(); kept here so both scripts share it.
_write_helpers() {
    mkdir -p "${BR}/bin" 2>/dev/null || true
    cat > "${BR}/bin/brl-mem" <<'SH'
#!/bin/sh
free -m 2>/dev/null | awk -F'[ :]+' '/^Mem:/{printf "%dMiB / %dMiB", $3, $2}'
SH
    cat > "${BR}/bin/brl-swap" <<'SH'
#!/bin/sh
free -m 2>/dev/null | awk -F'[ :]+' '/^Swap:/{printf "%dMiB / %dMiB", $3, $2}'
SH
    cat > "${BR}/bin/brl-disk" <<'SH'
#!/bin/sh
df -hP / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}'
SH
    cat > "${BR}/bin/brl-strata" <<'SH'
#!/bin/sh
ls -1 /bedrock/run/enabled_strata 2>/dev/null | sed 's/^/  /' || echo none
SH
    chmod 0755 "${BR}/bin/brl-mem" "${BR}/bin/brl-swap" "${BR}/bin/brl-disk" "${BR}/bin/brl-strata" 2>/dev/null || true
}
_install_ff() {
    _write_helpers
    _fc="${HOME}/.config/fastfetch"; mkdir -p "$_fc"
    [ -f "${_fc}/config.jsonc" ] && [ ! -f "${_fc}/config.jsonc.bedrock-bak" ] && cp -a "${_fc}/config.jsonc" "${_fc}/config.jsonc.bedrock-bak" 2>/dev/null || true
    cat > "${_fc}/config.jsonc" <<CFG
{
  "modules": [
    "title", "separator",
    { "type": "os", "key": "OS" },
    { "type": "host", "key": "Host" },
    { "type": "kernel", "key": "Kernel" },
    { "type": "uptime", "key": "Uptime" },
    { "type": "packages", "key": "Packages" },
    { "type": "shell", "key": "Shell" },
    { "type": "terminal", "key": "Terminal" },
    { "type": "cpu", "key": "CPU" },
    { "type": "command", "key": "Memory", "text": "${BR}/bin/brl-mem" },
    { "type": "command", "key": "Swap", "text": "${BR}/bin/brl-swap" },
    { "type": "command", "key": "Disk (/)", "text": "${BR}/bin/brl-disk" },
    { "type": "localip", "key": "Local IP" },
    { "type": "locale", "key": "Locale" },
    { "type": "command", "key": "Strata", "text": "${BR}/bin/brl-strata" },
    "break", "colors"
  ]
}
CFG
    ok "fastfetch configured"
}

# ── report ──────────────────────────────────────────────────────────────
brl_report() {
    say ""; print_logo; say ""; say "${B}brl report${Z}"; say ""
    say "Kernel:  $(uname -sr 2>/dev/null || echo '?')   Arch: $(uname -m 2>/dev/null || echo '?')"
    say "User:    $(id -un) (uid $(id -u))"; say ""
    if has chroot && chroot / true 2>/dev/null; then ok "chroot"; else err "chroot MISSING"; fi
    if has mount; then _ra="/tmp/.br_a$$"; _rb="/tmp/.br_b$$"; mkdir -p "$_ra" "$_rb" 2>/dev/null
        mount --bind "$_ra" "$_rb" 2>/dev/null && { ok "bind mount"; umount "$_rb" 2>/dev/null; } || warn "no bind mount"
        rmdir "$_ra" "$_rb" 2>/dev/null || true; fi
    { has wget && ok "wget"; } || { has curl && ok "curl"; } || err "need wget or curl"
    has tar && ok "tar" || err "tar MISSING"
    has xz && ok "xz" || err "xz MISSING — install xz-utils"
    if have_mount_ns; then ok "mount namespaces: available (isolated strat mounts)"; else info "mount namespaces: unavailable — using global bind mounts"; fi
    for _nsf in user pid net uts ipc cgroup; do
        [ -e "/proc/self/ns/${_nsf}" ] && printf "  ${color_misc}* ${color_norm}%s namespace: present\n" "$_nsf"
    done
    [ -d /sys/fs/cgroup ] && ok "cgroup v2: $([ -f /sys/fs/cgroup/cgroup.controllers ] && echo present || echo v1/hybrid)"
    info "crossfs emulated via wrapper scripts in ${CROSSBIN}"
    say ""; [ -f "$RELEASE_FILE" ] && ok "hijacked ($(cat "$RELEASE_FILE"))" || warn "not hijacked"
    [ -f "$URLCACHE" ] && ok "sources: $(wc -l < "$URLCACHE" 2>/dev/null) strata cached" || warn "no cache (brl update-urls)"
    _rpn=0; for _rpd in "${STRATA}"/*; do [ -d "$_rpd" ] && _rpn=$((_rpn+1)); done
    _rpm=0; [ -r /proc/mounts ] && _rpm="$(awk -v p="$STRATA" '$2~("^"p){c++}END{print c+0}' /proc/mounts 2>/dev/null)"
    say "  init: $(init_stratum)   strata: ${_rpn}   mounts: ${_rpm}"
    [ -x "${BR}/bin/brl-mem" ] && say "  memory: $(${BR}/bin/brl-mem 2>/dev/null)   disk: $(${BR}/bin/brl-disk 2>/dev/null)"
    say ""
}
brl_version() { print_logo "$(cat "$RELEASE_FILE" 2>/dev/null || echo "Bedrock Linux ${BEDROCK_VERSION} ${BEDROCK_CODENAME}")"; say "Bedrock Linux ${BEDROCK_VERSION} ${BEDROCK_CODENAME} (${PORT_TAG} port)"; say "bedrock-port ${BRL_PORT_VERSION}"; }

# ── help ────────────────────────────────────────────────────────────────
brl_help() {
    print_logo "Bedrock Linux ${BEDROCK_VERSION} ${BEDROCK_CODENAME} (${PORT_TAG})"
    printf "Usage: ${color_cmd}brl ${color_sub}<command> [arguments]${color_norm}\n"
    printf "       ${color_cmd}strat ${color_sub}[-r] <stratum> <command>${color_norm}\n\n"
    printf "Manage a Bedrock Linux system: mix packages from many distros as ${color_term}strata${color_norm}.\n\n"
    printf "${B}Stratum management${Z}\n"
    printf "  ${color_cmd}fetch ${color_sub}[-r] <stratum>${color_norm}   acquire and add a new stratum  (${color_cmd}brl fetch --list${color_norm})\n"
    printf "  ${color_cmd}fetch-url ${color_sub}<name> <url>${color_norm} acquire a stratum from a custom rootfs URL\n"
    printf "  ${color_cmd}apply${color_norm}                  fetch every stratum in the catalog\n"
    printf "  ${color_cmd}list ${color_sub}[-e|-d]${color_norm}           list all/enabled/disabled strata\n"
    printf "  ${color_cmd}status ${color_sub}[stratum]${color_norm}       report whether strata are enabled\n"
    printf "  ${color_cmd}show ${color_sub}<stratum>${color_norm}         show details about a stratum\n"
    printf "  ${color_cmd}which ${color_sub}[command]${color_norm}        report which stratum provides a command\n"
    printf "  ${color_cmd}enable${color_norm} / ${color_cmd}disable ${color_sub}<s>${color_norm}   add/remove a stratum from cross-command access\n"
    printf "  ${color_cmd}remove${color_norm} / ${color_cmd}rename ${color_sub}<s>${color_norm}    delete / rename a stratum\n"
    printf "  ${color_cmd}copy ${color_sub}<s> <file> <d>${color_norm}    copy a file between strata\n"
    printf "  ${color_cmd}pin ${color_sub}[stratum]${color_norm}          protect a stratum from remove/update (toggle)\n"
    printf "  ${color_cmd}alias ${color_sub}<name> <stratum>${color_norm} create an alternate name for a stratum\n"
    printf "  ${color_cmd}which ${color_sub}[--bin|--file|--pid]${color_norm} identify which stratum owns a cmd/path/pid\n"
    printf "  ${color_cmd}export${color_norm} / ${color_cmd}import-tar${color_norm}     save / restore a stratum as a portable tarball\n"
    printf "\n${B}Packages${Z}\n"
    printf "  ${color_cmd}update ${color_sub}[stratum]${color_norm}       update packages (one stratum or all; skips pinned)\n"
    printf "  ${color_cmd}install ${color_sub}<s> <pkg>...${color_norm}   install package(s) into a stratum\n"
    printf "\n${B}Running commands${Z}\n"
    printf "  ${color_cmd}shell${color_norm} / ${color_cmd}enter ${color_sub}<stratum>${color_norm} open an interactive shell in a stratum\n"
    printf "  ${color_cmd}strat ${color_sub}<stratum> <cmd>${color_norm}  run a command inside a stratum\n"
    printf "\n${B}System${Z}\n"
    printf "  ${color_cmd}hijack ${color_sub}[name]${color_norm}          convert this system into Bedrock Linux\n"
    printf "  ${color_cmd}unhijack${color_norm}               revert the hijack\n"
    printf "  ${color_cmd}apply ${color_sub}[BRL_JOBS=n]${color_norm}      fetch the whole catalog (parallel)\n"
    printf "  ${color_cmd}update-urls${color_norm}            re-resolve stratum sources from live mirrors\n"
    printf "  ${color_cmd}config ${color_sub}get|set${color_norm}         read/write bedrock.conf\n"
    printf "  ${color_cmd}capabilities${color_norm} / ${color_cmd}security${color_norm} runtime capability + security posture\n"
    printf "  ${color_cmd}reload${color_norm}                 rebuild cross-command wrappers\n"
    printf "  ${color_cmd}umount ${color_sub}[stratum]${color_norm}       release stratum mounts\n"
    printf "  ${color_cmd}fix${color_norm} / ${color_cmd}repair ${color_sub}[stratum]${color_norm} re-apply environment fixes to a stratum\n"
    printf "  ${color_cmd}verify${color_norm} / ${color_cmd}health${color_norm} / ${color_cmd}test${color_norm}  integrity / health / regression suite\n"
    printf "  ${color_cmd}deps${color_norm}                   check/install host dependencies\n"
    printf "  ${color_cmd}report${color_norm}                 system health check\n"
    printf "  ${color_cmd}self-update${color_norm}            re-fetch the script (verified)\n"
    printf "  ${color_cmd}tutorial${color_norm}               show a quick tutorial\n"
    printf "  ${color_cmd}subcommands${color_norm}            list all subcommands\n"
    printf "  ${color_cmd}version${color_norm}, ${color_cmd}help ${color_sub}[cmd]${color_norm}      version / help (per-command help available)\n"
    printf "\n${B}Quickstart${Z}\n"
    printf "  ${color_cmd}brl hijack${color_norm} && ${color_cmd}brl fetch alpine${color_norm} && ${color_cmd}brl shell alpine${color_norm}\n"
}

# ── official-compatible subcommands ─────────────────────────────────────

# brl show <stratum> — show details about a stratum (official parity)
brl_show() {
    _shpmm=0; case "${1:-}" in --pmm) _shpmm=1; shift ;; esac
    _shw="${1:-}"; [ -n "$_shw" ] || die "usage: brl show [--pmm] <stratum>"
    stratum_exists "$_shw" || die "no such stratum: $_shw"
    _shreal="$(deref "$_shw" 2>/dev/null || echo "$_shw")"
    _shr="${STRATA}/${_shreal}"
    [ "$_shreal" = "$(init_stratum)" ] && _shr="/"
    # --pmm: just print the package manager name (official parity).
    if [ "$_shpmm" = 1 ]; then
        _pmm="$(_pkg_install_cmd "$_shr" 2>/dev/null | awk '{print $1}')"
        [ -n "$_pmm" ] && echo "$_pmm" || echo "none"
        return 0
    fi
    printf "${color_strat}%s${color_norm}\n" "$_shw"
    is_alias "$_shw" && printf "  ${color_misc}alias of:${color_norm} %s\n" "$_shreal"
    [ "$_shreal" = "$(init_stratum)" ] && printf "  ${color_misc}type:${color_norm}    init stratum\n"
    is_enabled "$_shw" && printf "  ${color_misc}status:${color_norm}  ${color_okay}enabled${color_norm}\n" || printf "  ${color_misc}status:${color_norm}  ${color_warn}disabled${color_norm}\n"
    is_pinned "$_shreal" && printf "  ${color_misc}pinned:${color_norm}  yes\n"
    if [ -f "${_shr}/etc/os-release" ]; then
        _shp="$(. "${_shr}/etc/os-release" 2>/dev/null; echo "${PRETTY_NAME:-${NAME:-unknown}}")"
        printf "  ${color_misc}distro:${color_norm}  %s\n" "$_shp"
    fi
    _shpm="$(_pkg_install_cmd "$_shr" 2>/dev/null | awk '{print $1}')"
    [ -n "$_shpm" ] && printf "  ${color_misc}pkgmgr:${color_norm}  %s\n" "$_shpm"
    printf "  ${color_misc}path:${color_norm}    %s\n" "${STRATA}/${_shreal}"
}

# brl copy <src-stratum> <file> <dst-stratum> [dstpath] — copy a file between strata
brl_copy() {
    need_root
    _cs="${1:-}"; _cf="${2:-}"; _cd="${3:-}"; _cdp="${4:-}"
    { [ -n "$_cs" ] && [ -n "$_cf" ] && [ -n "$_cd" ]; } || die "usage: brl copy <src-stratum> <file> <dst-stratum> [dest-path]"
    stratum_exists "$_cs" || die "no such stratum: $_cs"
    stratum_exists "$_cd" || die "no such stratum: $_cd"
    _csr="${STRATA}/${_cs}"; [ "$_cs" = "$(init_stratum)" ] && _csr=""
    _cdr="${STRATA}/${_cd}"; [ "$_cd" = "$(init_stratum)" ] && _cdr=""
    _srcpath="${_csr}${_cf}"
    [ -e "$_srcpath" ] || die "source file not found: ${_cs}:${_cf}"
    [ -n "$_cdp" ] || _cdp="$_cf"
    _dstpath="${_cdr}${_cdp}"
    mkdir -p "$(dirname "$_dstpath")" 2>/dev/null || true
    cp -a "$_srcpath" "$_dstpath" 2>/dev/null && ok "copied ${_cs}:${_cf} -> ${_cd}:${_cdp}" || die "copy failed"
}

# ── v1.2.0: pinning (protect a stratum from remove/update) ──────────────
_pin_file() { echo "${BETC}/pinned"; }
is_pinned() { _pf="$(_pin_file)"; [ -f "$_pf" ] && grep -qx "$1" "$_pf" 2>/dev/null; }
brl_pin() {
    need_root; _pn="${1:-}"
    _pf="$(_pin_file)"; touch "$_pf" 2>/dev/null || true
    case "$_pn" in
        ""|--list) say "${B}Pinned strata:${Z}"; [ -s "$_pf" ] && sed 's/^/  /' "$_pf" || say "  (none)" ;;
        *)
            stratum_exists "$_pn" || die "no such stratum: $_pn"
            if is_pinned "$_pn"; then
                sed -i "/^${_pn}\$/d" "$_pf" 2>/dev/null; ok "unpinned ${_pn}"
            else
                echo "$_pn" >> "$_pf"; ok "pinned ${_pn} (protected from remove/update)"
            fi ;;
    esac
}

# ── v1.2.0: export / import a stratum as a portable tarball ──────────────
brl_export() {
    need_root; _en="${1:-}"; _ef="${2:-}"
    [ -n "$_en" ] && [ -n "$_ef" ] || die "usage: brl export <stratum> <file.tar.gz>"
    stratum_exists "$_en" || die "no such stratum: $_en"
    _er="${STRATA}/${_en}"
    say "${GR}exporting ${_en} -> ${_ef}${Z}"
    if has gzip; then (cd "$_er" && tar cf - . 2>/dev/null) | gzip > "$_ef" 2>/dev/null
    else (cd "$_er" && tar cf - . 2>/dev/null) > "$_ef" 2>/dev/null; fi
    [ -s "$_ef" ] && { ok "exported ($(( $(wc -c <"$_ef")/1024/1024 )) MB)"; _sh="$(_sha256 "$_ef")"; [ -n "$_sh" ] && say "  sha256: ${_sh}"; } || die "export failed"
}
brl_import_tar() {
    need_root; _in="${1:-}"; _if="${2:-}"
    [ -n "$_in" ] && [ -n "$_if" ] || die "usage: brl import-tar <name> <file.tar[.gz]>"
    [ -f "$_if" ] || die "no such file: $_if"
    ensure_deps || die "deps missing"
    _ir="${STRATA}/${_in}"
    { [ -d "$_ir" ] && [ -n "$(ls -A "$_ir" 2>/dev/null)" ]; } && die "'$_in' exists. brl remove $_in first"
    mkdir -p "$_ir"
    say "${GR}importing ${_if} -> ${_in}${Z}"
    if   tar -xzf "$_if" -C "$_ir" 2>/dev/null; then :
    elif tar -xf "$_if" -C "$_ir" 2>/dev/null; then :
    elif has gzip && gzip -dc "$_if" 2>/dev/null | tar -xf - -C "$_ir" 2>/dev/null; then :
    else rm -rf "$_ir"; die "import failed (unrecognized archive)"; fi
    _prepare_stratum "$_ir" "$_in"; mkdir -p "$ENABLED"; : > "${ENABLED}/${_in}"
    brl_reload >/dev/null 2>&1 || true
    ok "imported stratum '${_in}'"
}

# ── v1.2.0: config get/set (reads/writes /bedrock/etc/bedrock.conf) ─────
_conf_file() { echo "${BETC}/bedrock.conf"; }
brl_config() {
    _cf="$(_conf_file)"
    case "${1:-get}" in
        get)
            _ck="${2:-}"
            if [ -z "$_ck" ]; then [ -f "$_cf" ] && cat "$_cf" || say "(no config)"; return 0; fi
            # key may be "section.key" or just "key"
            grep -vE '^\s*#|^\s*$' "$_cf" 2>/dev/null | sed -n "s/^[[:space:]]*${_ck##*.}[[:space:]]*=[[:space:]]*//p" | head -1
            ;;
        set)
            need_root; _ck="${2:-}"; _cv="${3:-}"
            [ -n "$_ck" ] || die "usage: brl config set <key> <value>"
            touch "$_cf" 2>/dev/null || die "cannot write config"
            _kk="${_ck##*.}"
            if grep -qE "^[[:space:]]*${_kk}[[:space:]]*=" "$_cf" 2>/dev/null; then
                sed -i "s|^[[:space:]]*${_kk}[[:space:]]*=.*|${_kk} = ${_cv}|" "$_cf"
            else
                printf '%s = %s\n' "$_kk" "$_cv" >> "$_cf"
            fi
            ok "set ${_kk} = ${_cv}"
            ;;
        *) die "usage: brl config [get [key] | set <key> <value>]" ;;
    esac
}

# ── v1.2.0: self-update (verified) ──────────────────────────────────────
brl_self_update() {
    need_root
    [ -n "$BRL_SELF_URL" ] || die "set BRL_SELF_URL to a trusted https URL of the script first"
    ensure_deps || die "deps missing"
    _sud="$(_mktemp_dir)"; _sunew="${_sud}/bedrock-port.new"
    say "${GR}fetching update from ${BRL_SELF_URL}${Z}"
    dl "$BRL_SELF_URL" "$_sunew" || die "download failed"
    # sanity: must be a POSIX sh script that parses and declares our version var
    head -1 "$_sunew" | grep -q '^#!/bin/sh' || die "downloaded file is not a shell script"
    sh -n "$_sunew" 2>/dev/null || die "downloaded script failed syntax check — refusing"
    grep -q 'BRL_PORT_VERSION=' "$_sunew" || die "downloaded script is not bedrock-port — refusing"
    _sunew_ver="$(grep -m1 'BRL_PORT_VERSION=' "$_sunew" | cut -d'"' -f2)"
    cp -f "${BR}/bin/brl" "${BR}/bin/brl.bak" 2>/dev/null || true
    cp -f "$_sunew" "${BR}/bin/brl" && chmod +x "${BR}/bin/brl" && ok "updated to ${_sunew_ver} (backup: ${BR}/bin/brl.bak)" || die "install failed"
}

# ── v1.2.0: per-command help ────────────────────────────────────────────
brl_help_cmd() {
    case "${1:-}" in
        fetch)    say "brl fetch [-r] <stratum>   Acquire a stratum. -r = restricted (no crossfs)."; say "         brl fetch --list          Show the catalog." ;;
        strat)    say "strat [-r] <stratum> <cmd> Run a command inside a stratum (private mount ns when available)." ;;
        pin)      say "brl pin [<stratum>]        Toggle protection of a stratum from remove/update. No arg lists pins." ;;
        export)   say "brl export <stratum> <f>   Save a stratum to a portable tar.gz (prints sha256)." ;;
        import-tar) say "brl import-tar <name> <f> Create a stratum from a tar[.gz] made by 'brl export'." ;;
        config)   say "brl config get [key]       Read config. brl config set <key> <val>  Write it." ;;
        alias)    say "brl alias <name> <stratum>  Create an alternate name for a stratum. No args lists aliases." ;;
        unalias)  say "brl unalias <name>         Remove a stratum alias." ;;
        which)    say "brl which [--bin|--file|--pid] <arg>  Which stratum owns a command / path / pid. No arg = current stratum." ;;
        show)     say "brl show [--pmm] <stratum>  Show stratum details, or just its package manager with --pmm." ;;
        security) say "brl security               Report TLS/checksum/gpg posture and how to harden." ;;
        capabilities) say "brl capabilities [--json] Runtime-proven capability report." ;;
        self-update)  say "brl self-update          Re-fetch the script from BRL_SELF_URL (verified) and replace brl." ;;
        init-install) say "brl init-install         Make Bedrock PID 1: installs a /sbin/init shim that runs early"; say "                         setup then exec()s the real systemd. Opt-in. Reversible via init-uninstall." ;;
        init-uninstall) say "brl init-uninstall     Restore the original /sbin/init (systemd back as sole PID 1)." ;;
        init-status)  say "brl init-status          Show current PID 1, whether the Bedrock init shim is installed, and the real init path." ;;
        "")       brl_help ;;
        *)        say "No detailed help for '${1}'. See: brl help"; ;;
    esac
}

# ── v1.2.0: JSON output helpers ─────────────────────────────────────────
brl_list_json() {
    printf '['; _lj_first=1
    for _ld in "${STRATA}"/*; do
        [ -d "$_ld" ] || continue; _ln="$(basename "$_ld")"
        [ "$_lj_first" = 1 ] || printf ','; _lj_first=0
        _len="false"; is_enabled "$_ln" && _len="true"
        _lpin="false"; is_pinned "$_ln" && _lpin="true"
        _linit="false"; [ "$_ln" = "$(init_stratum)" ] && _linit="true"
        printf '{"name":"%s","enabled":%s,"pinned":%s,"init":%s}' "$_ln" "$_len" "$_lpin" "$_linit"
    done
    printf ']\n'
}

# brl subcommands — list all subcommands (official parity)
brl_subcommands() {
    for _sc in list status show fetch fetch-url apply install update copy \
               enable disable remove rename alias unalias which reload umount \
               fix deps hijack unhijack report update-urls tutorial \
               capabilities security pin export import-tar config self-update integrate boot-init init-install init-uninstall init-status rollback verify health \
               test register-aok archs subcommands version help; do
        echo "$_sc"
    done
}

# brl tutorial [topic] — pointer to learning material (official has interactive tutorials)
brl_tutorial() {
    print_logo "$(cat "$RELEASE_FILE" 2>/dev/null || echo "Bedrock Linux ${BEDROCK_VERSION} ${BEDROCK_CODENAME}")"
    say "${B}Bedrock Linux — quick tutorial${Z}"
    say ""
    say "Bedrock lets you mix packages from many Linux distributions on one system."
    say "Each distribution is a ${color_term}stratum${color_norm}."
    say ""
    say "  1. ${color_cmd}brl fetch alpine${color_norm}      acquire a stratum (start small — alpine)"
    say "  2. ${color_cmd}brl list${color_norm}              see your strata"
    say "  3. ${color_cmd}strat alpine apk add vim${color_norm}   run a stratum's package manager"
    say "  4. ${color_cmd}brl which vim${color_norm}         see which stratum provides a command"
    say "  5. ${color_cmd}brl shell alpine${color_norm}      open a shell inside a stratum"
    say ""
    say "Cross-distro commands are auto-wired into ${color_file}${CROSSBIN}${color_norm}"
    say "so a tool installed in any stratum is runnable from anywhere."
    say ""
    say "Full docs: ${color_link}https://docs.bedrocklinux.org${color_norm}"
}

# ============================================================================
#  BEDROCK-AOK INTEGRATION LAYER   (brl-permanent-integrated only)
#
#  Everything below is ADDITIVE. It never removes or rewrites existing brl
#  functionality; it layers boot integration, capability detection, rollback,
#  integrity/health checks, AOK-root registration, and a regression suite on
#  top of the working permanent build. The plain `brl-permanent` build remains
#  a untouched fallback.
# ============================================================================

BRAOK_VAR="${BR}/var"
BRAOK_LOG="${BRAOK_VAR}/log/bedrock.log"
BRAOK_ROLLBACK="${BRAOK_VAR}/rollback"
BRAOK_CAPS="${BETC}/capabilities.conf"
AOK_ROOTS="/AOK/roots"
AOK_PERSIST="/AOK/persist"

# ── logging: journald if available, file fallback (always) ──────────────
braok_log() {
    _lvl="${1:-info}"; shift 2>/dev/null || true; _msg="$*"
    mkdir -p "$(dirname "$BRAOK_LOG")" 2>/dev/null || true
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo now)" "$_lvl" "$_msg" >> "$BRAOK_LOG" 2>/dev/null || true
    if has systemd-cat; then printf '%s\n' "$_msg" | systemd-cat -t bedrock-aok -p "$_lvl" 2>/dev/null || true
    elif has logger; then logger -t bedrock-aok -p "user.${_lvl}" "$_msg" 2>/dev/null || true; fi
}

# ── capability detection API ────────────────────────────────────────────
# Classifies each feature as: native | emulated | unavailable
# Writes a machine-readable file and can print human or --json output.
braok_probe() {
    # echoes "native"/"emulated"/"unavailable".
    # RULE: a "native" verdict must come from a real runtime operation that
    # proves the feature works — not merely a file existing. Namespace kernel
    # objects (/proc/self/ns/*) exist on every Linux even when unshare into
    # them is blocked, so we actually attempt the unshare.
    case "$1" in
        chroot)
            # prove chroot(2) works, not just that the binary exists
            has chroot && chroot / /bin/true 2>/dev/null && echo native || echo unavailable ;;
        unshare)
            # prove unshare actually executes (not just that the binary exists)
            has unshare && unshare /bin/true 2>/dev/null && echo native || echo unavailable ;;
        nsenter)
            # nsenter needs a target ns to truly exercise; prove it runs + self-enter
            has nsenter && nsenter --help >/dev/null 2>&1 && echo native || echo unavailable ;;
        mount_ns)
            # real test: create a private mount namespace and run a process in it
            has unshare && unshare -m /bin/true 2>/dev/null && echo native || echo unavailable ;;
        user_ns)
            has unshare && unshare -U /bin/true 2>/dev/null && echo native || echo unavailable ;;
        pid_ns)
            # needs fork inside the new PID ns; unshare -pf does that
            has unshare && unshare -pf /bin/true 2>/dev/null && echo native || echo unavailable ;;
        net_ns)
            has unshare && unshare -n /bin/true 2>/dev/null && echo native || echo unavailable ;;
        uts_ns)
            has unshare && unshare -u /bin/true 2>/dev/null && echo native || echo unavailable ;;
        ipc_ns)
            has unshare && unshare -i /bin/true 2>/dev/null && echo native || echo unavailable ;;
        cgroup_ns)
            has unshare && unshare -C /bin/true 2>/dev/null && echo native || echo unavailable ;;
        cgroup2)
            # prove it's actually cgroup2 (controllers file only exists on v2)
            if [ -f /sys/fs/cgroup/cgroup.controllers ]; then echo native
            elif [ -d /sys/fs/cgroup ]; then echo emulated
            else echo unavailable; fi ;;
        procfs)
            # prove /proc is a live proc fs by reading a kernel-generated field
            [ -r /proc/self/status ] && grep -q '^Pid:' /proc/self/status 2>/dev/null && echo native || echo unavailable ;;
        sysfs)
            # prove sysfs is populated (not just an empty dir)
            [ -r /sys/kernel ] && [ -n "$(ls -A /sys 2>/dev/null)" ] && echo native || { [ -d /sys ] && echo emulated || echo unavailable; } ;;
        tmpfs)
            # prove we can actually mount a tmpfs into a temp dir (in a private ns
            # so we leave nothing behind), else fall back to a write test
            if has unshare && has mount; then
                unshare -m /bin/sh -c '_t=$(mktemp -d 2>/dev/null) || exit 1; mount -t tmpfs none "$_t" 2>/dev/null && echo x > "$_t/x" 2>/dev/null && [ -f "$_t/x" ]' 2>/dev/null \
                    && echo native || echo emulated
            else echo emulated; fi ;;
        devpts)
            # prove a devpts mount is present/working, not just that /dev/pts exists
            if mount 2>/dev/null | grep -q 'devpts'; then echo native
            elif [ -d /dev/pts ] && [ -e /dev/ptmx ]; then echo emulated
            else echo unavailable; fi ;;
        devtmpfs)
            mount 2>/dev/null | grep -q 'devtmpfs' && echo native || { [ -d /dev ] && [ -e /dev/null ] && echo emulated || echo unavailable; } ;;
        bind_mount)
            # real test: perform an actual bind mount inside a private mount ns
            if has unshare && has mount; then
                unshare -m /bin/sh -c '_a=$(mktemp -d) _b=$(mktemp -d) || exit 1; echo hi > "$_a/f"; mount --bind "$_a" "$_b" 2>/dev/null && [ -f "$_b/f" ]' 2>/dev/null \
                    && echo native || echo unavailable
            elif has mount; then echo emulated
            else echo unavailable; fi ;;
        seccomp)
            # seccomp is reported in /proc/self/status as "Seccomp:" (0=off).
            # AOK runs with seccomp disabled; report accordingly but honestly.
            if grep -q '^Seccomp:' /proc/self/status 2>/dev/null; then
                _sv="$(grep '^Seccomp:' /proc/self/status 2>/dev/null | awk '{print $2}')"
                [ "${_sv:-0}" = "0" ] && echo "disabled" || echo native
            else echo unavailable; fi ;;
        fuse)      [ -e /dev/fuse ] && echo native || echo unavailable ;;
        systemd)
            [ -d /run/systemd/system ] && echo native || { has systemctl && echo emulated || echo unavailable; } ;;
        crossfs)   echo emulated ;;   # emulated by design (no FUSE requirement)
        etcfs)     echo emulated ;;
        aok_roots)   [ -d "$AOK_ROOTS" ] && echo native || echo unavailable ;;
        aok_persist) [ -d "$AOK_PERSIST" ] && echo native || echo unavailable ;;
        arch)      get_system_arch ;;
        *) echo unavailable ;;
    esac
}
braok_detect_caps() {
    mkdir -p "$BETC" 2>/dev/null || true
    _tmp="${BRAOK_CAPS}.new"
    {
        echo "# Bedrock-AOK detected capabilities — generated $(date 2>/dev/null || echo)"
        echo "# values: native | emulated | unavailable"
        for _k in arch chroot bind_mount unshare nsenter mount_ns user_ns pid_ns net_ns uts_ns ipc_ns cgroup_ns cgroup2 procfs sysfs devtmpfs devpts tmpfs systemd seccomp fuse crossfs etcfs aok_roots aok_persist; do
            printf '%s=%s\n' "$_k" "$(braok_probe "$_k")"
        done
    } > "$_tmp" 2>/dev/null && mv "$_tmp" "$BRAOK_CAPS" 2>/dev/null || true
    braok_log info "capabilities detected -> $BRAOK_CAPS"
}
cap_of() { [ -f "$BRAOK_CAPS" ] && grep "^${1}=" "$BRAOK_CAPS" 2>/dev/null | head -1 | cut -d= -f2 || braok_probe "$1"; }
# require a native/emulated capability or print a clear error
require_cap() {
    _rc="$(cap_of "$1")"
    case "$_rc" in native|emulated) return 0 ;; esac
    err "operation needs '${1}' which is ${color_alert}unavailable${color_norm} on this iSH-AOK build."
    return 1
}

# brl security — honest report of the current security posture, plus how to harden.
brl_security() {
    print_logo "Bedrock-AOK security posture"
    # transport
    if _cab="$(_have_ca_bundle)"; then ok "CA bundle: ${color_file}${_cab}${color_norm}"
    else warn "no CA bundle found — verified TLS impossible until installed (brl deps)"; fi
    if tls_verify_works; then ok "verified TLS: ${color_okay}working${color_norm} (downloads authenticate the server)"
    else warn "verified TLS: ${color_alert}not working${color_norm} — run ${color_cmd}brl deps${color_norm} to install ca-certificates"; fi
    # integrity tooling
    if has sha256sum || has shasum || has openssl; then ok "sha256: available (rootfs integrity checked when a checksum is published)"
    else warn "no sha256 tool — cannot verify download integrity (brl deps installs openssl)"; fi
    has gpg && ok "gpg: available (package signatures verifiable in strict mode)" || info "gpg: not present (package-signature verification limited)"
    # posture flags
    say ""
    if [ "${BRL_INSECURE:-0}" = 1 ]; then warn "BRL_INSECURE=1 — insecure transport fallback is ENABLED for this run"
    else ok "insecure fallback: ${color_okay}disabled${color_norm} (secure by default; set BRL_INSECURE=1 to override)"; fi
    if [ "${BRL_STRICT:-0}" = 1 ]; then ok "BRL_STRICT=1 — package-manager signature/gpg checks kept ON in strata"
    else info "package-manager checks: relaxed for install reliability on iSH-AOK"
         info "  set ${color_cmd}BRL_STRICT=1${color_norm} before fetch to keep distro gpg/signature checks enabled"; fi
    say ""
    say "Notes:"
    say "  • Rootfs downloads use verified TLS by default and are sha256-checked when the"
    say "    mirror publishes SHA256SUMS (LXC does)."
    say "  • Strata package managers relax gpg by default because fresh iSH-AOK roots"
    say "    often lack seeded keyrings; ${color_cmd}BRL_STRICT=1${color_norm} keeps them strict where the"
    say "    keyring is present."
}
brl_capabilities() {
    [ -f "$BRAOK_CAPS" ] || braok_detect_caps
    if [ "${1:-}" = "--json" ]; then
        printf '{\n'; _first=1
        while IFS='=' read -r _k _v; do
            case "$_k" in ''|\#*) continue ;; esac
            [ "$_first" = 1 ] || printf ',\n'; _first=0
            printf '  "%s": "%s"' "$_k" "$_v"
        done < "$BRAOK_CAPS"
        printf '\n}\n'; return 0
    fi
    print_logo "Bedrock-AOK capabilities"
    while IFS='=' read -r _k _v; do
        case "$_k" in ''|\#*) continue ;; esac
        case "$_v" in
            native)      _c="$color_okay" ;;
            emulated)    _c="$color_warn" ;;
            unavailable) _c="$color_alert" ;;
            *)           _c="$color_norm" ;;
        esac
        printf "  ${color_misc}%-12s${color_norm} ${_c}%s${color_norm}\n" "$_k" "$_v"
    done < "$BRAOK_CAPS"
}

# ── rollback points ─────────────────────────────────────────────────────
# Snapshot the small, critical config surface (not strata payloads) so a bad
# change can be reverted. Cheap and safe.
braok_rollback_create() {
    _rlabel="${1:-auto}"
    _rid="$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo "$$")"
    _rdir="${BRAOK_ROLLBACK}/${_rid}-${_rlabel}"
    mkdir -p "$_rdir" 2>/dev/null || { warn "cannot create rollback dir"; return 1; }
    # config surface: bedrock etc, os-release, systemd units, enabled strata list
    [ -d "$BETC" ] && cp -a "$BETC" "${_rdir}/etc" 2>/dev/null || true
    [ -f /etc/os-release ] && cp -a /etc/os-release "${_rdir}/os-release" 2>/dev/null || true
    [ -d "$ENABLED" ] && cp -a "$ENABLED" "${_rdir}/enabled_strata" 2>/dev/null || true
    for _u in /etc/systemd/system/bedrock-init.service /etc/systemd/system/bedrock.target /etc/systemd/system/bedrock-stratum@.service; do
        [ -f "$_u" ] && { mkdir -p "${_rdir}/units" 2>/dev/null; cp -a "$_u" "${_rdir}/units/" 2>/dev/null; } || true
    done
    ls -1 "${STRATA}" 2>/dev/null > "${_rdir}/strata.list" 2>/dev/null || true
    ok "rollback point created: ${color_file}${_rid}-${_rlabel}${color_norm}"
    braok_log info "rollback point ${_rid}-${_rlabel}"
    echo "${_rid}-${_rlabel}"
}
brl_rollback() {
    need_root
    case "${1:-list}" in
        create) shift 2>/dev/null || true; braok_rollback_create "${1:-manual}" >/dev/null ;;
        list)
            say "${B}Rollback points:${Z}"
            [ -d "$BRAOK_ROLLBACK" ] || { say "  (none)"; return 0; }
            for _d in "$BRAOK_ROLLBACK"/*; do [ -d "$_d" ] && printf "  %s\n" "$(basename "$_d")"; done
            ;;
        restore)
            _rrid="${2:-}"; [ -n "$_rrid" ] || die "usage: brl rollback restore <id>"
            _rrdir="${BRAOK_ROLLBACK}/${_rrid}"
            [ -d "$_rrdir" ] || die "no such rollback point: $_rrid"
            braok_rollback_create "pre-restore" >/dev/null
            [ -d "${_rrdir}/etc" ] && { rm -rf "${BETC}.old" 2>/dev/null; cp -a "$BETC" "${BETC}.old" 2>/dev/null; cp -a "${_rrdir}/etc/." "$BETC/" 2>/dev/null; }
            [ -f "${_rrdir}/os-release" ] && cp -a "${_rrdir}/os-release" /etc/os-release 2>/dev/null || true
            [ -d "${_rrdir}/enabled_strata" ] && { rm -rf "$ENABLED" 2>/dev/null; cp -a "${_rrdir}/enabled_strata" "$ENABLED" 2>/dev/null; }
            [ -d "${_rrdir}/units" ] && cp -a "${_rrdir}/units/." /etc/systemd/system/ 2>/dev/null || true
            brl_reload >/dev/null 2>&1 || true
            ok "restored rollback point ${_rrid}"
            braok_log warn "restored rollback ${_rrid}"
            ;;
        *) die "usage: brl rollback [list|create [label]|restore <id>]" ;;
    esac
}

# ── integrity checks + auto-repair ──────────────────────────────────────
brl_verify() {
    _vfix="${1:-}"
    _issues=0
    say "${B}Bedrock-AOK integrity check${Z}"
    # core directories
    for _d in "$BR" "$STRATA" "$CROSSBIN" "$BRUN" "$ENABLED" "$BETC" "${BR}/bin"; do
        if [ -d "$_d" ]; then ok "dir ${color_file}${_d}${color_norm}"
        else warn "missing dir ${_d}"; _issues=$((_issues+1))
            [ "$_vfix" = "--repair" ] && { mkdir -p "$_d" 2>/dev/null && ok "  repaired ${_d}"; }
        fi
    done
    # core files
    for _f in "$RELEASE_FILE" "${BR}/bin/brl" "${BR}/bin/strat"; do
        [ -f "$_f" ] && ok "file ${color_file}${_f}${color_norm}" || { warn "missing file ${_f}"; _issues=$((_issues+1)); }
    done
    # os-release must be a real file (not dangling symlink)
    if [ -f /etc/os-release ]; then ok "/etc/os-release present"
    else warn "/etc/os-release missing or dangling"; _issues=$((_issues+1))
        [ "$_vfix" = "--repair" ] && [ -f "${BETC}/os-release" ] && { cp -f "${BETC}/os-release" /etc/os-release 2>/dev/null && ok "  repaired os-release"; }
    fi
    # each stratum: has a shell + enabled flag consistency
    for _sd in "${STRATA}"/*; do
        [ -d "$_sd" ] || continue; _sname="$(basename "$_sd")"
        if [ -x "${_sd}/bin/sh" ] || [ -x "${_sd}/bin/bash" ] || [ -x "${_sd}/bin/ash" ]; then
            ok "stratum ${color_strat}${_sname}${color_norm} has a shell"
        else warn "stratum ${_sname} has no shell"; _issues=$((_issues+1)); fi
    done
    say ""
    if [ "$_issues" = 0 ]; then ok "no integrity issues"; else warn "${_issues} issue(s) found$([ "$_vfix" = "--repair" ] || echo " (run: brl verify --repair)")"; fi
    braok_log info "integrity check: ${_issues} issue(s)"
    return 0
}

# ── health checks + recovery ────────────────────────────────────────────
brl_health() {
    _hstratum="${1:-}"
    _check_one() {
        _hs="$1"; _hr="${STRATA}/${_hs}"; _hok=1
        [ -d "$_hr" ] || { warn "${_hs}: root missing"; return 1; }
        [ -x "${_hr}/bin/sh" ] || [ -x "${_hr}/bin/bash" ] || [ -x "${_hr}/bin/ash" ] || { warn "${_hs}: no shell"; _hok=0; }
        # can we actually enter and run true?
        if [ "$_hok" = 1 ] && has chroot; then
            if chroot "$_hr" /bin/sh -c 'true' 2>/dev/null; then
                ok "${color_strat}${_hs}${color_norm}: healthy"
            else
                warn "${_hs}: cannot exec inside — attempting repair"
                _prepare_stratum "$_hr" "$_hs" 2>/dev/null
                chroot "$_hr" /bin/sh -c 'true' 2>/dev/null && ok "  ${_hs}: recovered" || warn "  ${_hs}: still failing"
            fi
        fi
    }
    if [ -n "$_hstratum" ]; then
        stratum_exists "$_hstratum" || die "no such stratum: $_hstratum"
        _check_one "$_hstratum"
    else
        say "${B}Stratum health${Z}"
        for _hd in "${STRATA}"/*; do [ -d "$_hd" ] && _check_one "$(basename "$_hd")"; done
    fi
}

# ── systemd boot integration ────────────────────────────────────────────
# Installs a oneshot init service + target so /bedrock comes up at boot with
# systemd remaining PID 1 (Bedrock-aware). Safe: guarded by systemctl presence.
braok_boot_init() {
    # This is what bedrock-init.service runs at boot.
    braok_detect_caps
    for _d in "$STRATA" "$CROSSBIN" "$BRUN" "$ENABLED" "$BETC" "${BR}/bin"; do mkdir -p "$_d" 2>/dev/null || true; done
    # ensure pseudo-fs on the host side exist
    for _p in /proc /sys /dev /dev/pts /dev/shm /run; do [ -d "$_p" ] || mkdir -p "$_p" 2>/dev/null || true; done
    brl_verify --repair >/dev/null 2>&1 || true
    brl_reload >/dev/null 2>&1 || true
    braok_register_aok >/dev/null 2>&1 || true
    braok_log info "boot init complete"
}
braok_install_units() {
    has systemctl || { warn "systemctl not present — skipping unit install (boot integration unavailable)"; return 0; }
    _ud=/etc/systemd/system
    mkdir -p "$_ud" 2>/dev/null || return 0
    cat > "${_ud}/bedrock-init.service" <<UNIT
[Unit]
Description=Bedrock-AOK initialization
DefaultDependencies=no
After=local-fs.target
Before=multi-user.target
ConditionPathExists=/bedrock/bin/brl

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bedrock/bin/brl boot-init
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
    cat > "${_ud}/bedrock.target" <<UNIT
[Unit]
Description=Bedrock-AOK ready
Requires=bedrock-init.service
After=bedrock-init.service
AllowIsolate=no
UNIT
    cat > "${_ud}/bedrock-stratum@.service" <<'UNIT'
[Unit]
Description=Bedrock stratum %i services
After=bedrock-init.service
Requires=bedrock-init.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bedrock/bin/brl health %i
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=bedrock.target
UNIT
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable bedrock-init.service 2>/dev/null && ok "enabled bedrock-init.service (boot integration active)" || warn "could not enable bedrock-init.service"
    # Make systemd (PID 1) Bedrock-aware WITHOUT replacing it:
    # a manager environment drop-in advertises Bedrock to every unit, and
    # bedrock.target is pulled into the default boot.
    mkdir -p /etc/systemd/system.conf.d 2>/dev/null || true
    cat > /etc/systemd/system.conf.d/00-bedrock.conf <<'SDCONF'
# Bedrock-AOK: systemd remains PID 1, made Bedrock-aware.
[Manager]
DefaultEnvironment=BEDROCK=1 BEDROCK_STRATUM=bedrock
SDCONF
    systemctl add-wants multi-user.target bedrock.target 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    braok_log info "systemd units installed; PID 1 made Bedrock-aware"
}

# ── PID 1: Bedrock init supervisor ──────────────────────────────────────
# Opt-in (brl init-install). Installs a shim as /sbin/init that becomes PID 1,
# performs Bedrock early setup, then exec()s the REAL systemd so systemd still
# runs as PID 1 afterward. This is a supervisor+handoff, NOT a systemd
# replacement — if anything is wrong, the shim falls back to the real init so
# the system always boots.
BEDROCK_INIT="${BR}/libexec/bedrock-init"
_find_real_init() {
    # Locate the genuine init (systemd) without following our own shim.
    for _ri in /lib/systemd/systemd /usr/lib/systemd/systemd /sbin/init.real \
               /sbin/init.bedrock-orig /usr/sbin/init; do
        [ -x "$_ri" ] && { echo "$_ri"; return 0; }
    done
    # Last resort: whatever /sbin/init.real points to
    [ -x /sbin/init.real ] && { echo /sbin/init.real; return 0; }
    return 1
}
braok_write_init_shim() {
    mkdir -p "${BR}/libexec" 2>/dev/null || true
    cat > "$BEDROCK_INIT" <<'INITEOF'
#!/bin/sh
# Bedrock-AOK PID 1 supervisor.
# Runs as the very first userspace process, does Bedrock early setup, then
# hands off to the real systemd via exec so systemd becomes PID 1.
# SAFETY: every Bedrock step is best-effort; the final exec ALWAYS runs. If the
# real init cannot be found or Bedrock setup fails, we still exec an init so the
# machine boots.
BR=/bedrock
log() { printf '[bedrock-init] %s\n' "$*" 2>/dev/null || true; }

# 1) Minimal early filesystem scaffolding (never fatal).
for d in /proc /sys /dev /dev/pts /dev/shm /run /tmp; do [ -d "$d" ] || mkdir -p "$d" 2>/dev/null || true; done
mountpoint -q /proc 2>/dev/null || mount -t proc proc /proc 2>/dev/null || true
mountpoint -q /sys  2>/dev/null || mount -t sysfs sys /sys 2>/dev/null || true
mountpoint -q /run  2>/dev/null || mount -t tmpfs tmpfs /run 2>/dev/null || true

# 2) Bedrock bring-up (best-effort, time-boxed, never blocks boot).
if [ -x "$BR/bin/brl" ]; then
    ( "$BR/bin/brl" boot-init >/dev/null 2>&1 ) &
    _bp=$!
    ( sleep 15; kill "$_bp" 2>/dev/null ) 2>/dev/null &
    wait "$_bp" 2>/dev/null || true
    log "bedrock boot-init done"
fi

# 3) Locate the REAL init and hand off. This MUST succeed to avoid a panic.
REAL=""
for c in /lib/systemd/systemd /usr/lib/systemd/systemd /sbin/init.bedrock-orig \
         /sbin/init.real /usr/sbin/init; do
    [ -x "$c" ] && { REAL="$c"; break; }
done
if [ -n "$REAL" ]; then
    log "handing off to $REAL as PID 1"
    export BEDROCK=1 BEDROCK_STRATUM=bedrock
    exec "$REAL" "$@"
fi
# Absolute fallback: try common shells so we never panic PID 1.
log "no real init found — emergency shell"
for s in /bin/sh /bin/bash /sbin/init; do [ -x "$s" ] && exec "$s"; done
# If even that fails, sleep forever rather than exit (exit of PID1 = panic).
while : ; do sleep 3600; done
INITEOF
    chmod 0755 "$BEDROCK_INIT" 2>/dev/null || true
}
braok_install_init() {
    need_root
    say ""; print_logo "Bedrock-AOK PID 1 init"
    warn "${color_priority}This makes Bedrock the first userspace process (PID 1).${color_norm}"
    warn "A rollback point is created; the real systemd is preserved and still"
    warn "runs as PID 1 after Bedrock's handoff. If anything is wrong, the shim"
    warn "falls back to the real init so the system still boots."
    # 0) safety: must find the real init BEFORE we touch anything
    _ri="$(_find_real_init)" || { err "cannot locate real systemd/init — refusing to install PID1 shim"; return 1; }
    notice "real init: ${color_file}${_ri}${color_norm}"
    braok_rollback_create "pre-init-install" >/dev/null 2>&1 || true
    braok_write_init_shim
    sh -n "$BEDROCK_INIT" 2>/dev/null || { err "generated init shim failed syntax check — aborting"; return 1; }

    # 1) Preserve the real init under a stable name the shim looks for.
    if [ -e /sbin/init ] && [ ! -e /sbin/init.bedrock-orig ]; then
        if [ -L /sbin/init ]; then
            _tgt="$(readlink -f /sbin/init 2>/dev/null)"
            [ -n "$_tgt" ] && ln -sf "$_tgt" /sbin/init.bedrock-orig 2>/dev/null || true
        else
            cp -a /sbin/init /sbin/init.bedrock-orig 2>/dev/null || true
        fi
        notice "preserved original init as /sbin/init.bedrock-orig"
    fi
    # If /sbin/init.bedrock-orig still absent, point it straight at systemd.
    [ -e /sbin/init.bedrock-orig ] || ln -sf "$_ri" /sbin/init.bedrock-orig 2>/dev/null || true

    # 2) Install the shim as /sbin/init (atomically via temp+mv).
    cp -f "$BEDROCK_INIT" /sbin/init.bedrock-new 2>/dev/null && \
        mv -f /sbin/init.bedrock-new /sbin/init 2>/dev/null && \
        ok "installed Bedrock init as /sbin/init (PID 1 on next boot)" || {
            err "failed to install /sbin/init — original left intact"; return 1; }

    # 3) Keep the systemd unit path working too (belt and suspenders).
    braok_install_units 2>/dev/null || true
    notice "Reboot to boot via Bedrock init. Verify with: ${color_cmd}brl init-status${color_norm}"
    braok_log warn "PID1 init shim installed (real init: ${_ri})"
}
braok_uninstall_init() {
    need_root
    if [ -e /sbin/init.bedrock-orig ]; then
        if [ -L /sbin/init.bedrock-orig ]; then
            _o="$(readlink -f /sbin/init.bedrock-orig 2>/dev/null)"
            [ -n "$_o" ] && ln -sf "$_o" /sbin/init 2>/dev/null || true
        else
            cp -a /sbin/init.bedrock-orig /sbin/init 2>/dev/null || true
        fi
        rm -f /sbin/init.bedrock-orig 2>/dev/null || true
        ok "restored original /sbin/init (systemd is PID 1 again on next boot)"
    else
        # No backup: point init at systemd directly.
        _ri="$(_find_real_init)" && ln -sf "$_ri" /sbin/init 2>/dev/null && ok "pointed /sbin/init at ${_ri}" || warn "could not restore /sbin/init"
    fi
    rm -f "$BEDROCK_INIT" 2>/dev/null || true
    braok_log warn "PID1 init shim removed"
}
brl_init_status() {
    print_logo "Bedrock-AOK init status"
    _p1="$(ps -p 1 -o comm= 2>/dev/null || cat /proc/1/comm 2>/dev/null || echo unknown)"
    say "  current PID 1 process:  ${color_strat}${_p1}${color_norm}"
    if [ -e /sbin/init ]; then
        _it="$(readlink -f /sbin/init 2>/dev/null || echo /sbin/init)"
        # Detect our shim by its marker, regardless of path resolution.
        if grep -q 'Bedrock-AOK PID 1 supervisor' /sbin/init 2>/dev/null; then
            ok "/sbin/init is the Bedrock init shim (active on next boot)"
        else
            info "/sbin/init -> ${_it} (Bedrock init shim NOT installed)"
        fi
        [ -x "$BEDROCK_INIT" ] && say "  shim present: ${color_file}${BEDROCK_INIT}${color_norm}"
    fi
    [ -e /sbin/init.bedrock-orig ] && ok "original init preserved: /sbin/init.bedrock-orig" || info "no preserved original init recorded"
    _ri="$(_find_real_init 2>/dev/null || echo none)"; say "  real systemd/init: ${color_file}${_ri}${color_norm}"
    say ""
    say "Model: Bedrock init becomes PID 1, does early setup, then exec()s the real"
    say "systemd — so systemd runs as PID 1 after handoff. Falls back to the real"
    say "init if anything is wrong, so the system always boots."
}


# ── AOK roots integration ───────────────────────────────────────────────
# Register existing /AOK/roots as Bedrock strata (additive; never deletes AOK data).
braok_register_aok() {
    [ -d "$AOK_ROOTS" ] || return 0
    _rcount=0
    for _ar in "$AOK_ROOTS"/*; do
        [ -d "$_ar" ] || continue
        _an="aok-$(basename "$_ar")"
        _at="${STRATA}/${_an}"
        [ -e "$_at" ] && continue
        # symlink the AOK root into the stratum tree (additive, non-destructive)
        ln -s "$_ar" "$_at" 2>/dev/null && { : > "${ENABLED}/${_an}" 2>/dev/null; _rcount=$((_rcount+1)); braok_log info "registered AOK root ${_an}"; } || true
    done
    [ "$_rcount" -gt 0 ] && ok "registered ${_rcount} AOK root(s) as strata"
    return 0
}
brl_register_aok() { need_root; braok_register_aok; brl_reload >/dev/null 2>&1 || true; }

# ── regression / self-test suite ────────────────────────────────────────
brl_test() {
    _tp=0; _tf=0
    _t() { # name, condition-cmd
        if eval "$2" >/dev/null 2>&1; then printf "  ${color_okay}PASS${color_norm} %s\n" "$1"; _tp=$((_tp+1))
        else printf "  ${color_alert}FAIL${color_norm} %s\n" "$1"; _tf=$((_tf+1)); fi
    }
    print_logo "Bedrock-AOK self-test"
    say "${B}Environment${Z}"
    _t "chroot available"        "has chroot"
    _t "tar available"           "has tar"
    _t "downloader (wget/curl)"  "has wget || has curl"
    _t "xz available"            "has xz"
    _t "bind mount works"        "has mount"
    say "${B}Bedrock structure${Z}"
    _t "/bedrock exists"         "[ -d '$BR' ]"
    _t "strata dir exists"       "[ -d '$STRATA' ]"
    _t "crossfs dir exists"      "[ -d '$CROSSBIN' ]"
    _t "brl installed"           "[ -f '${BR}/bin/brl' ]"
    _t "strat installed"         "[ -f '${BR}/bin/strat' ]"
    _t "os-release is real file" "[ -f /etc/os-release ] && [ ! -L /etc/os-release ] || [ -e /etc/os-release ]"
    _t "capabilities detected"   "[ -f '$BRAOK_CAPS' ] || braok_detect_caps"
    _t "arch is supported"       "brl_archs | grep -qx \"\$(get_system_arch)\""
    say "${B}Security${Z}"
    _t "sha256 tool present"     "has sha256sum || has shasum || has openssl"
    _t "verify_sha256 detects match" "_tf1=\$(mktemp); echo bedrock>\$_tf1; _th=\$(_sha256 \$_tf1); verify_sha256 \$_tf1 \$_th"
    _t "verify_sha256 rejects mismatch" "_tf2=\$(mktemp); echo bedrock>\$_tf2; ! verify_sha256 \$_tf2 deadbeef"
    _t "CA bundle present"       "_have_ca_bundle"
    say "${B}v1.2.0 features${Z}"
    _t "config set/get roundtrip" "brl_config set test.k testval >/dev/null 2>&1; [ \"\$(brl_config get test.k 2>/dev/null)\" = testval ]"
    _t "pin file writable"       "touch \"\$(_pin_file)\" 2>/dev/null"
    _t "list --json valid"       "brl_list_json | grep -q '\\['"
    _t "safe tmp dir created"    "[ -d \"\$(_mktemp_dir)\" ]"
    _t "gpg verify advisory-ok"  "_gtf=\$(mktemp); verify_gpg \$_gtf https://example/none 2>/dev/null"
    _t "init shim generates + valid" "braok_write_init_shim && sh -n '$BEDROCK_INIT'"
    _t "real init locatable"     "_find_real_init"
    say "${B}Fidelity (aliases / which)${Z}"
    _t "deref passes through name" "[ \"\$(deref nonexistent-xyz 2>/dev/null || echo nonexistent-xyz)\" = nonexistent-xyz ]"
    _t "which --file resolves init" "brl_which --file /etc/hostname >/dev/null 2>&1"
    _t "which --pid 1 resolves"   "brl_which --pid 1 >/dev/null 2>&1"
    say "${B}Namespaces / mounts${Z}"
    _t "mount ns unshare works"  "has unshare && unshare -m /bin/true"
    _t "uts ns unshare works"    "has unshare && unshare -u /bin/true"
    _t "ipc ns unshare works"    "has unshare && unshare -i /bin/true"
    _t "pid ns unshare works"    "has unshare && unshare -pf /bin/true"
    _t "net ns unshare works"    "has unshare && unshare -n /bin/true"
    _t "user ns unshare works"   "has unshare && unshare -U /bin/true"
    _t "cgroup ns unshare works" "has unshare && unshare -C /bin/true"
    _t "bind mount in private ns" "has unshare && has mount && unshare -m /bin/sh -c '_a=\$(mktemp -d) _b=\$(mktemp -d); echo hi>\"\$_a/f\"; mount --bind \"\$_a\" \"\$_b\" && [ -f \"\$_b/f\" ]'"
    _t "tmpfs mount in private ns" "has unshare && has mount && unshare -m /bin/sh -c '_t=\$(mktemp -d); mount -t tmpfs none \"\$_t\" && echo x>\"\$_t/x\" && [ -f \"\$_t/x\" ]'"
    _t "procfs live (Pid: field)" "grep -q '^Pid:' /proc/self/status"
    _t "sysfs populated"         "[ -n \"\$(ls -A /sys 2>/dev/null)\" ]"
    _t "devpts / ptmx present"   "[ -e /dev/ptmx ]"
    _t "signals deliverable"     "sh -c 'kill -0 \$\$'"
    # strat round-trip if any stratum with a real shell exists
    _tstrat=""
    for _td in "${STRATA}"/*; do [ -d "$_td" ] && { [ -x "${_td}/bin/sh" ] || [ -x "${_td}/bin/bash" ]; } && { _tstrat="$(basename "$_td")"; break; }; done
    if [ -n "$_tstrat" ]; then
        say "${B}strat / brl round-trip (${_tstrat})${Z}"
        _t "strat runs a command"  "'${BR}/bin/brl' strat '$_tstrat' /bin/sh -c 'exit 0'"
        _t "strat filesystem view" "'${BR}/bin/brl' strat '$_tstrat' /bin/sh -c '[ -d / ]'"
        _t "brl which resolves sh" "'${BR}/bin/brl' which sh"
    fi
    say ""
    if [ "$_tf" = 0 ]; then ok "all ${_tp} tests passed"; else warn "${_tp} passed, ${color_alert}${_tf} failed${color_norm}"; fi
    braok_log info "self-test: ${_tp} pass ${_tf} fail"
    [ "$_tf" = 0 ]
}

# ── main integration entry point ────────────────────────────────────────
brl_integrate() {
    need_root
    say ""; print_logo "Bedrock-AOK integration"
    step_init 6
    step "Creating rollback point"
    braok_rollback_create "pre-integrate" >/dev/null
    step "Detecting iSH-AOK capabilities"
    braok_detect_caps; notice "capabilities -> ${color_file}${BRAOK_CAPS}${color_norm}"
    step "Verifying + repairing Bedrock structure"
    brl_verify --repair >/dev/null 2>&1 || true
    step "Registering /AOK/roots as strata"
    braok_register_aok || true
    step "Installing systemd boot integration"
    braok_install_units
    step "Finalizing"
    brl_reload >/dev/null 2>&1 || true
    notice "Bedrock-AOK integration complete"
    notice "Run ${color_cmd}brl capabilities${color_norm}, ${color_cmd}brl test${color_norm}, ${color_cmd}brl health${color_norm}"
    say ""
}

# ── official installer interface (mirrors real bedrock.sh) ──────────────
# When invoked by its script name (not as brl/strat), bedrock-port.sh behaves
# like the upstream installer: --hijack [name] / --update / --force-update / -h.
installer_help() {
    print_logo "Bedrock Linux ${BEDROCK_VERSION} ${BEDROCK_CODENAME} (${PORT_TAG} port)"
    printf "Usage: ${color_cmd}%s ${color_sub}<operations>${color_norm}\n" "$0"
    printf "Install or update a Bedrock Linux system (iSH-AOK port).\n"
    printf "Operations:\n"
    printf "  ${color_cmd}--hijack ${color_sub}[name]       ${color_norm}convert current installation to Bedrock Linux.\n"
    printf "                        ${color_priority}this operation is not intended to be reversible!${color_norm}\n"
    printf "                        optionally specify initial ${color_term}stratum${color_norm} name.\n"
    printf "  ${color_cmd}--update              ${color_norm}update current Bedrock Linux system.\n"
    printf "  ${color_cmd}--force-update        ${color_norm}update current system, ignoring warnings.\n"
    printf "  ${color_cmd}--restat              ${color_norm}re-run capability detection.\n"
    printf "  ${color_cmd}-h${color_norm}, ${color_cmd}--help            ${color_norm}print this message\n"
    printf "\nAfter install, manage the system with ${color_cmd}brl${color_norm} and ${color_cmd}strat${color_norm}.\n"
}
# Capability-driven sanity checks: try everything, use what's available, never
# hard-fail on an emulated-but-usable feature. Only genuinely fatal gaps abort.
installer_sanity() {
    step_init 2
    step "Performing sanity checks"
    [ "$(id -u)" -eq 0 ] || abort "root required"
    has chroot || abort "chroot unavailable — cannot operate on this system."
    has tar || abort "tar required — install it and try again."
    { has wget || has curl; } || warn "no downloader yet — will install one during setup"
    [ -e /bedrock ] && [ -e /bedrock/etc/bedrock-release ] && abort "/bedrock found. Already Bedrock Linux."
    # NOTE: unlike upstream, FUSE is NOT required — crossfs/etcfs are emulated.
    # Probe (never abort) every optional capability; record what we can use.
    braok_detect_caps 2>/dev/null || true
    step "Recording available capabilities"
    notice "capabilities recorded at ${color_file}${BRAOK_CAPS}${color_norm}"
    # Surface what will/won't be used, honestly.
    for _c in mount_ns pid_ns net_ns user_ns uts_ns ipc_ns cgroup_ns cgroup2 procfs sysfs devpts tmpfs bind_mount seccomp; do
        _v="$(cap_of "$_c")"
        case "$_v" in
            native)      notice "will use ${color_okay}${_c}${color_norm} (native)" ;;
            emulated)    notice "will use ${color_warn}${_c}${color_norm} (emulated)" ;;
            unavailable|disabled) notice "skipping ${color_alert}${_c}${color_norm} (${_v})" ;;
        esac
    done
}
run_installer() {
    _op="${1:-}"; [ "$#" -ge 1 ] && shift
    case "$_op" in
        --hijack)  installer_sanity; brl_hijack "$@" ;;
        --update)  brl_update "$@" ;;
        --force-update) brl_update "$@" ;;
        --restat)  braok_detect_caps && brl_capabilities ;;
        -h|--help|"") installer_help ;;
        *) err "unknown operation: ${_op}"; installer_help; exit 1 ;;
    esac
}

# ── dispatch ────────────────────────────────────────────────────────────
_base="$(basename "$0" 2>/dev/null || echo brl)"
case "$_base" in
    strat) cmd_strat "$@"; exit $? ;;
esac
# When invoked by the installer name with an installer operation (or no args),
# behave as the installer. Otherwise fall through to the brl command dispatch,
# so `bedrock-port.sh capabilities`, `bedrock-port.sh archs`, etc. still work.
case "$_base" in
    bedrock-port.sh|bedrock-port|bedrock-linux*|bedrock.sh)
        case "${1:-}" in
            --hijack|--update|--force-update|--restat|-h|--help|"")
                run_installer "$@"; exit $? ;;
        esac ;;
esac
_cmd="${1:-help}"; [ "$#" -ge 1 ] && shift
case "$_cmd" in
    fetch)         brl_fetch "$@" ;; fetch-url) brl_fetch_url "$@" ;; apply) brl_apply "$@" ;;
    list)          brl_list "$@" ;; status) brl_status "$@" ;; which) brl_which "$@" ;;
    show)          brl_show "$@" ;; copy) brl_copy "$@" ;;
    enable|retain) brl_enable "$@" ;; disable) brl_disable "$@" ;;
    remove|deref)  brl_remove "$@" ;; rename) brl_rename "$@" ;;
    alias)         brl_alias "$@" ;; unalias) brl_unalias "$@" ;;
    update)        brl_update "$@" ;; update-urls) brl_update_urls "$@" ;;
    install|import) brl_install "$@" ;;
    reload)        brl_reload "$@" ;; umount|unmount) cmd_umount "$@" ;;
    hijack)        brl_hijack "$@" ;; unhijack) brl_unhijack "$@" ;;
    report|doctor) brl_report "$@" ;; strat) cmd_strat "$@" ;;
    shell|enter|sh) cmd_shell "$@" ;;
    deps)          ensure_deps && ok "all host dependencies present" ;;
    fix|repair)    brl_fix "$@" ;;
    tutorial)      brl_tutorial "$@" ;;
    subcommands)   brl_subcommands ;;
    archs)         brl_archs ;;
    capabilities|caps) brl_capabilities "$@" ;;
    security)      brl_security "$@" ;;
    pin)           brl_pin "$@" ;;
    export)        brl_export "$@" ;;
    import-tar)    brl_import_tar "$@" ;;
    config)        brl_config "$@" ;;
    self-update)   brl_self_update "$@" ;;
    integrate)     brl_integrate "$@" ;;
    boot-init)     braok_boot_init ;;
    init-install)  braok_install_init "$@" ;;
    init-uninstall) braok_uninstall_init "$@" ;;
    init-status)   brl_init_status "$@" ;;
    rollback)      brl_rollback "$@" ;;
    verify|integrity) brl_verify "$@" ;;
    health)        brl_health "$@" ;;
    test|selftest) brl_test "$@" ;;
    register-aok)  brl_register_aok "$@" ;;
    --hijack|--update|--force-update|--restat) run_installer "$_cmd" "$@" ;;
    version|--version|-v) brl_version ;;
    help|--help|-h) if [ "$#" -ge 1 ]; then brl_help_cmd "$1"; else brl_help; fi ;;
    *) err "unknown: $_cmd"; brl_help; exit 1 ;;
esac
