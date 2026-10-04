#!/usr/bin/env bash
# =============================================================================
#  gentoo-install.sh — Installer Gentoo Linux otomatis
# -----------------------------------------------------------------------------
#  Target : UEFI + NVMe (GPT), ext4, OpenRC, GRUB (x86_64-efi)
#  Fitur  : NetworkManager (backend iwd), CUPS, Bluetooth (bluez),
#           timezone Asia/Jakarta, pilihan kernel, user + sudo,
#           semua service otomatis aktif saat boot (rc-update).
#
#  CARA PAKAI
#    1. Boot Gentoo Minimal Installation CD dalam mode UEFI (Secure Boot OFF)
#       dan pastikan internet aktif (Wi-Fi: `iwctl` / `net-setup`).
#    2. Salin script ini ke live environment, lalu:
#         chmod +x gentoo-install.sh && ./gentoo-install.sh
#    3. Jawab pertanyaan (Enter = pakai default).
#
#  MODE OTOMATIS PENUH (tanpa pertanyaan):
#         ./gentoo-install.sh -c config.conf -n -y
#
#  Contoh config.conf (semua variabel opsional kecuali DISK, NEW_USER,
#  USER_PASSWORD, dan ROOT_PASSWORD bila LOCK_ROOT=no):
#         DISK=/dev/nvme0n1
#         SWAP_SIZE=8G                 # 0 = tanpa swap
#         MIRROR=https://distfiles.gentoo.org
#         HOST_NAME=gentoo
#         TIMEZONE=Asia/Jakarta
#         SYS_LOCALE=id_ID.UTF-8
#         KEYMAP=us
#         KERNEL_TYPE=bin              # bin | dist | genkernel | manual
#         USE_BINPKG=yes               # pakai binary package resmi Gentoo
#         UPDATE_WORLD=no
#         INSTALL_FIRMWARE=yes         # linux-firmware (+ intel-microcode)
#         INSTALL_SOF=yes              # sof-firmware (audio Intel modern)
#         GPU_DRIVER=amd               # amd | intel | nouveau | none
#         INSTALL_VULKAN=yes
#         INSTALL_CUPS=yes
#         CUPS_GUTENPRINT=yes CUPS_HPLIP=no CUPS_BRLASER=no
#         CUPS_PDF=yes CUPS_AVAHI=yes
#         INSTALL_BLUETOOTH=yes
#         INSTALL_ELOGIND=yes          # elogind + polkit
#         INSTALL_SSHD=no
#         INSTALL_CRON=yes ENABLE_FSTRIM=yes
#         INSTALL_LOGGER=yes INSTALL_CHRONY=yes
#         EXTRA_PKGS="app-portage/gentoolkit app-editors/vim"
#         NEW_USER=budi
#         USER_PASSWORD='rahasia'
#         SUDO_NOPASSWD=no
#         LOCK_ROOT=no
#         ROOT_PASSWORD='rahasia-root'
#         REBOOT_NOW=no
#
#  PERINGATAN: SELURUH ISI DISK TARGET AKAN DIHAPUS.
# =============================================================================

set -Eeuo pipefail

TARGET="/mnt/gentoo"
CHROOT_SCRIPT="/root/gentoo-install.sh"
CHROOT_ENV="/root/.gentoo-install.env"
STATE_DIR="/root/.gentoo-install-state"
SELF="$(readlink -f "${BASH_SOURCE[0]}")"

STAGE="host"
CONFIG_FILE=""
ASSUME_YES=0
NONINTERACTIVE=0

# =============================================================================
#  Util
# =============================================================================
info() { printf '\e[1;34m[INFO]\e[0m %s\n' "$*"; }
ok()   { printf '\e[1;32m[ OK ]\e[0m %s\n' "$*"; }
warn() { printf '\e[1;33m[WARN]\e[0m %s\n' "$*" >&2; }
die()  { printf '\e[1;31m[FAIL]\e[0m %s\n' "$*" >&2; exit 1; }

on_err() {
    printf '\e[1;31m[FAIL]\e[0m Perintah gagal (exit %s) di baris %s\n' "$1" "$2" >&2
}
trap 'on_err $? $LINENO' ERR

usage() {
    cat <<EOF
Penggunaan: $0 [opsi]

  -c, --config FILE      Muat konfigurasi dari file (format variabel bash)
  -n, --non-interactive  Jangan bertanya; pakai default untuk variabel yang belum diset
  -y, --yes              Lewati konfirmasi penghapusan disk
  -h, --help             Tampilkan bantuan ini

Lihat komentar di bagian atas script untuk daftar variabel konfigurasi.
EOF
}

is_yes() { [[ "${!1:-}" == "yes" ]]; }

norm_bool() {
    local v="${!1:-}"
    v="${v,,}"
    case "$v" in
        y|yes|ya|true|1)  printf -v "$1" '%s' yes ;;
        n|no|t|tidak|false|0) printf -v "$1" '%s' no ;;
        *) die "Nilai '$v' untuk $1 tidak valid (gunakan yes/no)" ;;
    esac
}

