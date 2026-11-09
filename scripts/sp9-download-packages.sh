#!/bin/bash
# =============================================================================
# Surface Pro 6 — Download Ubuntu packages on SP9/WSL2 for offline install
# =============================================================================
#
# PURPOSE:
#   Downloads all packages needed for the SP6 Ubuntu 24.04 install to a
#   local directory on a USB drive, then builds a local APT repository
#   that can be used on the SP6 (which has no internet access — no WiFi
#   card, no USB ethernet yet).
#
# RUN ON:  SP9 (companion machine) / WSL2 Ubuntu 24.04 (Noble)
# NOT ON:  SP6 (target machine — no internet at this stage)
#
# REQUIREMENTS:
#   - WSL2 running Ubuntu 24.04 Noble (packages MUST match target OS version)
#   - USB drive mounted and accessible (see USB_DRIVE variable below)
#   - Root or sudo access
#   - Internet access on SP9
#
# WARNING — VERSION DISCIPLINE:
#   Every package downloaded here must come from Ubuntu 24.04 Noble.
#   If your SP9/WSL2 runs a different Ubuntu version, packages will be
#   mismatched and cause dpkg errors on SP6 (symptom: initramfs-tools
#   version mismatch, dpkg --configure -a failures).
#   Verify: lsb_release -a  → should show "Noble Numbat / 24.04"
#
# WARNING — iptsd IS NOT IN UBUNTU REPOS:
#   iptsd (touchscreen daemon for Surface IPTS) comes from the linux-surface
#   project repository, not from Ubuntu. It is downloaded separately at the
#   end of this script. See the linux-surface section below.
#
# USAGE:
#   sudo bash sp9-download-packages.sh [USB_DRIVE_PATH]
#   Example: sudo bash sp9-download-packages.sh /mnt/e
#   Default if no argument: /mnt/e
#
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------

# Path where the USB drive is mounted in WSL2
# Windows drive letter E: → /mnt/e in WSL2
# Adjust if your USB drive has a different letter
USB_DRIVE="${1:-/mnt/e}"
REPO_DIR="${USB_DRIVE}/sp6-install"

# --- Sanity checks -----------------------------------------------------------

echo "=== SP6 Package Downloader ==="
echo ""

# Verify we are on Ubuntu 24.04 Noble
DISTRO_CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")
if [ "$DISTRO_CODENAME" != "noble" ]; then
    echo "ERROR: This script must run on Ubuntu 24.04 Noble."
    echo "       Current system: $DISTRO_CODENAME"
    echo "       Packages from other Ubuntu versions will cause errors on SP6."
    exit 1
fi

# Verify USB drive is mounted
if [ ! -d "$USB_DRIVE" ]; then
    echo "ERROR: USB drive not found at $USB_DRIVE"
    echo "       Mount it first: mount -t drvfs E: /mnt/e"
    echo "       Or pass the correct path: sudo bash $0 /mnt/d"
    exit 1
fi

# Verify running as root
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo bash $0)"
    exit 1
fi

echo "Target directory: $REPO_DIR"
echo "Ubuntu version:   $DISTRO_CODENAME (Noble 24.04) ✓"
echo ""

# --- Create repository directory ---------------------------------------------

mkdir -p "$REPO_DIR"

# --- Update package lists ----------------------------------------------------

echo "--- Updating package lists ---"
apt-get update

# --- Download standard Ubuntu packages ---------------------------------------
# These are downloaded WITHOUT installing them (--download-only)
# They land in /var/cache/apt/archives/ and are then copied to the USB drive.

echo ""
echo "--- Downloading Ubuntu packages (this may take 10-30 minutes) ---"

apt-get install --download-only -y \
    kde-plasma-desktop \
    plasma-pa \
    plasma-nm \
    pulseaudio \
    pulseaudio-module-bluetooth \
    network-manager \
    wpasupplicant \
    libinput10 \
    libinput-bin \
    iio-sensor-proxy \
    linux-firmware \
    bluetooth \
    bluez \
    bluez-tools \
    build-essential \
    git \
    dpkg-dev \
    setpci \
    pciutils \
    initramfs-tools \
    sudo \
    locales \
    bash-completion \
    curl \
    wget \
    vim \
    htop

# --- Download iptsd from linux-surface repository ----------------------------
# iptsd is the IPTS touchscreen daemon. It is NOT in Ubuntu repos.
# It comes from the linux-surface project APT repository.

echo ""
echo "--- Adding linux-surface repository for iptsd ---"

# Add the linux-surface GPG key
curl -s https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
    | gpg --dearmor \
    | tee /etc/apt/trusted.gpg.d/surface.gpg > /dev/null

# Add the linux-surface APT source for Ubuntu 24.04 Noble
echo "deb [arch=amd64] https://pkg.linux.surface.net/microsoft/noble/prod/deb stable main" \
    | tee /etc/apt/sources.list.d/linux-surface.list

# Update to include linux-surface packages
apt-get update

echo ""
echo "--- Downloading iptsd from linux-surface repo ---"
apt-get install --download-only -y iptsd

# --- Copy all downloaded .deb files to USB drive -----------------------------

echo ""
echo "--- Copying .deb files to $REPO_DIR ---"
cp /var/cache/apt/archives/*.deb "$REPO_DIR/"

# --- Build local APT repository on the USB drive ----------------------------
# This creates a Packages.gz index so SP6 can use the USB drive as an
# APT source with: deb [trusted=yes] file:///media/usb/sp6-install ./

echo ""
echo "--- Building local APT repository index ---"

# dpkg-dev provides dpkg-scanpackages
apt-get install -y dpkg-dev

cd "$REPO_DIR"
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

# --- Summary -----------------------------------------------------------------

echo ""
echo "=== Done ==="
echo ""
echo "Repository created at: $REPO_DIR"
echo "Package count:         $(ls "$REPO_DIR"/*.deb 2>/dev/null | wc -l) .deb files"
echo "Total size:            $(du -sh "$REPO_DIR" | cut -f1)"
echo ""
echo "On SP6, add this source to APT:"
echo "  echo \"deb [trusted=yes] file:///media/usb/sp6-install ./\" \\"
echo "      > /etc/apt/sources.list.d/local.list"
echo "  apt update"
echo "  apt install kde-plasma-desktop iptsd ..."
echo ""
echo "NOTE: iptsd requires the linux-surface kernel to function."
echo "      Install the patched kernel first, then iptsd."
