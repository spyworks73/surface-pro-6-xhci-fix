# Surface Pro 6 — Resurrecting a Dead USB Controller (xHCI Intel 8086:9D2F)

**A complete technical post-mortem: from hardware failure to a working Linux system, through 20+ failed attempts, a parallel rescue kernel, and a definitive kernel-level fix.**

> **TL;DR:** The Intel xHCI USB controller on a Surface Pro 6 progressively dies due to silicon degradation in the PCH. The UEFI firmware sets register `XHCLKGTEN` (PCI config offset `0x50`) to the wrong value at `ExitBootServices()`, causing `xhci_hcd: can't setup: -110` on every OS. The fix is a 4-line patch in `drivers/usb/host/xhci-pci.c` that corrects this register value directly in the driver probe function. With a dead USB port, Ubuntu 24.04 must be installed via `debootstrap` from a companion machine.

---

## Table of Contents

1. [Machine Specifications](#machine-specifications)
2. [The Failure Timeline](#the-failure-timeline)
3. [Root Cause Analysis](#root-cause-analysis)
4. [Diagnostic: UEFI Shell Register Investigation](#diagnostic-uefi-shell-register-investigation)
5. [What We Tried and Why It All Failed (Complete Log)](#what-we-tried-and-why-it-all-failed-complete-log)
   - [Phase 1: Standard kernel parameters and ACPI patches](#phase-1-standard-kernel-parameters-and-acpi-patches)
   - [Phase 2: Compiling xHCI as a module (CONFIG_USB_XHCI_HCD=m)](#phase-2-compiling-xhci-as-a-module)
   - [Phase 3: Kernel parameter tuning — multi-AI comparative analysis](#phase-3-kernel-parameter-tuning--multi-ai-comparative-analysis)
   - [Phase 4: Last-ditch attempts before the patch](#phase-4-last-ditch-attempts-before-the-patch)
6. [The Breakthrough: XHCLKGTEN Register Discovery](#the-breakthrough-xhclkgten-register-discovery)
7. [Interim Solution: acpi=off + initrd setpci Hook + HCRST skip](#interim-solution-acpioff--initrd-setpci-hook--hcrst-skip)
8. [The Definitive Fix: xhci-pci.c Kernel Patch](#the-definitive-fix-xhci-pcic-kernel-patch)
9. [Installing Ubuntu Without USB: The debootstrap Method](#installing-ubuntu-without-usb-the-debootstrap-method)
10. [Building the Patched Kernel on a Companion Machine](#building-the-patched-kernel-on-a-companion-machine)
11. [Installing the Patched Modules on SP6](#installing-the-patched-modules-on-sp6)
12. [Final System State](#final-system-state)
13. [Known Remaining Issues](#known-remaining-issues)
14. [Key Lessons Learned](#key-lessons-learned)
15. [AI Collaboration: Multi-Model Debugging](#ai-collaboration-multi-model-debugging)
16. [Repository Structure and Patch File](#repository-structure-and-patch-file)

---

## Machine Specifications

| Component | Details |
|-----------|---------|
| **Model** | Microsoft Surface Pro 6 (model 1796) |
| **CPU** | Intel Core i5-8250U (Kaby Lake Refresh) |
| **RAM** | 8 GB LPDDR3 |
| **Storage** | 128 GB NVMe SSD |
| **WiFi/BT/NFC** | Marvell 88W8897 AVASTAR (PCIe x1) — later desoldered |
| **USB Controller** | Intel xHCI (8086:9D2F) — Sunrise Point-LP PCH, PCI 00:14.0 |
| **UEFI Firmware** | Version 239.779.768 (EOL since September 2023) |
| **Secure Boot** | Locked to "Microsoft Only" (reverts to this value no matter what) |
| **Companion build machine** | Microsoft Surface Pro 9 (SP9), Windows 11 + WSL2 Ubuntu |

**Bluetooth accessories confirmed working after fix:**
- Dongle: TP-Link UB500 (USB)
- Mouse: Microsoft Arc Mouse (Bluetooth)

---

## The Failure Timeline

This was not a sudden failure. The degradation was **progressive over several weeks**, and understanding the sequence is critical to understanding the root cause.

### Stage 1 — USB becomes intermittent, then permanently dead

The first symptom was USB devices disconnecting randomly — mice, keyboards, USB drives would disconnect and reconnect unpredictably. Over several weeks, the USB controller became completely non-functional.

- **Windows**: Device Manager showed xHCI controller with **Code 10** ("This device cannot start")
- **Linux** (any kernel): `dmesg` showed `xhci_hcd 0000:00:14.0: can't setup: -110`
- **UEFI Shell**: USB works perfectly (keyboard, USB drives, polling mode)

### Stage 2 — Bluetooth stops working

Shortly after USB failed, Bluetooth also died. The Marvell 88W8897 chip handles WiFi, Bluetooth, and NFC together on a PCIe x1 connection; it was now also showing signs of failure.

### Stage 3 — WiFi stops working

Finally, WiFi dropped out completely. The Marvell chip appeared to be generating PCIe errors that cascaded across the bus.

### Stage 4 — Marvell chip desoldered by technician (ExpressRepair Moscow) — USB STILL dead

Based on early AI recommendations, a professional repair technician desoldered the **Marvell 88W8897 chip** from the motherboard PCB. This eliminated the PCIe noise from the failing Marvell device.

**Result**: WiFi and Bluetooth were gone (chip physically absent), but **USB remained completely dead.**

This was the key revelation: **the USB failure was entirely independent of the Marvell failure.** The xHCI silicon itself had been degrading independently. The Marvell failure was a parallel hardware failure, not the root cause of the USB problem.

### Why desoldering the Marvell didn't help

Two reasons:
1. The xHCI degradation had already occurred independently in the PCH silicon
2. The SP6's ACPI tables (DSDT) define shared power resources between the Marvell PCIe device and the xHCI controller. Removing the Marvell likely left some GPIO/power lines in an undefined state.

---

## Root Cause Analysis

After exhaustive investigation — UEFI Shell MMIO register reads, kernel debugging across 8+ kernel builds, and consultation with 7 AI models — the root cause was identified as **two compounding problems**:

### Problem 1: XHCLKGTEN Register Corruption at ExitBootServices()

The Intel PCH Sunrise Point-LP has a clock gating register at PCI configuration offset `0x50` for the xHCI controller: **XHCLKGTEN** (xHCI Clock Gating Enable).

**What the UEFI firmware does:**
- During UEFI operation (before booting an OS): correctly sets `XHCLKGTEN = 0x0FDF6D3F` → USB works
- At `ExitBootServices()` — the moment the firmware hands control to the OS — the firmware **resets this register to `0x0FCE6E5B`** → USB fails

This was observable in real time: when `ExitBootServices()` is called, the keyboard backlight LED goes dark and the UEFI virtual keyboard disappears. At exactly that moment, USB dies.

| State | XHCLKGTEN (PCI offset 0x50) | Result |
|-------|----------------------------|--------|
| UEFI pre-ExitBootServices | `0x0FDF6D3F` | USB works ✅ |
| Post-ExitBootServices (all OS) | `0x0FCE6E5B` | USB fails -110 ❌ |

**Bit difference**: `0x0FDF6D3F XOR 0x0FCE6E5B = 0x00110164`. Specific clock gating bits that the hardware requires are disabled by the firmware at the OS handoff point.

**OS affected**: Windows, Ubuntu (kernels 6.8 through 6.19), Puppy Linux — every OS, without exception.

### Problem 2: HCRST Bit Stuck in Silicon

UEFI Shell MMIO reads of the xHCI capability registers revealed a second hardware-level problem:

```
BAR0 MMIO base:          0xA1500000
CAPLENGTH:               0x80
USBCMD   (0xA1500080):   0x00000003   ← Run=1 AND HCRST=1 simultaneously!
USBSTS   (0xA1500084):   0x00000018   ← EINT=1, PCD=1
PORTSC   (0xA15004B0):   0x000002A0   ← Power=1, RxDetect
```

The `HCRST` (Host Controller Reset) bit is set simultaneously with `Run=1`. According to the xHCI specification, this is an illegal state: a reset cannot be in progress while the controller is running. This indicates **physical silicon degradation** in the PCH — the HCRST bit is stuck at 1 and cannot clear.

The standard kernel xHCI initialization sequence waits for HCRST to clear (timeout: several hundred milliseconds). It never clears. Result: `-110` = `-ETIMEDOUT`.

---

## Diagnostic: UEFI Shell Register Investigation

The UEFI Shell (`startup.nsh` or accessed via Volume-Up + Power → Shell) provides low-level hardware access before `ExitBootServices()`. These commands were used to prove the register corruption theory:

```bash
# Read PCI configuration register 0x50 (XHCLKGTEN) for device 00:14.0
pci 0 14 0

# Read MMIO registers after locating BAR0 at 0xA1500000
mm 0xA1500080 4   # USBCMD
mm 0xA1500084 4   # USBSTS
mm 0xA15004B0 4   # PORTSC for port 1

# Try to clear HCRST (write 0x0 to USBCMD bit 1)
mm 0xA1500080 4=0x00000000
# Then read back:
mm 0xA1500080 4   # Still shows 0x00000003 — hardware stuck
```

**Key observation**: The UEFI `connect -r` command re-enumerates xHCI successfully in the UEFI environment (USB works). But after `ExitBootServices()`, the register corruption occurs and no OS can recover it.

---

## What We Tried and Why It All Failed (Complete Log)

### Phase 1: Standard kernel parameters and ACPI patches

Over approximately 2 weeks, every standard approach was attempted:

#### Kernel boot parameters (all failed)

```
pci=nomsi                      # No effect
pcie_port_pm=off               # No effect  
intel_iommu=off                # No effect
pci=nocrs                      # No effect
pci=assign-busses,realloc      # No effect
acpi_osi="Windows 2015"        # No effect
intel_idle.max_cstate=0        # No effect
usbcore.quirks=8086:9d2f:b     # No effect (also invalid: driver was built-in)
noapic                         # No effect
irqpoll                        # No effect
pci=routeirq                   # No effect
```

**Exception**: `acpi=off` made USB work — but killed Type Cover and touchscreen (see Interim Solution below).

#### UEFI Shell attempts (all failed)

```bash
mm 0xA1500080 4=0x00000000   # Clear HCRST: accepted but reverts immediately
connect -r                    # Re-enumerates in UEFI but -110 persists after ExitBootServices
```

#### PCI-level resets from Linux (failed)

```bash
setpci -s 00:14.0 04.W=0x0000   # Disable PCI bus mastering
setpci -s 00:14.0 04.W=0x0007   # Re-enable — still -110
```

#### Force D0 power state + sysfs bind (failed)

```bash
setpci -s 00:14.0 PM_CTRL.W=0x0000
echo "0000:00:14.0" > /sys/bus/pci/drivers/xhci_hcd/bind
# Error: Operation timed out
```

#### ACPI/DSDT patches (partial / insufficient)

- **DSDT IRQ patch** (LNKA → GSI 16): Fixed error -22, but -110 remained
- **DSDT `_PS0`/`_PS3` patch** (force PDBM Memory Space + Bus Master active): -110 remained
- **DSDT `_PR0`/`_PR3` empty** (remove XHC power resources): -110 remained
- **SSDT RTD3_CA patch**: -110 remained

#### Kernel module reload attempts (failed — wrong config)

```bash
modprobe -r xhci_hcd   # Error: Module xhci_hcd is built into the kernel
```

This is why `CONFIG_USB_XHCI_HCD=y` (built-in) is a dead end. You cannot manipulate the hardware state before a built-in driver initializes. The driver must be compiled as a module.

---

### Phase 2: Compiling xHCI as a Module

**Action**: Recompile linux-surface kernel 6.19.8 with `CONFIG_USB_XHCI_HCD=m` and `CONFIG_USB_XHCI_PCI=m`.

**Result**: The kernel boots, but:
- xHCI enumerates devices **without IRQ** initially
- `systemd-udev-settle.service` times out after **3 minutes** waiting for USB enumeration
- After the timeout, the system continues booting — USB eventually works
- Type Cover works **after 20-30 minutes** (kernel USB retry mechanism)
- External USB keyboard produces `-71` (EPROTO) errors intermittently

This was progress — USB eventually worked — but the 3-minute boot delay and flaky behavior were unacceptable.

**Fix for the 3-minute delay:**
```bash
systemctl mask systemd-udev-settle.service
```

---

### Phase 3: Kernel Parameter Tuning — Multi-AI Comparative Analysis

At this stage, all 7 AI models (Claude, Kimi, ChatGPT, Gemini, DeepSeek, Qwen, GLM) were consulted simultaneously. Each provided analysis reports, which were then cross-compared by Kimi's comparative analysis framework.

**Parameters tested in Phase 3:**

| Parameter | Suggested by | Result |
|-----------|-------------|--------|
| `noapic` | Claude | ❌ No effect |
| `irqpoll` | Claude | ❌ No effect |
| `pci=routeirq` | Claude | ❌ No effect |
| Blacklist IPTS | Claude | ❌ Invalid (IPTS built-in) |
| `usbcore.use_both_schemes=y` | Gemini, DeepSeek, GLM | 🟡 Partial: USB keyboard after 20 min |
| `usbcore.old_scheme_first=1` | Gemini, DeepSeek | 🟡 Partial: improved enumeration |
| `xhci_hcd.quirks=0x100` | DeepSeek, GLM | ⛔ **DANGEROUS**: This is an AMD-specific quirk |

> ⚠️ **Warning on `xhci_hcd.quirks=0x100`**: This quirk (`XHCI_AMD_PLL_FIX`) was suggested by multiple AIs but is an AMD platform quirk. Using it on Intel hardware causes unpredictable behavior. Never apply AMD-specific quirks to an Intel xHCI controller.

**Key discovery from Phase 3**: With `usbcore.use_both_schemes=y`, the system booted and USB eventually worked — but only after 20-30 minutes. This proved that the xHCI hardware could enumerate devices, but needed the USB specification's "both schemes" fallback to work around the broken HCRST state.

---

### Phase 4: Last-Ditch Attempts Before the Patch

Just before committing to the kernel patch, three more approaches were tried live on the running SP6:

#### Attempt: Piste 1 — Unbind/bind Type Cover via sysfs
```bash
# Script: piste1-unbind-bind-typecover-v16.sh
# Unbind and rebind the Surface Type Cover input device
bash /mnt/usb/piste1-unbind-bind-typecover-v16.sh
```
**Result**: ❌ No response. Physical detach and reconnect also had no effect.

#### Attempt: Piste 2 — Physical detachment of Type Cover
Physically disconnected and reconnected the Type Cover magnetic connector.  
**Result**: ❌ Still non-functional.

#### Attempt: Piste 3 — Full xHCI unbind/bind via sysfs
```bash
# Script: piste3-unbind-bind-xhci-complet-v17.sh
# WARNING: This disconnects ALL USB devices temporarily
echo "0000:00:14.0" > /sys/bus/pci/drivers/xhci_hcd/unbind
sleep 5
echo "0000:00:14.0" > /sys/bus/pci/drivers/xhci_hcd/bind
```
**Result**: ❌ Catastrophic — disconnected all USB including external keyboard. System became extremely slow (possibly waiting for USB enumeration). Required full reboot to kernel 6.6.40 (rescue kernel). The 6.19.8 kernel was left in a broken state.

**Decision point**: After Piste 3 failed, the system was rebooted to the **6.6.40 rescue kernel** (which had `acpi=off` + initrd hook and was reliably stable). The decision was made to implement the definitive xhci-pci.c patch on the SP9 (companion machine).

---

## The Breakthrough: XHCLKGTEN Register Discovery

The key insight emerged from systematic UEFI Shell investigation: by reading PCI configuration register `0x50` on device `00:14.0` before and after `ExitBootServices()`, the firmware corruption was directly observed and measured.

The fix was conceptually simple: **write `0x0FDF6D3F` back to offset `0x50` after the firmware corrupts it, before the xHCI driver initializes.**

The initrd setpci hook (interim solution) proved this worked. The question became: **how to do this cleanly, without `acpi=off`?**

The answer: patch the driver itself.

---

## Interim Solution: acpi=off + initrd setpci Hook + HCRST Skip

This solution confirmed the approach and provided a usable (if incomplete) system while the final patch was being developed.

**Timeline**: Around June 10-12, 2026 (Phase 1 of the SP6 Linux project).  
**Kernel used**: linux-surface 6.6.40-surface-sp6 (kept as rescue kernel throughout)

### The Two Patches Applied

#### Patch 1: HCRST skip in `drivers/usb/host/xhci.c`

Applied to skip the stuck HCRST wait and force initialization to continue:

```c
/* SP6 FIX: HCRST bit is permanently stuck due to PCH silicon degradation.
 * Skip the HCRST wait and force initialization to continue. */
// Around line 5484 in xhci.c, in the reset/init function:
if (xhci_readl(xhci, &xhci->op_regs->command) & CMD_RESET) {
    xhci_warn(xhci, "HCRST stuck at 1 — PCH silicon degraded. Forcing init.\n");
    // Clear the bit forcefully and continue
    xhci_writel(xhci, 0, &xhci->op_regs->command);
    // Skip the standard wait loop
}
```

#### Patch 2: initramfs hook to restore XHCLKGTEN (init-top stage)

```bash
# File: /usr/share/initramfs-tools/scripts/init-top/xhci-fix
#!/bin/sh

PREREQ=""
prereqs() { echo "$PREREQ"; }
case $1 in
    prereqs) prereqs; exit 0;;
esac

. /scripts/functions

# Restore XHCLKGTEN to the correct value before xhci_pci module loads
mount -t sysfs sysfs /sys
/usr/bin/setpci -s 00:14.0 50.L=0x0FDF6D3F

# Load xHCI modules in correct order
modprobe xhci_pci
modprobe hid
modprobe hid-generic
modprobe usbhid
modprobe evdev
```

```bash
chmod +x /usr/share/initramfs-tools/scripts/init-top/xhci-fix
update-initramfs -u -k all
```

> **Why `init-top` and not `init-premount`?**  
> The `init-top` stage executes before `load_modules` (line 269 in Ubuntu 24.04's initramfs `/init` script). The `init-premount` stage runs after modules have already started loading. Using the wrong stage means setpci runs after the driver that already failed. This was an error in early attempts.

### GRUB parameters (interim)

```
GRUB_CMDLINE_LINUX_DEFAULT="acpi=off intel_idle.max_cstate=1 usbcore.autosuspend=-1"
```

### Result of interim solution

- ✅ USB works
- ✅ External USB keyboard/mouse functional  
- ❌ Type Cover dead (depends on Surface Aggregator Module, controlled via ACPI)
- ❌ IPTS touchscreen dead (depends on ACPI power management)
- ❌ Higher power consumption (C-states management disabled)

Usable for limited purposes, but not a daily driver. This kernel (6.6.40) was kept as a **rescue kernel** in the GRUB menu throughout the Phase 3 and 4 experiments.

---

## The Definitive Fix: xhci-pci.c Kernel Patch

**This is the solution that actually works for daily use with all hardware functional.**

**Timeline**: June 25-26, 2026, in collaboration with Kimi/Moonshot AI.  
**Kernel**: linux-surface 6.19.8-surface-3-xhci-m

### The Core Insight

Instead of a fragile initramfs hook requiring `acpi=off`, write the correct XHCLKGTEN value directly inside the xHCI PCI driver's probe function (`xhci_pci_common_probe()`), right before `usb_add_hcd()`. This runs with full ACPI support active, corrects the register at exactly the right moment, and allows every piece of hardware to work normally.

### The Patch

**File**: `drivers/usb/host/xhci-pci.c`  
**Function**: `xhci_pci_common_probe()`  
**Location**: Just before `return usb_add_hcd(hcd, irq, IRQF_SHARED);` (approximately line 654)

```c
static int xhci_pci_common_probe(struct pci_dev *dev, const struct pci_device_id *id)
{
    /* ... existing probe code ... */

    /*
     * Surface Pro 6 (Intel 8086:9d2f / Sunrise Point-LP PCH) workaround:
     *
     * The UEFI firmware corrupts PCI config register 0x50 (XHCLKGTEN,
     * xHCI Clock Gating Enable) at ExitBootServices(), changing it from
     * 0x0FDF6D3F (working) to 0x0FCE6E5B (broken). This causes
     * xhci_hcd: can't setup: -110 on every OS boot.
     *
     * We restore the correct value here in the driver probe function,
     * right before usb_add_hcd() is called, with ACPI fully active.
     * This eliminates the need for acpi=off and allows the Type Cover
     * and IPTS touchscreen to work normally.
     */
    if (dev->vendor == PCI_VENDOR_ID_INTEL && dev->device == 0x9d2f) {
        pci_write_config_dword(dev, 0x50, 0x0FDF6D3F);
        dev_info(&dev->dev, "SP6 FIX: XHCLKGTEN hardware register corrected in probe\n");
    }

    return usb_add_hcd(hcd, irq, IRQF_SHARED);
}
```

> ⚠️ **Critical**: The function parameter is `dev` (type `struct pci_dev *`), **not** `pdev`. The first attempt used `pdev->vendor`, `pdev->device`, `pci_write_config_dword(pdev, ...)` and failed with `error: 'pdev' undeclared`. **Always check the actual function signature in the kernel source before writing the patch.**

### Additional patch: HCRST skip in xhci.c

This patch from the interim solution was **also kept** in the final kernel build, applied at lines 5484 and 5492 of `drivers/usb/host/xhci.c`. The XHCLKGTEN fix resolves the clock gating issue, but the HCRST bit is still stuck in hardware. The HCRST skip patch prevents the driver from hanging on the reset wait.

### Mandatory kernel config

```
CONFIG_USB_XHCI_HCD=m    # MUST be module, not built-in
CONFIG_USB_XHCI_PCI=m    # MUST be module
```

With `=y` (built-in), the driver initializes before userspace has any control, and the probe function runs before any register correction is possible. With `=m`, the driver probe runs at a later stage where our in-driver correction is effective.

### GRUB parameters (final)

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="intel_idle.max_cstate=1 usbcore.autosuspend=-1"
# acpi=off is COMPLETELY REMOVED — ACPI runs normally
```

### Fix for 3-minute boot delay

With `CONFIG_USB_XHCI_HCD=m`, `systemd-udev-settle.service` times out waiting for USB enumeration on degraded hardware. This service is not essential on modern systems:

```bash
systemctl mask systemd-udev-settle.service
```

---

## Installing Ubuntu Without USB: The debootstrap Method

With USB completely dead, booting from a standard USB live image is impossible. The solution: install Ubuntu 24.04 directly onto the SP6's NVMe drive using `debootstrap` from the companion SP9 machine.

### High-level overview

```
SP9 (Surface Pro 9, Windows 11 + WSL2 Ubuntu 24.04)
    ↓  debootstrap --arch=amd64 noble /root/ubuntu-rootfs
    ↓  chroot: install grub-efi-amd64, initramfs-tools, kernel
    ↓  tar -czf → ubuntu-sp6-rootfs.tar.gz
    ↓  USB drive (letter D: or E:)
         ↓
SP6 (booted into Puppy Linux via UEFI polling mode, or UEFI Shell)
    ↓  partition NVMe: EFI (512MB, nvme0n1p1) + swap + root (nvme0n1p3)
    ↓  tar -xzf → extract rootfs to nvme0n1p3
    ↓  chroot: grub-install + update-grub
    ↓  reboot → Ubuntu 24.04
```

> **Why Puppy Linux works for the initial extraction**: Puppy Linux with a custom kernel can access USB in UEFI polling mode, **before** `ExitBootServices()` is called. Once Puppy's init scripts run and `ExitBootServices()` fires, USB dies — but by then, Puppy's ramdisk is already loaded and running. This gives a working Linux environment with network (not USB-dependent) for the extraction step.

### Step 1: Run debootstrap on SP9/WSL2

```bash
# In WSL2 on SP9, as root:
apt-get install debootstrap

# Create the Ubuntu 24.04 Noble base system (~800MB, 10-20 minutes)
debootstrap --arch=amd64 noble /root/ubuntu-rootfs http://archive.ubuntu.com/ubuntu/

# Success output ends with:
# I: Base system installed successfully.
```

### Step 2: Configure the chroot

```bash
# Mount necessary filesystems
mount --bind /dev      /root/ubuntu-rootfs/dev
mount --bind /proc     /root/ubuntu-rootfs/proc
mount --bind /sys      /root/ubuntu-rootfs/sys
mount --bind /etc/resolv.conf /root/ubuntu-rootfs/etc/resolv.conf

# Enter chroot
chroot /root/ubuntu-rootfs /bin/bash

# Inside the chroot — install essential packages
apt update
apt install -y grub-efi-amd64 initramfs-tools linux-firmware \
    network-manager sudo locales

# Set up locale, timezone, root password
locale-gen en_US.UTF-8
passwd root

exit
```

### Step 3: Transfer rootfs via USB drive

```bash
# In WSL2, mount the USB drive
# Windows letter D: → WSL path /mnt/d
mount -t drvfs D: /mnt/d

# Pack the rootfs (5-10 minutes)
tar -czf /mnt/d/ubuntu-sp6-rootfs.tar.gz -C /root/ubuntu-rootfs .

# Verify
ls -lh /mnt/d/ubuntu-sp6-rootfs.tar.gz
# Should be ~350-500MB
```

### Step 4: Partition the SP6's NVMe and install

```bash
# On SP6 (in Puppy Linux or rescue environment):
# Partition the NVMe (example with sgdisk)
sgdisk -Z /dev/nvme0n1                               # Wipe
sgdisk -n 1:0:+512M -t 1:ef00 /dev/nvme0n1          # EFI partition
sgdisk -n 2:0:+8G   -t 2:8200 /dev/nvme0n1          # Swap
sgdisk -n 3:0:0     -t 3:8300 /dev/nvme0n1          # Root

# Format
mkfs.vfat -F32 /dev/nvme0n1p1
mkswap /dev/nvme0n1p2
mkfs.ext4 /dev/nvme0n1p3

# Mount and extract
mount /dev/nvme0n1p3 /mnt/sp6
mkdir -p /mnt/sp6/boot/efi

# Mount USB drive and extract rootfs
mount /dev/sda1 /media/usb
tar -xzf /media/usb/ubuntu-sp6-rootfs.tar.gz -C /mnt/sp6
```

### Step 5: Install GRUB

```bash
# Chroot into the new system
mount --bind /dev  /mnt/sp6/dev
mount --bind /proc /mnt/sp6/proc
mount --bind /sys  /mnt/sp6/sys
mount /dev/nvme0n1p1 /mnt/sp6/boot/efi

chroot /mnt/sp6 /bin/bash

# Install GRUB for EFI
grub-install --target=x86_64-efi --efi-directory=/boot/efi \
    --bootloader-id=ubuntu --recheck

# Generate GRUB config (the kernel isn't installed yet, so this may be minimal)
update-grub

exit
```

### Step 6: Create /etc/fstab

```bash
# Get UUIDs
blkid /dev/nvme0n1p1
blkid /dev/nvme0n1p2
blkid /dev/nvme0n1p3

# Write /etc/fstab (in the chroot)
cat > /mnt/sp6/etc/fstab << EOF
UUID=<EFI-UUID>   /boot/efi   vfat   defaults   0   1
UUID=<swap-UUID>  none        swap   sw         0   0
UUID=<root-UUID>  /           ext4   errors=remount-ro  0  1
EOF
```

### Offline package installation (no internet on SP6)

Since SP6 has no network card (Marvell desoldered, no USB dongle yet), all packages must be downloaded on SP9 and transferred via USB drive.

**On SP9/WSL2** — download packages:

```bash
# Download to local cache WITHOUT installing (SP9 must have ubuntu 24.04 Noble)
apt-get install --download-only -y \
    kde-plasma-desktop plasma-pa plasma-nm \
    pulseaudio pulseaudio-module-bluetooth \
    network-manager wpasupplicant \
    libinput10 libinput-bin iio-sensor-proxy \
    linux-firmware \
    bluetooth bluez bluez-tools \
    build-essential git

# Create local APT repository on USB drive
REPO=/mnt/e/sp6-install
mkdir -p $REPO
cp /var/cache/apt/archives/*.deb $REPO/
cd $REPO
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz
ls -lh $REPO/
du -sh $REPO/   # Expect 1-3 GB
```

**On SP6** — use the local repository:

```bash
# Mount USB drive
mount /dev/sda1 /media/sp6-usb

# Add local repository
echo "deb [trusted=yes] file:///media/sp6-usb/sp6-install ./" \
    > /etc/apt/sources.list.d/local.list

apt update
apt install kde-plasma-desktop iptsd ...
```

> ⚠️ **`iptsd` is NOT in Ubuntu repositories.** It is a [linux-surface project](https://github.com/linux-surface/linux-surface) package. Download it separately from the linux-surface package repository:
> ```bash
> # On SP9/WSL2 — add the linux-surface repo and download iptsd
> curl -s https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc \
>     | gpg --dearmor | tee /etc/apt/trusted.gpg.d/surface.gpg > /dev/null
> echo "deb [arch=amd64] https://pkg.linux.surface.net/microsoft/noble/prod/deb stable main" \
>     | tee /etc/apt/sources.list.d/linux-surface.list
> apt update
> apt-get install --download-only -y iptsd
> cp /var/cache/apt/archives/iptsd*.deb /mnt/e/sp6-install/
> ```
> Then add `iptsd` to your local APT repo on the USB drive (re-run `dpkg-scanpackages` after copying the .deb).

> ⚠️ **Version discipline**: Make sure all packages come from Ubuntu 24.04 Noble. During this project, packages from Ubuntu 25.04 (Questing) were accidentally installed — specifically `initramfs-tools 0.150ubuntu3` (Questing) instead of `0.142ubuntu25` (Noble). This caused `dpkg --configure -a` failures.
>
> Fix if this happens:
> ```bash
> mv /etc/initramfs-tools/initramfs.conf.dpkg-new \
>    /etc/initramfs-tools/initramfs.conf
> dpkg --configure -a
> ```
> Always verify: `apt-cache policy initramfs-tools` should show the Noble version.

---

## Building the Patched Kernel on a Companion Machine

The kernel was compiled on SP9 (working USB, internet access), then transferred to SP6 via USB drive.

### Environment: SP9 / WSL2 Ubuntu 24.04

**Kernel sources location** (confirmed from build logs):
```
~/sp6-rebuild/linux-6.19.8-surface/
```

> **Important**: The kernel sources were on the WSL2 **internal** filesystem (home directory), not on the external USB drive (E:). During a critical compilation session, the external drive E: developed I/O errors. The internal drive was unaffected and compilation could continue from `~/sp6-rebuild/`.

### Install build dependencies

```bash
apt-get install -y build-essential libncurses-dev bison flex libssl-dev \
    libelf-dev bc git fakeroot kernel-package dwarves
```

### Get linux-surface kernel

```bash
mkdir -p ~/sp6-rebuild
cd ~/sp6-rebuild

# Option A: Clone linux-surface and apply patches
git clone https://github.com/linux-surface/linux-surface.git
# Follow their patch application instructions

# Option B: Get the specific version used in this project
# linux-surface 6.19.8 with surface patches applied
wget https://github.com/linux-surface/linux-surface/releases/...
# (check the linux-surface releases page for 6.19.x)
```

### Critical kernel config options

```bash
# Generate a default config and then adjust:
make menuconfig

# Non-negotiable options:
CONFIG_USB_XHCI_HCD=m            # MUST be module (not =y)
CONFIG_USB_XHCI_PCI=m            # MUST be module
CONFIG_FB=y                       # MUST be built-in (not =m!)
CONFIG_FRAMEBUFFER_CONSOLE=y      # Required for console output at boot
CONFIG_SURFACE_AGGREGATOR=m       # Type Cover, Surface hardware bus
CONFIG_SURFACE_AGGREGATOR_REGISTRY=m
CONFIG_INTEL_IPTS=m               # Touchscreen driver
CONFIG_HID_MULTITOUCH=m           # Multi-touch support

# Optional but recommended:
CONFIG_INTEL_IDLE=y
CONFIG_CPU_IDLE=y
```

> ⚠️ **CONFIG_FB must be `=y`, not `=m`**: This was discovered after kernel build #4. When compiled as a module, the framebuffer isn't available early enough in the boot process, causing a **black screen** after the kernel takes over. The kernel must have framebuffer support built in for early console output.

### Apply the two patches

**Patch 1: xhci-pci.c** (XHCLKGTEN fix — the main fix)

```bash
cd ~/sp6-rebuild/linux-6.19.8-surface

# Edit the file and add the patch before usb_add_hcd():
nano drivers/usb/host/xhci-pci.c
# Find: return usb_add_hcd(hcd, irq, IRQF_SHARED);
# Insert before it: the if(dev->vendor...) block shown above
```

**Patch 2: xhci.c** (HCRST skip — complementary fix)

```bash
nano drivers/usb/host/xhci.c
# Find the HCRST wait loop (around line 5484) and add the skip logic
```

### Build option A: Build only the USB modules (fast, ~5 minutes)

```bash
cd ~/sp6-rebuild/linux-6.19.8-surface

# Build only the 3 xHCI modules
make drivers/usb/host/xhci-hcd.ko \
     drivers/usb/host/xhci-pci.ko \
     drivers/usb/host/xhci-plat-hcd.ko

ls -la drivers/usb/host/xhci-*.ko
# xhci-hcd.ko, xhci-pci.ko, xhci-plat-hcd.ko
```

### Build option B: Full kernel build with .deb packages (slow, ~1-2 hours)

This is what was done in the final build to get a proper installable package:

```bash
cd ~/sp6-rebuild/linux-6.19.8-surface

# Build all packages (kernel image + headers + libc-dev)
make -j$(nproc) bindeb-pkg LOCALVERSION=-surface-3-xhci-m

# Output (in ~/sp6-rebuild/):
ls ~/sp6-rebuild/*.deb
# linux-headers-6.19.8-surface-3-xhci-m_6.19.8-g57d61aff0b53-2_amd64.deb
# linux-image-6.19.8-surface-3-xhci-m_6.19.8-g57d61aff0b53-2_amd64.deb
# linux-libc-dev_6.19.8-g57d61aff0b53-2_amd64.deb
```

### A nasty WSL2 disk bug encountered during compilation

During a critical compilation session, the external drive E: began failing with I/O errors on all commands:

```
-bash: /usr/bin/sed: Input/output error
-bash: /usr/bin/ls: Input/output error
read: Input/output error
```

**The kernel sources were NOT on E:**, so compilation was not blocked. But all commands using utilities from the external drive failed. The fix:

1. Exit WSL2
2. In Windows PowerShell (admin): `chkdsk E: /f` → reboot Windows
3. Restart WSL2

**Lesson**: Keep kernel sources and compilation on the WSL2 internal filesystem (home directory, `~/`), not on external drives. Use external drives only for transfer.

---

## Installing the Patched Modules on SP6

### If you built only the .ko modules (Build Option A):

```bash
# On SP6, with the USB drive mounted at /media/usb:
KVER="6.19.8-surface-3-xhci-m"
MODULE_DIR="/lib/modules/$KVER/kernel/drivers/usb/host"

mkdir -p $MODULE_DIR
cp /media/usb/xhci-hcd.ko $MODULE_DIR/
cp /media/usb/xhci-pci.ko $MODULE_DIR/
cp /media/usb/xhci-plat-hcd.ko $MODULE_DIR/

depmod -a $KVER
update-initramfs -u -k $KVER
```

### If you built the full .deb packages (Build Option B):

```bash
# On SP6, with the USB drive mounted:
dpkg -i /media/usb/linux-image-6.19.8-surface-3-xhci-m_*.deb
dpkg -i /media/usb/linux-headers-6.19.8-surface-3-xhci-m_*.deb

# GRUB will be updated automatically
# Remove acpi=off from GRUB if present:
nano /etc/default/grub
# GRUB_CMDLINE_LINUX_DEFAULT="intel_idle.max_cstate=1 usbcore.autosuspend=-1"

update-grub
```

### After installation: remove acpi=off from GRUB

This is critical. The whole point of the xhci-pci.c patch is to eliminate the need for `acpi=off`.

```bash
# Edit /etc/default/grub
# BEFORE:
GRUB_CMDLINE_LINUX_DEFAULT="acpi=off intel_idle.max_cstate=1 usbcore.autosuspend=-1"

# AFTER:
GRUB_CMDLINE_LINUX_DEFAULT="intel_idle.max_cstate=1 usbcore.autosuspend=-1"

update-grub
```

### Mask the udev-settle service

```bash
systemctl mask systemd-udev-settle.service
# Prevents the 3-minute boot timeout on degraded USB hardware
```

---

## Final System State

**Confirmed working as of June 26, 2026.**

### Kernel

```
Linux kernel:    6.19.8-surface-3-xhci-m
Package version: 6.19.8-g57d61aff0b53-2
Source:          linux-surface project + 2 custom patches
Built on:        SP9 / WSL2 Ubuntu 24.04
```

### GRUB

```bash
# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="intel_idle.max_cstate=1 usbcore.autosuspend=-1"
# GRUB has two entries:
# 1. Ubuntu (6.19.8-surface-3-xhci-m) ← default
# 2. SECOURS 6.6.40-surface-sp6       ← rescue (kept for safety)
```

### Hardware status

| Component | Status | Notes |
|-----------|--------|-------|
| USB ports (xHCI 8086:9d2f) | ✅ Functional | Immediate on boot |
| External USB keyboard | ✅ Functional | Immediate |
| Type Cover keyboard | ✅ Functional | Immediate (ACPI active) |
| Type Cover trackpad | ✅ Functional | Immediate (ACPI active) |
| Touchscreen (IPTS) | ✅ Functional | Via `iptsd` daemon, ACPI active |
| Bluetooth (TP-Link UB500 dongle) | ✅ Functional | |
| Microsoft Arc Mouse (BT) | ✅ Functional | |
| WiFi | ⚠️ USB dongle only | Marvell 88W8897 desoldered |
| USB-Ethernet (Baseus CAHUB-B0G) | ❌ Non-functional | See Known Issues |
| NVMe storage | ✅ Functional | |
| Display (Intel i915 iGPU) | ✅ Functional | |
| Audio | ✅ Functional | |
| Boot time | ✅ < 30 seconds | No udev-settle timeout |
| Desktop environment | KDE Plasma 6 | |
| OS | Ubuntu 24.04 LTS (Noble) | |

### Boot log confirmation

```
[    2.891] xhci-pci 0000:00:14.0: SP6 FIX: XHCLKGTEN hardware register corrected in probe
[    2.934] xhci-pci 0000:00:14.0: xHCI Host Controller
[    2.941] xhci-pci 0000:00:14.0: new USB bus registered, assigned bus number 1
[    3.012] usb 1-1: new high-speed USB device number 2 using xhci_hcd
```

The `-110` error is gone. USB enumerates immediately on boot.

---

## Known Remaining Issues

### Baseus CAHUB-B0G USB-Ethernet adapter

| Detail | Value |
|--------|-------|
| Hub model | Baseus CAHUB-B0G (8-in-1 USB hub) |
| Serial number | LX220403 |
| Ethernet chip | ASIX AX88179**A** (USB ID: 0b95:1790) |
| LED green | Fixed = power OK |
| LED orange | Blinking = network activity |

**Symptom**: The driver loads and the device is detected, but the network interface is never created:

```bash
lsusb
# Bus 001 Device 007: ID 0b95:1790 ASIX Electronics Corp. AX88179 Gigabit Ethernet

lsmod | grep asix
# asix        77824  0
# ax88179_178a  69632  0

ip link show
# 2: enp1s0f0u1u2: <BROADCAST,MULTICAST> mtu 1500 state DOWN
# (but: dhclient reports "Cannot find device enp1s0f0u1u2")

# /sys/class/net/ does not contain the interface
```

**Root cause**: The chip is identified as "AX88179**A**" (with suffix A), which may be a hardware variant requiring a different driver binding than the standard AX88179. The `ax88179_178a` driver loads but does not bind successfully to this variant.

**Status**: Non-critical — WiFi dongle provides connectivity. Investigation ongoing.

---

## Key Lessons Learned

1. **Hardware failures can be independent.** The Marvell WiFi/BT failure and the xHCI failure were separate issues occurring in parallel. Never assume removing the noisier component fixes both problems.

2. **UEFI Shell is an invaluable diagnostic tool.** The key breakthrough came from reading PCI registers *before* `ExitBootServices()`. If USB works in UEFI Shell but not in any OS, the problem is at the UEFI→OS transition. The `mm` command for MMIO reads and `pci` for config space reads are essential.

3. **Watch for ExitBootServices().** It's the exact moment things change. Observable on SP6 as the keyboard backlight LED going dark. Any register read before that moment vs. after reveals what the firmware is doing.

4. **CONFIG_USB_XHCI_HCD=m vs =y is not trivial.** Built-in drivers initialize too early for any userspace intervention. If you need to manipulate hardware state before a driver loads, compile it as a module. This applies to any driver where hardware state must be set up before initialization.

5. **The initramfs stage matters critically.** `init-top` runs before `load_modules`; `init-premount` does not. Using the wrong stage means your fix runs after the driver that already failed.

6. **CONFIG_FB must be `=y`, not `=m`.** Framebuffer compiled as a module causes a black screen at boot because it's not available early enough. This cost one complete kernel rebuild to discover.

7. **debootstrap is the right tool for offline Linux installation.** When you have no USB and no network on the target machine, debootstrap from a companion machine via a physical USB drive is the cleanest approach.

8. **Package version discipline saves hours.** When building an offline APT repo, every package must come from exactly the same Ubuntu release as the target system. Version mismatches (22.04 Jammy vs 24.04 Noble vs 25.04 Questing) cause subtle, hard-to-diagnose `dpkg --configure -a` failures.

9. **Keep build artifacts on internal drives.** External drives fail under load. The kernel sources and compilation were safe on the WSL2 internal filesystem; only the external drive failed with I/O errors.

10. **Multi-AI consultation works for complex, multi-day problems.** No single AI had the complete answer. The final solution emerged from iterative debugging across multiple AI models, each contributing different perspectives and cross-validating each other's analyses.

---

## AI Collaboration: Multi-Model Debugging

This repair took approximately 3 weeks and involved consultation with 7 AI models:

| AI | Role |
|----|------|
| **Claude** (Anthropic) | Initial root cause analysis, ExitBootServices mechanism, register investigation, debootstrap strategy |
| **Kimi / Moonshot AI** | Step-by-step kernel compilation, initramfs construction, Phase 3 comparative analysis, final xhci-pci.c patch development and debugging |
| **ChatGPT** (OpenAI) | Alternative approaches, PCH register analysis |
| **Gemini** (Google) | Cross-validation of register values, USB scheme parameters |
| **DeepSeek** | Additional kernel patch approaches |
| **Qwen** (Alibaba) | Supporting analysis |
| **GLM** (Zhipu AI) | Cross-validation, comparative framework |

**How the multi-AI approach worked**: Each AI was given the same context document (problem statement, register values, failed attempts log) and asked independently for analysis. Kimi then produced a comparative matrix ranking all proposed solutions by estimated probability of success, implementation time, and risk. This framework guided prioritization of the final phases.

**What each AI did best**:
- Claude: Root cause analysis, understanding the UEFI/OS boundary, debootstrap strategy
- Kimi: Hands-on step-by-step execution, compilation debugging, the final patch
- Gemini/DeepSeek/GLM: Cross-validation and catching edge cases

---

## Searchable Keywords

For people finding this via search:

`Surface Pro 6 USB not working` · `Surface Pro 6 USB dead` · `Surface Pro 6 USB Code 10` · `xhci_hcd can't setup -110` · `xHCI -110 Linux` · `Intel 8086:9d2f USB failure` · `Sunrise Point-LP xHCI broken` · `XHCLKGTEN register` · `ExitBootServices xHCI` · `Marvell 88W8897 AVASTAR desoldering` · `Surface Pro 6 Linux Ubuntu` · `HCRST stuck bit` · `xhci-pci.c patch` · `Surface Pro 6 xhci kernel patch` · `CONFIG_USB_XHCI_HCD module` · `setpci XHCLKGTEN 0x0FDF6D3F` · `debootstrap no USB` · `linux-surface kernel Surface Pro 6` · `Surface Pro 6 Ubuntu 24.04` · `KDE Plasma Surface Pro 6` · `iptsd Surface Pro 6` · `Surface Pro 6 acpi=off Type Cover dead` · `PCH silicon degradation xHCI`

---

## Repository Structure and Patch File

```
surface-pro-6-xhci-fix/
├── README.md                               ← This file
├── patch/
│   ├── xhci-pci-sp6-xhclkgten.patch       ← Main patch (XHCLKGTEN fix)
│   └── xhci-hcrst-skip.patch              ← Complementary patch (HCRST skip)
├── scripts/
│   ├── initrd-xhci-hook-init-top.sh       ← Interim: initrd setpci hook
│   ├── sp9-download-packages.sh           ← Download Ubuntu packages on SP9/WSL2
│   ├── sp9-build-kernel-modules-only.sh   ← Build only xhci .ko files (fast)
│   └── sp9-full-kernel-build.sh           ← Full kernel build with .deb packages
└── docs/
    ├── uefi-shell-diagnostics.md          ← UEFI Shell commands for register reading
    ├── register-analysis.md               ← XHCLKGTEN bit analysis (0x0FDF6D3F vs 0x0FCE6E5B)
    ├── failed-attempts-log.md             ← Detailed log of all failed attempts
    └── baseus-cahub-b0g-issue.md          ← AX88179A ethernet debugging
```

### The Main Patch (xhci-pci.c)

```diff
--- a/drivers/usb/host/xhci-pci.c
+++ b/drivers/usb/host/xhci-pci.c
@@ -650,6 +650,19 @@ static int xhci_pci_common_probe(struct pci_dev *dev, const struct pci_device_i
 	if (ret)
 		goto put_hcd;
 
+	/*
+	 * Surface Pro 6 (Intel 8086:9d2f / Sunrise Point-LP PCH) workaround:
+	 * The UEFI firmware corrupts register XHCLKGTEN (PCI config offset 0x50)
+	 * at ExitBootServices(), changing it from 0x0FDF6D3F (working) to
+	 * 0x0FCE6E5B (broken). This causes xhci_hcd: can't setup: -110 on all OS.
+	 *
+	 * Restore the correct value here, right before usb_add_hcd() is called.
+	 * This allows the driver to work with ACPI fully active, eliminating
+	 * the need for acpi=off and restoring Type Cover and IPTS touchscreen.
+	 *
+	 * Variable name is 'dev' in this function, NOT 'pdev'.
+	 */
+	if (dev->vendor == PCI_VENDOR_ID_INTEL && dev->device == 0x9d2f) {
+		pci_write_config_dword(dev, 0x50, 0x0FDF6D3F);
+		dev_info(&dev->dev, "SP6 FIX: XHCLKGTEN hardware register corrected in probe\n");
+	}
+
 	return usb_add_hcd(hcd, irq, IRQF_SHARED);
```

---

*Repair completed June 2026, on a Surface Pro 6 (model 1796) with UEFI firmware 239.779.768. If your Surface Pro 6 USB is failing, the most important diagnostic question is: **does USB work in UEFI Shell?** If yes, this XHCLKGTEN register fix is almost certainly your solution.*
