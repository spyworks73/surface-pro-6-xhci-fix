#!/bin/bash
# =============================================================================
# Surface Pro 6 — Full patched kernel build with .deb packages (~1-2 hours)
# =============================================================================
#
# PURPOSE:
#   Full end-to-end kernel build: clone linux-surface, apply the SP6 patches,
#   configure, and produce installable .deb packages that can be transferred
#   to SP6 via USB drive.
#
#   Output: linux-image-*.deb and linux-headers-*.deb in ~/sp6-rebuild/
#   These are installed on SP6 with: dpkg -i linux-image-*.deb
#
# RUN ON:  SP9 (companion machine) / WSL2 Ubuntu 24.04
# NOT ON:  SP6 (target machine)
#
# REQUIREMENTS:
#   - WSL2 Ubuntu 24.04, internet access
#   - ~20 GB free disk space on WSL2 internal filesystem (NOT on external drive)
#   - Build dependencies installed by this script automatically
#
# CRITICAL — WSL2 DISK LOCATION:
#   Build on the WSL2 INTERNAL filesystem (~/), never on an external drive
#   (/mnt/e, /mnt/d, etc.). External drives can develop I/O errors during
#   long builds (observed: "Input/output error" on /usr/bin/sed during build).
#   Only the final .deb output is copied to the USB drive.
#
# USAGE:
#   bash sp9-full-kernel-build.sh [USB_DRIVE]
#   Example: bash sp9-full-kernel-build.sh /mnt/e
#   Default if no argument: /mnt/e
#
# WHAT THIS SCRIPT DOES:
#   1. Installs build dependencies
#   2. Clones linux-surface kernel 6.19.8 source
#   3. Applies the two SP6 patches (xhci-pci.c and xhci.c)
#   4. Configures the kernel (interactive menuconfig)
#   5. Builds .deb packages (make bindeb-pkg)
#   6. Copies .deb files to USB drive
#
# KERNEL CONFIG — KEY OPTIONS (set during menuconfig in step 4):
#   CONFIG_USB_XHCI_HCD=m          MUST be module (<M>), not built-in (<*>)
#   CONFIG_USB_XHCI_PCI=m          MUST be module
#   CONFIG_FB=y                     MUST be built-in (<*>), not module
#   CONFIG_FRAMEBUFFER_CONSOLE=y    Required for console at boot
#   CONFIG_SURFACE_AGGREGATOR=m     Type Cover and Surface hardware bus
#   CONFIG_SURFACE_AGGREGATOR_REGISTRY=m
#   CONFIG_INTEL_IPTS=m             IPTS touchscreen driver
#   CONFIG_HID_MULTITOUCH=m         Multi-touch support
#
# WARNING — CONFIG_FB MUST BE =y NOT =m:
#   Compiling the framebuffer as a module causes a black screen at boot
#   (framebuffer not available early enough). This costs a full rebuild
#   if missed. Always verify: grep "^CONFIG_FB=" .config → must show =y
#
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------

USB_DRIVE="${1:-/mnt/e}"
BUILD_DIR="$HOME/sp6-rebuild"
KERNEL_VERSION="6.19.8"
LOCALVERSION="-surface-3-xhci-m"
LINUX_SURFACE_REPO="https://github.com/linux-surface/linux-surface.git"

# --- Sanity checks -----------------------------------------------------------

echo "=== SP6 Full Kernel Builder ==="
echo ""

