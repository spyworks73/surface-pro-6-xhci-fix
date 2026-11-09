#!/bin/sh
# =============================================================================
# Surface Pro 6 — xHCI initramfs hook (init-top stage)
# =============================================================================
#
# PURPOSE:
#   Restores the XHCLKGTEN PCI config register (offset 0x50) on the Intel
#   xHCI controller (8086:9d2f) to its correct value (0x0FDF6D3F) before
#   the xhci_pci kernel module loads.
#
#   The UEFI firmware corrupts this register at ExitBootServices(), causing
#   xhci_hcd: can't setup: -110 on every OS boot. This hook corrects the
#   register in the initramfs, early enough to fix USB before the driver
#   initializes.
#
# STAGE: init-top  (runs BEFORE load_modules — this is critical)
#   init-top    → runs first, before any modules load     ← this script
#   init-premount → runs after modules have already loaded (too late)
#
# USAGE:
#   This script is an initramfs hook, not a standalone script.
#   Install it as follows:
#
#     sudo cp initrd-xhci-hook-init-top.sh \
#         /usr/share/initramfs-tools/scripts/init-top/xhci-fix
#     sudo chmod +x /usr/share/initramfs-tools/scripts/init-top/xhci-fix
#     sudo update-initramfs -u -k all
#
# REQUIREMENTS:
#   - setpci must be available in the initramfs
#     (add to /etc/initramfs-tools/initramfs.conf: MODULES=most)
#   - CONFIG_USB_XHCI_HCD=m (module, not built-in)
#
# NOTE:
#   This is the INTERIM solution. The definitive fix is the xhci-pci.c
#   kernel patch (xhci-pci-sp6-xhclkgten.patch), which does not require
#   this hook and allows ACPI to run normally (no acpi=off needed).
#   This hook requires acpi=off in GRUB to function reliably.
#
# TESTED ON:
#   Surface Pro 6 (model 1796), kernel 6.6.40-surface, Ubuntu 24.04 Noble
#
# =============================================================================

PREREQ=""

prereqs() {
    echo "$PREREQ"
}

case "$1" in
    prereqs)
        prereqs
        exit 0
        ;;
esac

. /scripts/functions

# Mount sysfs so setpci can access PCI config space
mount -t sysfs sysfs /sys

# Restore XHCLKGTEN to the correct value for the Intel xHCI controller
# PCI device: 00:14.0 (Sunrise Point-LP PCH xHCI, 8086:9d2f)
# Register:   0x50 (XHCLKGTEN — xHCI Clock Gating Enable)
# Correct:    0x0FDF6D3F (value set by UEFI before ExitBootServices)
# Broken:     0x0FCE6E5B (value written by UEFI at ExitBootServices)
/usr/bin/setpci -s 00:14.0 50.L=0x0FDF6D3F

# Load xHCI modules in the correct order
modprobe xhci_pci
modprobe hid
modprobe hid-generic
modprobe usbhid
modprobe evdev