# choose VAR "Judul" default_index "nilai|label" ...
choose() {
    local var="$1" title="$2" def="$3"
    shift 3
    local -a vals=() labels=()
    local item i n ans
    for item in "$@"; do
        vals+=("${item%%|*}")
        labels+=("${item#*|}")
    done
    if [[ -n "${!var:-}" ]]; then return 0; fi
    if (( NONINTERACTIVE )); then
        printf -v "$var" '%s' "${vals[def-1]}"
        return 0
    fi
    printf '\n\e[1m%s\e[0m\n' "$title"
    for i in "${!labels[@]}"; do
        n=$((i + 1))
        if (( n == def )); then
            printf '  %d) %s  \e[2m[default]\e[0m\n' "$n" "${labels[i]}"
        else
            printf '  %d) %s\n' "$n" "${labels[i]}"
        fi
    done
    while true; do
        read -r -p "Pilihan [${def}]: " ans
        ans="${ans:-$def}"
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= ${#vals[@]} )); then
            printf -v "$var" '%s' "${vals[ans-1]}"
            return 0
        fi
        warn "Pilihan tidak valid."
    done
}

# ask VAR "Prompt" default [regex]   (ketik "-" untuk nilai kosong)
ask() {
    local var="$1" prompt="$2" def="$3" re="${4:-.*}" val
    if [[ -n "${!var+x}" ]]; then
        val="${!var}"
    elif (( NONINTERACTIVE )); then
        val="$def"
    else
        while true; do
            read -r -e -p "${prompt}${def:+ [$def]}: " val
            val="${val:-$def}"
            if [[ "$val" == "-" ]]; then val=""; fi
            if [[ "$val" =~ $re ]]; then break; fi
            warn "Input tidak valid, coba lagi."
        done
    fi
    [[ "$val" =~ $re ]] || die "Nilai untuk $var tidak valid atau wajib diisi: '${val}'"
    printf -v "$var" '%s' "$val"
}

# yesno VAR "Prompt" yes|no
yesno() {
    local var="$1" prompt="$2" def="$3" ans hint
    if [[ -n "${!var:-}" ]]; then norm_bool "$var"; return 0; fi
    if (( NONINTERACTIVE )); then printf -v "$var" '%s' "$def"; return 0; fi
    if [[ "$def" == yes ]]; then hint="Y/n"; else hint="y/N"; fi
    while true; do
        read -r -p "${prompt} [${hint}]: " ans
        ans="${ans,,}"
        if [[ -z "$ans" ]]; then ans="${def:0:1}"; fi
        case "$ans" in
            y|yes|ya)       printf -v "$var" '%s' yes; return 0 ;;
            n|no|t|tidak)   printf -v "$var" '%s' no;  return 0 ;;
        esac
        warn "Jawab y atau n."
    done
}

# ask_secret VAR "Prompt"
ask_secret() {
    local var="$1" prompt="$2" p1 p2
    if [[ -n "${!var:-}" ]]; then return 0; fi
    if (( NONINTERACTIVE )); then die "Variabel $var wajib diisi pada mode non-interaktif"; fi
    while true; do
        read -r -s -p "${prompt}: " p1; echo
        read -r -s -p "Ulangi password: " p2; echo
        if [[ -n "$p1" && "$p1" == "$p2" ]]; then
            printf -v "$var" '%s' "$p1"
            return 0
        fi
        warn "Password kosong atau tidak sama, coba lagi."
    done
}

fetch_stdout() {
    if command -v wget >/dev/null 2>&1; then wget -qO- "$1"; else curl -fsSL "$1"; fi
}

fetch_file() { # url dest
    if command -v wget >/dev/null 2>&1; then
        wget -q --show-progress -c -O "$2" "$1"
    else
        curl -fL --progress-bar -C - -o "$2" "$1"
    fi
}

# =============================================================================
#  TAHAP 1 — HOST (live environment)
# =============================================================================
preflight() {
    [[ $EUID -eq 0 ]] || die "Jalankan sebagai root."
    [[ "$(uname -m)" == "x86_64" ]] || die "Script ini hanya untuk x86_64 (amd64)."
    [[ -d /sys/firmware/efi ]] || die "Tidak boot dalam mode UEFI. Boot ulang ISO dengan UEFI."
    local c
    for c in sgdisk partprobe wipefs udevadm lsblk blkid mkfs.ext4 mkfs.vfat \
             mkswap swapon tar chroot openssl awk sed grep mountpoint; do
        command -v "$c" >/dev/null 2>&1 || die "Perintah '$c' tidak ditemukan di live environment."
    done
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        die "Butuh wget atau curl."
    fi
    if [[ ! -f "$SELF" ]]; then die "Script harus dijalankan dari file (bukan dari pipe)."; fi
}