# Verify not building on external drive
if [[ "$BUILD_DIR" == /mnt/* ]]; then
    echo "ERROR: BUILD_DIR is on an external drive ($BUILD_DIR)"
    echo "       Build on the WSL2 internal filesystem only (e.g. ~/sp6-rebuild)"
    echo "       External drives can fail with I/O errors during long builds."
    exit 1
fi

if [ ! -d "$USB_DRIVE" ]; then
    echo "ERROR: USB drive not found at $USB_DRIVE"
    echo "       Mount it first or pass the correct path: bash $0 /mnt/d"
    exit 1
fi

# Verify we are on Ubuntu 24.04 Noble
DISTRO_CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")
if [ "$DISTRO_CODENAME" != "noble" ]; then
    echo "WARNING: Expected Ubuntu 24.04 Noble, got: $DISTRO_CODENAME"
    echo "         Proceeding, but package compatibility on SP6 is not guaranteed."
    sleep 3
fi

echo "Build directory: $BUILD_DIR (WSL2 internal filesystem)"
echo "USB drive:       $USB_DRIVE"
echo "Kernel version:  $KERNEL_VERSION$LOCALVERSION"
echo ""

# --- Step 1: Install build dependencies --------------------------------------

echo "--- Step 1: Installing build dependencies ---"
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    libncurses-dev \
    bison \
    flex \
    libssl-dev \
    libelf-dev \
    bc \
    git \
    fakeroot \
    dwarves \
    rsync \
    cpio \
    python3 \
    pahole

# --- Step 2: Clone linux-surface kernel source -------------------------------

echo ""
echo "--- Step 2: Cloning linux-surface kernel source ---"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ -d "linux-surface-src" ]; then
    echo "  linux-surface repo already exists — skipping clone"
    echo "  To re-clone from scratch: rm -rf $BUILD_DIR/linux-surface-src"
else
    git clone "$LINUX_SURFACE_REPO" linux-surface-src
fi

# Find and apply linux-surface patches for 6.19.x
PATCH_DIR="$BUILD_DIR/linux-surface-src/patches"

# Get vanilla kernel source
KERNEL_DIR="$BUILD_DIR/linux-${KERNEL_VERSION}-surface"

if [ -d "$KERNEL_DIR" ]; then
    echo "  Kernel source already exists at $KERNEL_DIR — skipping extraction"
else
    echo "  Downloading vanilla kernel ${KERNEL_VERSION}..."
    wget -c "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${KERNEL_VERSION}.tar.xz"

    echo "  Extracting..."
    tar -xf "linux-${KERNEL_VERSION}.tar.xz"
    mv "linux-${KERNEL_VERSION}" "$KERNEL_DIR"

    echo "  Applying linux-surface patches..."
    cd "$KERNEL_DIR"
    # Apply patches from the linux-surface repo for this kernel version
    # Patch directory naming may vary — adjust if needed
    for patch in "$PATCH_DIR/${KERNEL_VERSION%.*}/"*.patch; do
        if [ -f "$patch" ]; then
            echo "  Applying: $(basename $patch)"
            patch -p1 < "$patch"
        fi
    done
    cd "$BUILD_DIR"
fi

cd "$KERNEL_DIR"

# --- Step 3: Apply the two SP6 patches ---------------------------------------

echo ""
echo "--- Step 3: Applying SP6 patches ---"

# Check if patches are already applied
if grep -q "SP6 FIX: XHCLKGTEN" drivers/usb/host/xhci-pci.c 2>/dev/null; then
    echo "  xhci-pci.c patch already applied ✓"
else
    echo ""
    echo "  MANUAL STEP REQUIRED: Apply xhci-pci-sp6-xhclkgten.patch"
    echo ""
    echo "  Edit drivers/usb/host/xhci-pci.c"
    echo "  Find the line:  return usb_add_hcd(hcd, irq, IRQF_SHARED);"
    echo "  Insert BEFORE it:"
    echo ""
    echo "    if (dev->vendor == PCI_VENDOR_ID_INTEL && dev->device == 0x9d2f) {"
    echo "        pci_write_config_dword(dev, 0x50, 0x0FDF6D3F);"
    echo "        dev_info(&dev->dev, \"SP6 FIX: XHCLKGTEN hardware register corrected in probe\\n\");"
    echo "    }"
    echo ""
    echo "  Press ENTER when done (or Ctrl+C to abort and apply manually)..."
    read -r
    if ! grep -q "SP6 FIX: XHCLKGTEN" drivers/usb/host/xhci-pci.c; then
        echo "ERROR: Patch not found after manual edit. Apply the patch and re-run."
        exit 1
    fi
    echo "  xhci-pci.c patch verified ✓"
fi

if grep -q "SP6 FIX: HCRST" drivers/usb/host/xhci.c 2>/dev/null; then
    echo "  xhci.c HCRST patch already applied ✓"
else
    echo ""
    echo "  MANUAL STEP REQUIRED: Apply xhci-hcrst-skip.patch"
    echo "  See xhci-hcrst-skip.patch for instructions — the exact location"
    echo "  varies by kernel version. Apply and press ENTER when done..."
    read -r
fi

# --- Step 4: Configure kernel ------------------------------------------------

echo ""
echo "--- Step 4: Kernel configuration (interactive) ---"
echo ""
echo "  menuconfig will open. Set these options before saving:"
echo ""
echo "  MUST be <M> (module):"
echo "    Device Drivers → USB → xHCI HCD (USB 3.0) support → <M>"
echo "    Device Drivers → USB → xHCI PCI → <M>"
echo "    Surface Aggregator Module → <M>"
echo "    Surface Aggregator Registry → <M>"
echo "    Intel IPTS Touchscreen → <M>"
echo ""
echo "  MUST be <*> (built-in, NOT module):"
echo "    Device Drivers → Graphics → Frame buffer → <*>"
echo "    Device Drivers → Graphics → Frame buffer → Console display → <*>"
echo ""
echo "  Press ENTER to open menuconfig..."
read -r

# Start from a sane default if no .config exists
if [ ! -f ".config" ]; then
    make defconfig
fi

make menuconfig

# --- Verify critical config options after menuconfig -------------------------

echo ""
echo "--- Verifying critical config options ---"
ERRORS=0

check_config() {
    local option="$1"
    local expected="$2"
    local actual
    actual=$(grep "^${option}=" .config 2>/dev/null | cut -d= -f2 || echo "NOT SET")
    if [ "$actual" = "$expected" ]; then
        echo "  ✓ ${option}=${expected}"
    else
        echo "  ✗ ${option}=${actual} (expected ${expected})"
        ERRORS=$((ERRORS + 1))
    fi
}

check_config "CONFIG_USB_XHCI_HCD" "m"
check_config "CONFIG_USB_XHCI_PCI" "m"
check_config "CONFIG_FB" "y"

if [ $ERRORS -gt 0 ]; then
    echo ""
    echo "ERROR: $ERRORS critical config option(s) are wrong."
    echo "       Re-run make menuconfig and fix them before building."
    exit 1
fi

# --- Step 5: Build .deb packages ---------------------------------------------

echo ""
echo "--- Step 5: Building kernel .deb packages ---"
echo "    This takes 1-2 hours depending on CPU. Using $(nproc) threads."
echo "    DO NOT use the external USB drive for this — build on internal disk."
echo ""

make -j"$(nproc)" bindeb-pkg LOCALVERSION="$LOCALVERSION"

# --- Step 6: Copy .deb files to USB drive ------------------------------------

echo ""
echo "--- Step 6: Copying .deb packages to USB drive ---"

OUTPUT_DIR="${USB_DRIVE}/sp6-kernel"
mkdir -p "$OUTPUT_DIR"

# .deb files are created one level above the kernel source dir
cp "$BUILD_DIR"/linux-image-*.deb "$OUTPUT_DIR/" 2>/dev/null || true
cp "$BUILD_DIR"/linux-headers-*.deb "$OUTPUT_DIR/" 2>/dev/null || true

# --- Summary -----------------------------------------------------------------

KVER=$(make -s kernelrelease)

echo ""
echo "=== Done ==="
echo ""
echo "Kernel version: $KVER"
echo "Packages at:    $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR/"/*.deb 2>/dev/null || echo "  (no .deb files found — check build output)"
echo ""
echo "On SP6, install with:"
echo "  dpkg -i /media/usb/sp6-kernel/linux-image-${KVER}_*.deb"
echo "  dpkg -i /media/usb/sp6-kernel/linux-headers-${KVER}_*.deb"
echo "  # Edit /etc/default/grub — REMOVE acpi=off, keep:"
echo "  # GRUB_CMDLINE_LINUX_DEFAULT=\"intel_idle.max_cstate=1 usbcore.autosuspend=-1\""
echo "  update-grub"
echo "  systemctl mask systemd-udev-settle.service"
echo "  reboot"
