#!/bin/bash
# =============================================================================
# Surface Pro 6 — Build xHCI kernel modules only (fast path, ~5 minutes)
# =============================================================================
#
# PURPOSE:
#   Builds only the three xHCI kernel modules from a patched linux-surface
#   kernel source tree, without building the full kernel image. This is the
#   fast path when you only need to update the USB driver modules.
#
#   Output: xhci-hcd.ko, xhci-pci.ko, xhci-plat-hcd.ko
#   These are copied to the USB drive and installed on SP6 manually.
#
# RUN ON:  SP9 (companion machine) / WSL2 Ubuntu 24.04
# NOT ON:  SP6 (target machine — no internet, no compiler at this stage)
#
# REQUIREMENTS:
#   - linux-surface kernel source tree already cloned and patched
#     (see sp9-full-kernel-build.sh for the full setup)
#   - Build dependencies installed (build-essential, libssl-dev, etc.)
#   - Kernel .config already generated (make menuconfig or copied from SP6)
#   - Both patches applied:
#       * xhci-pci-sp6-xhclkgten.patch → drivers/usb/host/xhci-pci.c
#       * xhci-hcrst-skip.patch        → drivers/usb/host/xhci.c
#
# USAGE:
#   bash sp9-build-kernel-modules-only.sh [KERNEL_DIR] [USB_DRIVE]
#   Example: bash sp9-build-kernel-modules-only.sh \
#                ~/sp6-rebuild/linux-6.19.8-surface /mnt/e
#   Defaults: KERNEL_DIR=~/sp6-rebuild/linux-6.19.8-surface  USB_DRIVE=/mnt/e
#
# OUTPUT:
#   Three .ko files copied to $USB_DRIVE/sp6-modules/:
#     xhci-hcd.ko
#     xhci-pci.ko
#     xhci-plat-hcd.ko
#
# ON SP6 — install with:
#   KVER="6.19.8-surface-3-xhci-m"
#   MODULE_DIR="/lib/modules/$KVER/kernel/drivers/usb/host"
#   mkdir -p $MODULE_DIR
#   cp /media/usb/sp6-modules/xhci-*.ko $MODULE_DIR/
#   depmod -a $KVER
#   update-initramfs -u -k $KVER
#
# =============================================================================

set -euo pipefail

# --- Configuration -----------------------------------------------------------

KERNEL_DIR="${1:-$HOME/sp6-rebuild/linux-6.19.8-surface}"
USB_DRIVE="${2:-/mnt/e}"
OUTPUT_DIR="${USB_DRIVE}/sp6-modules"

# --- Sanity checks -----------------------------------------------------------

echo "=== SP6 xHCI Module Builder (fast path) ==="
echo ""

if [ ! -d "$KERNEL_DIR" ]; then
    echo "ERROR: Kernel source directory not found: $KERNEL_DIR"
    echo "       Pass the correct path as first argument."
    echo "       Usage: bash $0 /path/to/linux-source /mnt/e"
    exit 1
fi

if [ ! -f "$KERNEL_DIR/.config" ]; then
    echo "ERROR: No .config found in $KERNEL_DIR"
    echo "       Run 'make menuconfig' first to generate a kernel config."
    echo "       Ensure CONFIG_USB_XHCI_HCD=m and CONFIG_USB_XHCI_PCI=m"
    exit 1
fi

if [ ! -d "$USB_DRIVE" ]; then
    echo "ERROR: USB drive not found at $USB_DRIVE"
    echo "       Mount it first or pass the correct path as second argument."
    exit 1
fi

# Verify patches are applied
if ! grep -q "SP6 FIX" "$KERNEL_DIR/drivers/usb/host/xhci-pci.c" 2>/dev/null; then
    echo "ERROR: SP6 patch not found in xhci-pci.c"
    echo "       Apply xhci-pci-sp6-xhclkgten.patch before building."
    echo "       grep 'SP6 FIX' drivers/usb/host/xhci-pci.c should return a match."
    exit 1
fi

# Verify critical config options
if grep -q "CONFIG_USB_XHCI_HCD=y" "$KERNEL_DIR/.config"; then
    echo "ERROR: CONFIG_USB_XHCI_HCD=y found — must be =m (module, not built-in)"
    echo "       Run 'make menuconfig' and change Device Drivers → USB → xHCI to <M>"
    exit 1
fi

if ! grep -q "CONFIG_USB_XHCI_HCD=m" "$KERNEL_DIR/.config"; then
    echo "ERROR: CONFIG_USB_XHCI_HCD=m not found in .config"
    echo "       Run 'make menuconfig' and set it to <M>"
    exit 1
fi

echo "Kernel source: $KERNEL_DIR"
echo "Output:        $OUTPUT_DIR"
echo "Patches:       SP6 FIX found in xhci-pci.c ✓"
echo "Config:        CONFIG_USB_XHCI_HCD=m ✓"
echo ""

# --- Build xHCI modules only -------------------------------------------------

cd "$KERNEL_DIR"

echo "--- Preparing build environment ---"
# Generate module symbol versions (needed for standalone module build)
make prepare
make scripts

echo ""
echo "--- Building xHCI modules (3 files) ---"
make -j"$(nproc)" \
    drivers/usb/host/xhci-hcd.ko \
    drivers/usb/host/xhci-pci.ko \
    drivers/usb/host/xhci-plat-hcd.ko

# --- Verify output -----------------------------------------------------------

echo ""
echo "--- Verifying output ---"

for ko in xhci-hcd.ko xhci-pci.ko xhci-plat-hcd.ko; do
    if [ ! -f "drivers/usb/host/$ko" ]; then
        echo "ERROR: $ko was not built. Check build output above."
        exit 1
    fi
    echo "  ✓ drivers/usb/host/$ko ($(du -sh "drivers/usb/host/$ko" | cut -f1))"
done

# --- Copy to USB drive -------------------------------------------------------

echo ""
echo "--- Copying modules to USB drive ---"
mkdir -p "$OUTPUT_DIR"
cp drivers/usb/host/xhci-hcd.ko "$OUTPUT_DIR/"
cp drivers/usb/host/xhci-pci.ko "$OUTPUT_DIR/"
cp drivers/usb/host/xhci-plat-hcd.ko "$OUTPUT_DIR/"

# Save the kernel version string for reference on SP6
KVER=$(make -s kernelrelease)
echo "$KVER" > "$OUTPUT_DIR/kernel-version.txt"

echo ""
echo "=== Done ==="
echo ""
echo "Kernel version: $KVER"
echo "Modules at:     $OUTPUT_DIR/"
ls -lh "$OUTPUT_DIR/"
echo ""
echo "On SP6, install with:"
echo "  KVER=\"$KVER\""
echo "  MODULE_DIR=\"/lib/modules/\$KVER/kernel/drivers/usb/host\""
echo "  mkdir -p \$MODULE_DIR"
echo "  cp /media/usb/sp6-modules/xhci-*.ko \$MODULE_DIR/"
echo "  depmod -a \$KVER"
echo "  update-initramfs -u -k \$KVER"
