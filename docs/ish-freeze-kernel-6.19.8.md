# Kernel 6.19.8 on Surface Pro 6: boot freeze caused by the Intel ISH sensor hub

**Status:** workaround confirmed on one unit. Root cause **not** identified. Feedback from other Surface Pro 6 owners is welcome (open an issue).

This is a follow-up to the xHCI fix described in the main README. Once USB works, a second, unrelated problem shows up with kernel 6.19.8: the machine can hard-freeze during early boot. This page documents how it was isolated and how to work around it.

## Environment

- Surface Pro 6 (model 1796), Core i5-8250U, Ubuntu 24.04
- Kernel 6.19.8 (linux-surface configuration) with the xHCI patch from this repository
- Sensor hub: Intel ISH, PCI ID `8086:9d35`, at `00:13.0`
- Module set involved: `intel_ish_ipc`, `intel_ishtp`, `intel_ishtp_hid`, `hid_sensor_hub`

## Symptoms

- Hard freeze 1 to 9 seconds after the kernel starts, while the initramfs is loading modules (udev coldplug).
- The screen stops updating, keyboard LEDs go dead, no network, no SSH.
- Nothing is written to the persistent journal (it is not running yet), so the only evidence is the screen.
- With default logging, the last visible line is `intel_ish_ipc 0000:00:13.0: enabling device (0000 -> 0002)`, at about 1.6 s. With `initcall_debug` enabled, the last line seen was `initcall hid_generic_init returned 0`, at about 4 s or 8.6 s. The exact last line depends on logging options, but the freeze always happens while the ISH modules are loading.

## Bisection

| Boot parameter | Result |
|---|---|
| no module blocked | freeze, every attempt |
| `module_blacklist=intel_ish_ipc,intel_ishtp,intel_ishtp_hid,hid_sensor_hub` | boots normally, stable |
| only `hid_sensor_hub` blocked | freeze, at the `intel_ish_ipc` probe |

So the transport driver alone is enough to trigger the freeze. The HID bridge (`hid_sensor_hub`) is not the culprit.

## What was eliminated

During bisection, none of these made a difference: docking station and power path, USB dongles, a complete power drain (disconnecting all power, holding the power button, two-button reset), LPSS, Surface Aggregator (SAM), i915, IPTS, ITHC, Bluetooth and USB audio modules, SD/MMC controllers.

IOMMU was **not** tested directly. DMAR faults such as `[DMA Write NO_PASID] Request device [00:14.0] fault addr 0x0 ... PTE Write access is not set` are present even on stable boots where the ISH is blocked, so they do not look like the freeze mechanism.

## Workaround

Add this to the kernel command line:

```
module_blacklist=intel_ish_ipc,intel_ishtp,intel_ishtp_hid,hid_sensor_hub
```

The kernel parameter is used on purpose: it is honored inside the initramfs, where the freeze happens.

## What you lose

The ISH exposes the accelerometer and the ambient light sensor. Without it there is no `iio` device, so `iio-sensor-proxy` has nothing to read: no automatic screen rotation and no automatic brightness. Manual rotation works fine with `xrandr -o left|normal` plus an `xinput` coordinate transformation matrix for the touchscreen, bound to a keyboard shortcut (see [`scripts/rotate-manual.sh`](../scripts/rotate-manual.sh)). Touch input itself keeps working with the in-kernel IPTS driver.

## Open questions

- On the same unit, the hub bound without freezing in an earlier configuration with the same kernel version. What changed is unknown. Possible factors, none verified: boot parameters, module load timing, firmware state, hardware ageing.
- Whether other Surface Pro 6 units are affected.
- Whether loading the ISH modules late (from the root filesystem instead of the initramfs) avoids the freeze. Untested.

## Testing a risky boot safely

When a boot may hard-freeze, you want a one-shot test entry that falls back to a known-good entry by itself:

1. Keep your default entry unchanged (with the workaround).
2. Copy the kernel and initrd to the EFI System Partition and create a temporary UEFI entry for them, with the test command line:
   ```
   efibootmgr -c -d /dev/<disk> -p <esp-partition-number> -L "TEST" \
     -l '\EFI\TEST\vmlinuz.efi' \
     -u 'root=<root-device> rw initrd=\EFI\TEST\initrd.img <test parameters>'
   ```
3. Arm it for the next boot only: `efibootmgr -n <new-entry-number>`.
4. Power-cycle. If the machine freezes, force it off. The firmware consumes the one-shot entry, so the following boot returns to the default entry. In our case the firmware also deleted the temporary entry itself after use.
5. Remove the test directory from the ESP afterwards.

Adapt the disk, partition and root device to your system, and always keep a backup of your bootloader configuration. Note that on a system with a minimal GRUB on the ESP, running `update-grub` may have no effect; check which configuration file your GRUB really reads.

## Side notes from the same session

- Holding the power button for too long (well over 20 seconds) can make the tablet power back on instead of staying off. Release it as soon as the screen goes dark.
- A USB Wi-Fi dongle based on the Atheros AR9271 can end up in a state where the log shows `ath9k_htc: Target is unresponsive` and USB enumeration loops. Replugging was not enough; a full power cycle (shut down, disconnect external power for about 30 seconds, power on) fixed it.
- A worn-out battery makes the tablet cut power spontaneously when it runs without external power. This looks like a software crash but is not.