select_disk() {
    if [[ -n "${DISK:-}" ]]; then
        [[ -b "$DISK" ]] || die "$DISK bukan block device."
        return 0
    fi
    if (( NONINTERACTIVE )); then die "Mode non-interaktif: variabel DISK wajib diset."; fi

    local -a opts=()
    local line name idx=0 def=1 found_nvme=0
    while IFS= read -r line; do
        idx=$((idx + 1))
        name="${line%% *}"
        opts+=("${name}|${line}")
        if (( ! found_nvme )) && [[ "$name" == /dev/nvme* ]]; then
            def=$idx
            found_nvme=1
        fi
    done < <(lsblk -dpno NAME,TYPE,SIZE,MODEL | awk '$2=="disk" {$2=""; print}' \
             | grep -v zram | sed 's/  */ /g')
    (( ${#opts[@]} > 0 )) || die "Tidak ada disk yang ditemukan."
    choose DISK "Pilih disk tujuan (SEMUA DATA AKAN DIHAPUS)" "$def" "${opts[@]}"
}

gather_config() {
    printf '\n\e[1m=== Konfigurasi instalasi (Enter = default) ===\e[0m\n'

    select_disk

    ask SWAP_SIZE "Ukuran swap (contoh 8G, 0 = tanpa swap)" "8G" '^(0|[0-9]+[MmGg])$'
    SWAP_SIZE="${SWAP_SIZE^^}"
    ask MIRROR "Mirror Gentoo" "https://distfiles.gentoo.org" '^https?://[^ ]+$'
    ask HOST_NAME "Hostname" "gentoo" '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'

    choose TIMEZONE "Zona waktu" 1 \
        "Asia/Jakarta|Asia/Jakarta (WIB)" \
        "Asia/Makassar|Asia/Makassar (WITA)" \
        "Asia/Jayapura|Asia/Jayapura (WIT)" \
        "custom|Lainnya (ketik manual)"
    if [[ "$TIMEZONE" == "custom" ]]; then
        unset TIMEZONE
        ask TIMEZONE "Ketik zona waktu (contoh Asia/Singapore)" "Asia/Jakarta" \
            '^[A-Za-z_]+(/[A-Za-z0-9_+-]+)+$'
    fi

    ask SYS_LOCALE "Locale sistem (en_US.UTF-8 & id_ID.UTF-8 selalu di-generate)" \
        "id_ID.UTF-8" '^[a-z]{2,3}_[A-Z]{2}\.UTF-8$'
    ask KEYMAP "Keymap konsol" "us" '^[A-Za-z0-9_.-]+$'

    choose KERNEL_TYPE "Pilih kernel" 1 \
        "bin|gentoo-kernel-bin — kernel binary siap pakai (tercepat, direkomendasikan)" \
        "dist|gentoo-kernel — kernel distribusi, dikompilasi lokal (+dracut)" \
        "genkernel|gentoo-sources + genkernel — kompilasi otomatis (config generik)" \
        "manual|gentoo-sources + menuconfig — konfigurasi kernel sendiri"
    [[ "$KERNEL_TYPE" =~ ^(bin|dist|genkernel|manual)$ ]] || die "KERNEL_TYPE tidak valid: $KERNEL_TYPE"

    printf '\n\e[1mFitur opsional\e[0m\n'
    yesno USE_BINPKG        "Pakai binary package resmi Gentoo (instalasi jauh lebih cepat)?" yes
    yesno UPDATE_WORLD      "Update @world setelah sync (lama bila tanpa binary package)?" no
    yesno INSTALL_FIRMWARE  "Install linux-firmware (+ intel-microcode bila CPU Intel)?" yes
    yesno INSTALL_SOF       "Install sof-firmware (audio laptop Intel modern)?" yes

    # --- GPU (auto-detect lewat lspci) ---
    local gpu_def=1 gpu_info=""
    if command -v lspci >/dev/null 2>&1; then
        gpu_info="$(lspci | grep -Ei 'vga|3d controller|display controller' || true)"
        if   grep -qiE 'amd|ati|radeon' <<<"$gpu_info";  then gpu_def=1
        elif grep -qi 'intel' <<<"$gpu_info";            then gpu_def=2
        elif grep -qi 'nvidia' <<<"$gpu_info";           then gpu_def=3
        fi
    fi
    choose GPU_DRIVER "Driver GPU (terdeteksi: ${gpu_info:-tidak diketahui})" "$gpu_def" \
        "amd|AMD / Radeon (amdgpu + radeonsi, Mesa + Vulkan RADV)" \
        "intel|Intel (Mesa)" \
        "nouveau|NVIDIA open-source (nouveau)" \
        "none|Tanpa driver GPU (server/headless)"
    [[ "$GPU_DRIVER" =~ ^(amd|intel|nouveau|none)$ ]] || die "GPU_DRIVER tidak valid: $GPU_DRIVER"
    if [[ "$GPU_DRIVER" == "none" ]]; then
        INSTALL_VULKAN=no
    else
        yesno INSTALL_VULKAN "  - Install dukungan Vulkan (vulkan-loader)?" yes
    fi
    if [[ "$GPU_DRIVER" == "amd" ]] && ! is_yes INSTALL_FIRMWARE; then
        warn "GPU AMD butuh firmware amdgpu — linux-firmware tetap diinstall."
        INSTALL_FIRMWARE=yes
    fi

    yesno INSTALL_CUPS "Install CUPS (layanan printer)?" yes
    if is_yes INSTALL_CUPS; then
        yesno CUPS_GUTENPRINT "  - Driver Gutenprint (Epson/Canon/dll)?" yes
        yesno CUPS_HPLIP      "  - Driver HPLIP (printer HP)?" no
        yesno CUPS_BRLASER    "  - Driver brlaser (laser Brother)?" no
        yesno CUPS_PDF        "  - Printer virtual PDF (cups-pdf)?" yes
        yesno CUPS_AVAHI      "  - Avahi/mDNS (deteksi printer jaringan)?" yes
    else
        CUPS_GUTENPRINT=no; CUPS_HPLIP=no; CUPS_BRLASER=no; CUPS_PDF=no; CUPS_AVAHI=no
    fi

    yesno INSTALL_BLUETOOTH "Install Bluetooth (bluez)?" yes
    yesno INSTALL_ELOGIND   "Install elogind + polkit (izin user untuk NetworkManager/CUPS/Bluetooth)?" yes
    yesno INSTALL_SSHD      "Aktifkan SSH server (sshd)?" no
    yesno INSTALL_CRON      "Install cronie (cron)?" yes
    yesno ENABLE_FSTRIM     "Aktifkan TRIM mingguan untuk NVMe (fstrim via cron)?" yes
    if is_yes ENABLE_FSTRIM && ! is_yes INSTALL_CRON; then
        info "TRIM mingguan memerlukan cron — cronie ikut diinstall."
        INSTALL_CRON=yes
    fi
    yesno INSTALL_LOGGER "Install system logger (sysklogd)?" yes
    yesno INSTALL_CHRONY "Install chrony (sinkronisasi waktu NTP)?" yes
    ask EXTRA_PKGS "Paket tambahan (pisahkan spasi, '-' = kosong)" \
        "app-portage/gentoolkit app-editors/vim sys-process/htop app-shells/bash-completion"

    printf '\n\e[1mAkun pengguna\e[0m\n'
    ask NEW_USER "Nama user baru (masuk grup wheel / sudo)" "" '^[a-z_][a-z0-9_-]{0,31}$'
    ask_secret USER_PASSWORD "Password untuk user '${NEW_USER}'"
    yesno SUDO_NOPASSWD "Sudo tanpa password (NOPASSWD)? kurang aman" no
    yesno LOCK_ROOT "Kunci akun root (hanya login via sudo; recovery lebih sulit)?" no
    if is_yes LOCK_ROOT; then
        ROOT_PASSWORD=""
    else
        ask_secret ROOT_PASSWORD "Password root"
    fi

    # --- nilai turunan ---
    local cores mem_gb jobs
    cores="$(nproc)"
    mem_gb="$(awk '/MemTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)"
    jobs=$(( mem_gb / 2 ))
    (( jobs < 1 )) && jobs=1
    (( jobs > cores )) && jobs="$cores"
    MAKEJOBS="$jobs"

    case "$(grep -m1 '^vendor_id' /proc/cpuinfo | awk '{print $3}')" in
        GenuineIntel) CPU_VENDOR=intel ;;
        AuthenticAMD) CPU_VENDOR=amd ;;
        *)            CPU_VENDOR=other ;;
    esac

    ESP_PART="$(part_path 1)"
    if [[ "$SWAP_SIZE" != "0" ]]; then
        SWAP_PART="$(part_path 2)"
        ROOT_PART="$(part_path 3)"
    else
        SWAP_PART=""
        ROOT_PART="$(part_path 2)"
    fi
}

part_path() {
    if [[ "$DISK" =~ [0-9]$ ]]; then printf '%sp%s' "$DISK" "$1"; else printf '%s%s' "$DISK" "$1"; fi
}

show_summary() {
    cat <<EOF

=================== RINGKASAN ===================
 Disk target     : ${DISK}   (SEMUA DATA DIHAPUS)
 Partisi         : EFI 1G (vfat) | swap ${SWAP_SIZE} | root ext4 (sisa disk)
 Hostname        : ${HOST_NAME}
 Zona waktu      : ${TIMEZONE}
 Locale          : ${SYS_LOCALE}   Keymap: ${KEYMAP}
 Kernel          : ${KERNEL_TYPE}
 Binary package  : ${USE_BINPKG}     Update @world: ${UPDATE_WORLD}
 Firmware        : ${INSTALL_FIRMWARE} (SOF: ${INSTALL_SOF}, CPU: ${CPU_VENDOR})
 GPU             : ${GPU_DRIVER} (Vulkan: ${INSTALL_VULKAN})
 Jaringan        : NetworkManager + iwd (otomatis)
 CUPS            : ${INSTALL_CUPS} (gutenprint=${CUPS_GUTENPRINT} hplip=${CUPS_HPLIP} brlaser=${CUPS_BRLASER} pdf=${CUPS_PDF} avahi=${CUPS_AVAHI})
 Bluetooth       : ${INSTALL_BLUETOOTH}
 elogind/polkit  : ${INSTALL_ELOGIND}
 sshd / cron     : ${INSTALL_SSHD} / ${INSTALL_CRON} (fstrim=${ENABLE_FSTRIM})
 logger / chrony : ${INSTALL_LOGGER} / ${INSTALL_CHRONY}
 Paket tambahan  : ${EXTRA_PKGS:-<tidak ada>}
 User            : ${NEW_USER} (wheel/sudo, NOPASSWD=${SUDO_NOPASSWD})
 Akun root       : $(if is_yes LOCK_ROOT; then echo "dikunci"; else echo "aktif (password diset)"; fi)
 MAKEOPTS        : -j${MAKEJOBS}
=================================================
EOF
}

confirm_wipe() {
    lsblk "$DISK" || true
    if (( ASSUME_YES )); then return 0; fi
    local ans
    warn "SEMUA data di ${DISK} akan DIHAPUS PERMANEN."
    read -r -p "Ketik 'YA' (huruf besar) untuk melanjutkan: " ans
    [[ "$ans" == "YA" ]] || die "Dibatalkan oleh pengguna."
}

check_disk_unused() {
    if [[ -n "$(lsblk -nro MOUNTPOINT "$DISK" | tr -d '[:space:]')" ]]; then
        die "Ada partisi di ${DISK} yang sedang ter-mount (mungkin disk media instalasi). Pilih disk lain."
    fi
    local p
    while read -r p; do
        swapoff "$p" 2>/dev/null || true
    done < <(lsblk -nrpo NAME "$DISK")
}

sync_clock() {
    if command -v chronyc >/dev/null 2>&1; then
        chronyc makestep >/dev/null 2>&1 || true
    fi
}

resolve_stage3() {
    local base="${MIRROR%/}/releases/amd64/autobuilds" latest rel
    info "Mencari stage3 OpenRC terbaru di ${MIRROR} ..."
    latest="$(fetch_stdout "${base}/latest-stage3-amd64-openrc.txt")" \
        || die "Gagal mengakses ${MIRROR}. Periksa koneksi internet / mirror."
    rel="$(grep -Eo '^[0-9]{8}T[0-9]{6}Z/stage3-amd64-openrc-[0-9]{8}T[0-9]{6}Z\.tar\.xz' <<<"$latest" | head -n1 || true)"
    [[ -n "$rel" ]] || die "Tidak menemukan stage3 amd64-openrc pada ${base}."
    STAGE3_URL="${base}/${rel}"
    ok "Stage3: ${rel}"
}

partition_disk() {
    info "Mempartisi ${DISK} (GPT) ..."
    wipefs -af "$DISK" >/dev/null
    sgdisk --zap-all "$DISK" >/dev/null
    sgdisk -n1:0:+1G -t1:ef00 -c1:EFI "$DISK" >/dev/null
    if [[ -n "$SWAP_PART" ]]; then
        sgdisk -n2:0:+"${SWAP_SIZE}" -t2:8200 -c2:swap "$DISK" >/dev/null
        sgdisk -n3:0:0 -t3:8300 -c3:gentoo-root "$DISK" >/dev/null
    else
        sgdisk -n2:0:0 -t2:8300 -c2:gentoo-root "$DISK" >/dev/null
    fi
    partprobe "$DISK"
    udevadm settle
    sleep 2
    [[ -b "$ESP_PART" && -b "$ROOT_PART" ]] || die "Partisi baru tidak muncul (${ESP_PART} / ${ROOT_PART})."
}

format_disks() {
    info "Memformat partisi ..."
    mkfs.vfat -F 32 -n EFI "$ESP_PART" >/dev/null
    mkfs.ext4 -F -L gentoo "$ROOT_PART" >/dev/null
    if [[ -n "$SWAP_PART" ]]; then
        mkswap -L swap "$SWAP_PART" >/dev/null
        swapon "$SWAP_PART"
    fi
}

mount_target() {
    mkdir -p "$TARGET"
    mount "$ROOT_PART" "$TARGET"
}

verify_stage3() {
    local file="$1" key="/usr/share/openpgp-keys/gentoo-release.asc" gh
    if ! command -v gpg >/dev/null 2>&1 || [[ ! -r "$key" ]]; then
        warn "gpg / kunci rilis Gentoo tidak tersedia — verifikasi tanda tangan dilewati."
        return 0
    fi
    if ! fetch_file "${STAGE3_URL}.asc" "${file}.asc"; then
        warn "Gagal mengunduh file .asc — verifikasi tanda tangan dilewati."
        return 0
    fi
    gh="$(mktemp -d)"
    GNUPGHOME="$gh" gpg --quiet --import "$key" >/dev/null 2>&1 || true
    if GNUPGHOME="$gh" gpg --quiet --verify "${file}.asc" "$file" >/dev/null 2>&1; then
        ok "Tanda tangan stage3 valid."
        rm -rf "$gh"
    else
        rm -rf "$gh"
        die "Verifikasi tanda tangan stage3 GAGAL. Unduhan mungkin rusak/dimanipulasi."
    fi
}

fetch_stage3() {
    local file
    file="${TARGET}/$(basename "$STAGE3_URL")"
    info "Mengunduh stage3 ..."
    fetch_file "$STAGE3_URL" "$file"
    verify_stage3 "$file"
    info "Mengekstrak stage3 ke ${TARGET} (beberapa menit) ..."
    tar xpf "$file" --xattrs-include='*.*' --numeric-owner -C "$TARGET"
    rm -f "$file" "${file}.asc"
}

write_fstab() {
    local esp_uuid root_uuid swap_uuid
    esp_uuid="$(blkid -s UUID -o value "$ESP_PART")"
    root_uuid="$(blkid -s UUID -o value "$ROOT_PART")"
    {
        echo "# <fs>                                  <mountpoint> <type> <opts>            <dump> <pass>"
        echo "UUID=${root_uuid}  /            ext4   defaults,noatime  0      1"
        echo "UUID=${esp_uuid}                                 /efi         vfat   umask=0077         0      2"
        if [[ -n "$SWAP_PART" ]]; then
            swap_uuid="$(blkid -s UUID -o value "$SWAP_PART")"
            echo "UUID=${swap_uuid}  none         swap   sw                 0      0"
        fi
    } > "${TARGET}/etc/fstab"
}

hash_passwords() {
    USER_HASH="$(openssl passwd -6 -stdin <<<"$USER_PASSWORD")"
    if is_yes LOCK_ROOT; then
        ROOT_HASH=""
    else
        ROOT_HASH="$(openssl passwd -6 -stdin <<<"$ROOT_PASSWORD")"
    fi
    unset USER_PASSWORD ROOT_PASSWORD
}

CHROOT_VARS=(
    MIRROR HOST_NAME TIMEZONE SYS_LOCALE KEYMAP KERNEL_TYPE USE_BINPKG UPDATE_WORLD
    INSTALL_FIRMWARE INSTALL_SOF CPU_VENDOR GPU_DRIVER INSTALL_VULKAN MAKEJOBS
    INSTALL_CUPS CUPS_GUTENPRINT CUPS_HPLIP CUPS_BRLASER CUPS_PDF CUPS_AVAHI
    INSTALL_BLUETOOTH INSTALL_ELOGIND INSTALL_SSHD INSTALL_CRON ENABLE_FSTRIM
    INSTALL_LOGGER INSTALL_CHRONY EXTRA_PKGS
    NEW_USER USER_HASH ROOT_HASH LOCK_ROOT SUDO_NOPASSWD NONINTERACTIVE
)

write_chroot_env() {
    local v f="${TARGET}${CHROOT_ENV}"
    : > "$f"
    chmod 600 "$f"
    for v in "${CHROOT_VARS[@]}"; do
        printf '%s=%q\n' "$v" "${!v:-}" >> "$f"
    done
}

prepare_chroot() {
    info "Menyiapkan chroot ..."
    mkdir -p "${TARGET}/efi"
    mount "$ESP_PART" "${TARGET}/efi"

    cp --dereference /etc/resolv.conf "${TARGET}/etc/resolv.conf"
    mount --types proc /proc "${TARGET}/proc"
    mount --rbind /sys "${TARGET}/sys"
    mount --make-rslave "${TARGET}/sys"
    mount --rbind /dev "${TARGET}/dev"
    mount --make-rslave "${TARGET}/dev"
    mount --bind /run "${TARGET}/run"
    mount --make-slave "${TARGET}/run"

    # Live media non-Gentoo: /dev/shm kadang berupa symlink
    if [[ -L /dev/shm ]]; then
        rm /dev/shm
        mkdir /dev/shm
        mount --types tmpfs --options nosuid,nodev,noexec shm /dev/shm
        chmod 1777 /dev/shm
        if [[ -d /run/shm ]]; then chmod 1777 /run/shm; fi
    fi

    install -m 700 "$SELF" "${TARGET}${CHROOT_SCRIPT}"
    write_chroot_env
}

run_chroot() {
    info "Masuk chroot dan melanjutkan instalasi ..."
    if ! chroot "$TARGET" /usr/bin/env -i HOME=/root TERM="${TERM:-linux}" \
            /bin/bash "$CHROOT_SCRIPT" --stage chroot; then
        warn "Instalasi di dalam chroot GAGAL."
        warn "Setelah memperbaiki masalah, lanjutkan (langkah selesai akan dilewati) dengan:"
        warn "  chroot ${TARGET} /usr/bin/env -i HOME=/root TERM=\$TERM /bin/bash ${CHROOT_SCRIPT} --stage chroot"
        exit 1
    fi
}

umount_all() {
    if [[ -n "${SWAP_PART:-}" ]]; then swapoff "$SWAP_PART" 2>/dev/null || true; fi
    umount -R "$TARGET" 2>/dev/null || umount -l -R "$TARGET" 2>/dev/null || true
}

finish() {
    rm -f  "${TARGET}${CHROOT_SCRIPT}" "${TARGET}${CHROOT_ENV}"
    rm -rf "${TARGET}${STATE_DIR}"
    sync
    umount_all
    cat <<EOF

$(printf '\e[1;32m')=============== INSTALASI SELESAI ===============$(printf '\e[0m')
 Login sebagai '${NEW_USER}' (gunakan 'sudo' untuk perintah admin).

 Setelah boot:
   Wi-Fi      : nmtui    atau   nmcli device wifi connect <SSID> --ask
   Bluetooth  : bluetoothctl   (power on, scan on, pair, connect)
   Printer    : buka http://localhost:631  (login user di grup lpadmin)
   Update     : sudo emerge --sync && sudo emerge -avuDN @world
=================================================
EOF
    if (( NONINTERACTIVE )); then : "${REBOOT_NOW:=no}"; fi
    yesno REBOOT_NOW "Reboot sekarang?" yes
    if is_yes REBOOT_NOW; then
        info "Reboot ... (cabut media instalasi)"
        reboot
    fi
}

host_main() {
    printf '\e[1;36m\n  Gentoo Linux Auto Installer — UEFI / NVMe / ext4 / OpenRC\n\e[0m'
    preflight
    if [[ -n "$CONFIG_FILE" ]]; then
        [[ -r "$CONFIG_FILE" ]] || die "File konfigurasi tidak dapat dibaca: $CONFIG_FILE"
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
    gather_config
    show_summary
    confirm_wipe
    check_disk_unused
    hash_passwords
    sync_clock
    resolve_stage3
    partition_disk
    format_disks
    mount_target
    fetch_stage3
    write_fstab
    prepare_chroot
    run_chroot
    finish
}

# =============================================================================
#  TAHAP 2 — CHROOT (dijalankan di dalam sistem Gentoo baru)
# =============================================================================
step() {
    local name="$1"
    if [[ -e "${STATE_DIR}/${name}" ]]; then
        info "[lewati] ${name} (sudah selesai)"
        return 0
    fi
    info "==> ${name}"
    "$name"
    touch "${STATE_DIR}/${name}"
}

emerge_pkgs() { emerge --verbose --update --newuse "$@"; }

enable_svc() { # service [runlevel]
    local svc="$1" rl="${2:-default}"
    if [[ ! -x "/etc/init.d/${svc}" ]]; then
        warn "Init script '${svc}' tidak ditemukan — dilewati."
        return 0
    fi
    if rc-update show "$rl" 2>/dev/null | awk '{print $1}' | grep -qx "$svc"; then
        return 0
    fi
    rc-update add "$svc" "$rl"
}

s_sync_tree() {
    if ! emerge-webrsync; then
        warn "emerge-webrsync gagal, mencoba emerge --sync ..."
        emerge --sync
    fi
}

s_portage_conf() {
    local mc=/etc/portage/make.conf pu=/etc/portage/package.use

    sed -i 's/^COMMON_FLAGS=.*/COMMON_FLAGS="-O2 -pipe -march=native"/' "$mc"
    {
        echo
        echo "# ---- ditambahkan oleh gentoo-install.sh ----"
        echo "MAKEOPTS=\"-j${MAKEJOBS}\""
        echo 'ACCEPT_LICENSE="-* @FREE @BINARY-REDISTRIBUTABLE"'
        echo "GENTOO_MIRRORS=\"${MIRROR}\""
        echo 'GRUB_PLATFORMS="efi-64"'
        case "$GPU_DRIVER" in
            amd)     echo 'VIDEO_CARDS="amdgpu radeonsi"' ;;
            intel)   echo 'VIDEO_CARDS="intel"' ;;
            nouveau) echo 'VIDEO_CARDS="nouveau"' ;;
        esac
        if is_yes USE_BINPKG; then
            echo 'FEATURES="${FEATURES} getbinpkg binpkg-request-signature"'
            echo 'EMERGE_DEFAULT_OPTS="${EMERGE_DEFAULT_OPTS} --getbinpkg"'
        fi
    } >> "$mc"

    if is_yes USE_BINPKG; then
        if ! compgen -G "/etc/portage/binrepos.conf/*.conf" >/dev/null; then
            mkdir -p /etc/portage/binrepos.conf
            cat > /etc/portage/binrepos.conf/gentoobinhost.conf <<EOF
[binhost]
priority = 9999
sync-uri = ${MIRROR%/}/releases/amd64/binpackages/23.0/x86-64/
EOF
        fi
        getuto || warn "getuto gagal — verifikasi tanda tangan binary package mungkin bermasalah."
    fi

    mkdir -p "$pu"

    if [[ "$KERNEL_TYPE" == "genkernel" ]]; then
        echo "sys-kernel/installkernel grub" > "$pu/installkernel"
    else
        echo "sys-kernel/installkernel grub dracut" > "$pu/installkernel"
    fi

    local nm_flags="iwd wifi nmtui -wpa_supplicant"
    if is_yes INSTALL_BLUETOOTH; then nm_flags+=" bluetooth"; fi
    if is_yes INSTALL_ELOGIND;   then nm_flags+=" elogind"; fi
    echo "net-misc/networkmanager ${nm_flags}" > "$pu/networkmanager"

    if is_yes INSTALL_ELOGIND; then
        echo "sys-auth/pambase elogind" > "$pu/pambase"
    fi
    if is_yes INSTALL_BLUETOOTH; then
        echo "net-wireless/bluez obex readline udev" > "$pu/bluez"
    fi
    if [[ "$GPU_DRIVER" != "none" ]]; then
        local mesa_flags="vaapi"
        if is_yes INSTALL_VULKAN; then mesa_flags+=" vulkan"; fi
        echo "media-libs/mesa ${mesa_flags}" > "$pu/mesa"
    fi
    if is_yes INSTALL_CUPS; then
        local cups_flags="usb"
        if is_yes CUPS_AVAHI; then cups_flags+=" zeroconf"; fi
        echo "net-print/cups ${cups_flags}" > "$pu/cups"
        if is_yes CUPS_GUTENPRINT; then echo "net-print/gutenprint cups" > "$pu/gutenprint"; fi
        if is_yes CUPS_HPLIP;      then echo "net-print/hplip -qt5 -scanner" > "$pu/hplip"; fi
    fi
    return 0
}

s_cpu_flags() { # hanya tanpa binary package (CPU_FLAGS_X86 memicu build ulang dari source)
    emerge --oneshot app-portage/cpuid2cpuflags
    echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags
}

s_update_world() {
    emerge --verbose --update --deep --newuse @world
}

s_firmware() {
    local pkgs=()
    if is_yes INSTALL_FIRMWARE; then
        pkgs+=(sys-kernel/linux-firmware)
        if [[ "$CPU_VENDOR" == "intel" ]]; then pkgs+=(sys-firmware/intel-microcode); fi
    fi
    if is_yes INSTALL_SOF; then pkgs+=(sys-firmware/sof-firmware); fi
    if (( ${#pkgs[@]} > 0 )); then emerge_pkgs "${pkgs[@]}"; fi
    return 0
}

s_kernel() {
    mkdir -p /boot/grub
    emerge_pkgs sys-boot/grub:2 sys-boot/efibootmgr sys-fs/dosfstools sys-kernel/installkernel

    case "$KERNEL_TYPE" in
        bin)
            emerge_pkgs sys-kernel/gentoo-kernel-bin
            ;;
        dist)
            emerge_pkgs sys-kernel/gentoo-kernel
            ;;
        genkernel)
            emerge_pkgs sys-kernel/gentoo-sources sys-kernel/genkernel
            eselect kernel set 1
            genkernel --makeopts="-j${MAKEJOBS}" --install all
            ;;
        manual)
            emerge_pkgs sys-kernel/gentoo-sources
            emerge_pkgs app-alternatives/bc virtual/libelf sys-devel/flex sys-devel/bison \
                || warn "Beberapa dependensi build kernel gagal di-emerge (mungkin sudah ada)."
            eselect kernel set 1
            cd /usr/src/linux
            if [[ -r /proc/config.gz ]]; then
                zcat /proc/config.gz > .config
                make olddefconfig
            else
                make defconfig
            fi
            if (( ! NONINTERACTIVE )); then
                info "Membuka menuconfig. Pastikan NVMe, ext4, EFI, dan driver perangkat Anda aktif."
                info "Catatan: iwd & NetworkManager butuh opsi crypto/AF_ALG (lihat peringatan emerge net-wireless/iwd)."
                make menuconfig
            fi
            make -j"${MAKEJOBS}"
            make modules_install
            make install
            cd /
            ;;
    esac

    if ! compgen -G "/boot/vmlinuz*" >/dev/null && ! compgen -G "/boot/kernel*" >/dev/null; then
        warn "Berkas kernel tidak ditemukan di /boot — periksa langkah kernel."
    fi
    return 0
}

s_pkg_network() {
    emerge_pkgs sys-apps/dbus net-wireless/iwd net-misc/networkmanager app-admin/sudo \
                sys-apps/nvme-cli sys-apps/pciutils sys-apps/usbutils
}

s_pkg_gpu() {
    # VIDEO_CARDS di make.conf -> Mesa dibangun dengan driver yang sesuai
    # (AMD: radeonsi untuk OpenGL, RADV untuk Vulkan). Build Mesa+LLVM bisa lama
    # bila binary package tidak cocok dengan USE flag.
    local pkgs=(media-libs/mesa)
    if is_yes INSTALL_VULKAN; then pkgs+=(media-libs/vulkan-loader); fi
    emerge_pkgs "${pkgs[@]}"
}

s_pkg_session() {
    emerge_pkgs sys-auth/pambase sys-auth/elogind sys-auth/polkit
}

s_pkg_cups() {
    local pkgs=(net-print/cups net-print/cups-filters)
    if is_yes CUPS_GUTENPRINT; then pkgs+=(net-print/gutenprint); fi
    if is_yes CUPS_HPLIP;      then pkgs+=(net-print/hplip); fi
    if is_yes CUPS_BRLASER;    then pkgs+=(net-print/brlaser); fi
    if is_yes CUPS_PDF;        then pkgs+=(net-print/cups-pdf); fi
    if is_yes CUPS_AVAHI;      then pkgs+=(net-dns/avahi); fi
    emerge_pkgs "${pkgs[@]}"
}

s_pkg_bluetooth() {
    emerge_pkgs net-wireless/bluez
}

s_pkg_misc() {
    local pkgs=()
    if is_yes INSTALL_CRON;   then pkgs+=(sys-process/cronie); fi
    if is_yes INSTALL_LOGGER; then pkgs+=(app-admin/sysklogd); fi
    if is_yes INSTALL_CHRONY; then pkgs+=(net-misc/chrony); fi
    if (( ${#pkgs[@]} > 0 )); then emerge_pkgs "${pkgs[@]}"; fi
    return 0
}

s_pkg_extra() {
    local -a pkgs=()
    read -r -a pkgs <<<"${EXTRA_PKGS:-}"
    if (( ${#pkgs[@]} > 0 )); then emerge_pkgs "${pkgs[@]}"; fi
    return 0
}

s_merge_configs() {
    etc-update --automode -5 >/dev/null 2>&1 || true
}

s_conf_system() {
    [[ -f "/usr/share/zoneinfo/${TIMEZONE}" ]] || die "Timezone '${TIMEZONE}' tidak ditemukan."
    echo "${TIMEZONE}" > /etc/timezone
    ln -sf "../usr/share/zoneinfo/${TIMEZONE}" /etc/localtime

    printf '%s UTF-8\n' en_US.UTF-8 id_ID.UTF-8 "${SYS_LOCALE}" | sort -u > /etc/locale.gen
    locale-gen
    cat > /etc/env.d/02locale <<EOF
LANG="${SYS_LOCALE}"
LC_COLLATE="C.UTF-8"
EOF
    env-update

    sed -i "s/^keymap=.*/keymap=\"${KEYMAP}\"/" /etc/conf.d/keymaps
    echo "hostname=\"${HOST_NAME}\"" > /etc/conf.d/hostname
    cat > /etc/hosts <<EOF
127.0.0.1   localhost ${HOST_NAME}
::1         localhost ${HOST_NAME}
EOF
}

s_conf_services() {
    # --- NetworkManager dengan backend iwd ---
    mkdir -p /etc/NetworkManager/conf.d /etc/iwd
    cat > /etc/NetworkManager/conf.d/10-wifi-backend-iwd.conf <<EOF
[device]
wifi.backend=iwd
EOF
    cat > /etc/iwd/main.conf <<EOF
[General]
EnableNetworkConfiguration=false
EOF
    touch /etc/conf.d/NetworkManager
    if ! grep -q '^rc_use=' /etc/conf.d/NetworkManager; then
        echo 'rc_use="iwd"' >> /etc/conf.d/NetworkManager
    fi

    # --- Bluetooth: adapter otomatis menyala ---
    if is_yes INSTALL_BLUETOOTH && [[ -f /etc/bluetooth/main.conf ]]; then
        if ! grep -q '^AutoEnable' /etc/bluetooth/main.conf; then
            printf '\n[Policy]\nAutoEnable=true\n' >> /etc/bluetooth/main.conf
        fi
    fi

    # --- TRIM mingguan ---
    if is_yes ENABLE_FSTRIM; then
        mkdir -p /etc/cron.weekly
        cat > /etc/cron.weekly/fstrim <<'EOF'
#!/bin/sh
fstrim --all
EOF
        chmod 755 /etc/cron.weekly/fstrim
    fi

    # --- sudo untuk grup wheel ---
    if ! grep -Eq '^[#@]includedir[[:space:]]+/etc/sudoers.d' /etc/sudoers; then
        echo '#includedir /etc/sudoers.d' >> /etc/sudoers
    fi
    mkdir -p /etc/sudoers.d
    if is_yes SUDO_NOPASSWD; then
        echo '%wheel ALL=(ALL:ALL) NOPASSWD: ALL' > /etc/sudoers.d/10-wheel
    else
        echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
    fi
    chmod 0440 /etc/sudoers.d/10-wheel
    visudo -cf /etc/sudoers.d/10-wheel
    visudo -c
}

s_enable_services() {
    # Pastikan tidak bentrok dengan manajemen jaringan lain
    local s
    for s in dhcpcd net.lo; do
        rc-update del "$s" default >/dev/null 2>&1 || true
    done

    if is_yes INSTALL_ELOGIND; then enable_svc elogind boot; fi
    enable_svc dbus default
    enable_svc iwd default
    enable_svc NetworkManager default

    if is_yes INSTALL_CUPS; then
        enable_svc cupsd default
        if is_yes CUPS_AVAHI; then enable_svc avahi-daemon default; fi
    fi
    if is_yes INSTALL_BLUETOOTH; then enable_svc bluetooth default; fi
    if is_yes INSTALL_SSHD;      then enable_svc sshd default; fi
    if is_yes INSTALL_CRON;      then enable_svc cronie default; fi
    if is_yes INSTALL_LOGGER;    then enable_svc sysklogd default; fi
    if is_yes INSTALL_CHRONY;    then enable_svc chronyd default; fi
    return 0
}

s_users() {
    local g groups=()
    for g in wheel users audio video usb input plugdev lp lpadmin bluetooth cdrom; do
        if getent group "$g" >/dev/null; then groups+=("$g"); fi
    done
    if ! id "$NEW_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G "$(IFS=,; echo "${groups[*]}")" "$NEW_USER"
    fi
    echo "${NEW_USER}:${USER_HASH}" | chpasswd -e

    if is_yes LOCK_ROOT; then
        passwd -l root
    else
        echo "root:${ROOT_HASH}" | chpasswd -e
    fi
}

s_bootloader() {
    if ! grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=Gentoo; then
        warn "grub-install biasa gagal — mencoba mode --removable"
        grub-install --target=x86_64-efi --efi-directory=/efi --removable
    elif ! efibootmgr 2>/dev/null | grep -qi gentoo; then
        warn "Entri NVRAM tidak terdeteksi — memasang juga jalur fallback (--removable)"
        grub-install --target=x86_64-efi --efi-directory=/efi --removable
    fi
    grub-mkconfig -o /boot/grub/grub.cfg
}

chroot_main() {
    set +u
    # shellcheck disable=SC1091
    source /etc/profile
    set -u
    [[ -r "$CHROOT_ENV" ]] || die "File lingkungan ${CHROOT_ENV} tidak ditemukan."
    # shellcheck disable=SC1090
    source "$CHROOT_ENV"
    mkdir -p "$STATE_DIR"
    mountpoint -q /efi || die "/efi belum ter-mount (ESP)."

    step s_sync_tree
    step s_portage_conf
    if ! is_yes USE_BINPKG;  then step s_cpu_flags; fi
    if is_yes UPDATE_WORLD;  then step s_update_world; fi
    step s_firmware
    step s_kernel
    step s_pkg_network
    if [[ "$GPU_DRIVER" != "none" ]]; then step s_pkg_gpu; fi
    if is_yes INSTALL_ELOGIND;   then step s_pkg_session; fi
    if is_yes INSTALL_CUPS;      then step s_pkg_cups; fi
    if is_yes INSTALL_BLUETOOTH; then step s_pkg_bluetooth; fi
    step s_pkg_misc
    step s_pkg_extra
    step s_merge_configs
    step s_conf_system
    step s_conf_services
    step s_enable_services
    step s_users
    step s_bootloader
    ok "Konfigurasi di dalam chroot selesai."
}

# =============================================================================
#  Entry point
# =============================================================================
while (( $# )); do
    case "$1" in
        --stage)               STAGE="${2:?}"; shift 2 ;;
        -c|--config)           CONFIG_FILE="${2:?}"; shift 2 ;;
        -n|--non-interactive)  NONINTERACTIVE=1; shift ;;
        -y|--yes)              ASSUME_YES=1; shift ;;
        -h|--help)             usage; exit 0 ;;
        *)                     die "Opsi tidak dikenal: $1 (gunakan --help)" ;;
    esac
done

case "$STAGE" in
    host)   host_main ;;
    chroot) chroot_main ;;
    *)      die "Stage tidak dikenal: $STAGE" ;;
esac
