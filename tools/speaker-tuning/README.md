# Speaker tuning for an existing install

New installs collect each Mac's speaker tuning at install time (see
[macOS/docs/speaker-tuning.md](../../macOS/docs/speaker-tuning.md)). These two
scripts add it to a system that was installed before that, without
reinstalling. Run both from a checkout of this repository.

## 1. On the Mac's own macOS

```sh
tools/speaker-tuning/collect-macos.sh
```

This uses only the system `/usr/bin/python3` (it may ask to install the
Command Line Tools the first time) and reads the repository's
`asahi_firmware` without writing to it. No sudo is needed. It prints the AID,
the number of tuning files, whether the per-unit calibration
(`speaker-thiele-small`) is present, and writes
`~/aurora-speaker-tuning-<mac>-AID<n>.tar.gz` (mode 0600). Pass `-o FILE` to
write it somewhere else. Copy the tarball to the Linux side of the same Mac,
for example with a USB stick or `scp`.

The tarball holds `audio-tuning/` exactly as the installer writes it, plus
`aurora-speaker-tuning.json` with the Mac's model (`hw.target`, such as
J413AP) so the Linux side can refuse a bundle from another model.

## 2. On Linux (Fedora, Arch Linux ARM or NixOS)

```sh
sudo tools/speaker-tuning/install-linux.sh --dry-run aurora-speaker-tuning-j413ap-AID13.tar.gz
sudo tools/speaker-tuning/install-linux.sh aurora-speaker-tuning-j413ap-AID13.tar.gz
```

It needs `python3` (on NixOS without one it runs itself under
`nix shell nixpkgs#python3`). It finds the system ESP the same way
asahi-fwupdate does (the device tree's ESP PARTUUID, or `/boot/efi` or
`/boot` holding m1n1), mounting it only if it is not mounted. `--esp DIR`
overrides that. Then it

1. re-verifies the bundle against its `manifest.json` with
   `AudioTuningFWCollection(path=...)`, and checks that it came from this
   model and, if the ESP already has a bundle, that the AID is the same
   (`--any-mac` skips both),
2. stops with "already present, identical" if both `asahi/all_firmware.tar.gz`
   and `vendorfw/` already hold this bundle,
3. writes a copy of `all_firmware.tar.gz` with its `audio-tuning/` replaced by
   the bundle, and rebuilds `vendorfw/` from it and the ESP's kernelcache with
   this repository's `asahi_firmware.update`, in a temporary directory,
4. refuses unless the rebuilt `manifest.txt` keeps every old entry outside
   `apple/audio-tuning/` by path and SHA-256, the `u-boot/` copies are kept,
   and the tuning entries are exactly the bundle,
5. backs up `all_firmware.tar.gz` and `vendorfw/` to
   `/var/lib/aurora-rollback/speaker-tuning-<time>-<id>/` (`--backup-dir`
   changes the root) and checks the copies,
6. copies the new files onto the ESP as `vendorfw.new` and
   `all_firmware.tar.gz.new`, and swaps each in with one atomic
   `renameat2(RENAME_EXCHANGE)` (two renames on kernels without it). If the
   second swap fails the first one is swapped back.

`--dry-run` does steps 1 to 4 and changes nothing. Any failure before the
swap leaves the ESP untouched, and a failed swap is undone.

Then reboot. The initramfs unpacks the bundle to
`/lib/firmware/vendor/apple/audio-tuning/` (on NixOS
`/run/aurora-firmware/vendorfw/apple/audio-tuning/`). Check it with

```sh
sudo tools/speaker-tuning/install-linux.sh --verify
```

which verifies every file against `manifest.json`, compares the bundle with
the ESP's `vendorfw/`, and on SELinux systems prints the number of denials
since boot (it should be 0).

## Notes

- Fedora's `asahi-fwupdate` uses the system `python3-asahi_firmware`, which
  does not collect speaker tuning yet. If it rebuilds `vendorfw/`, the bundle
  drops out of `vendorfw/` but stays in `all_firmware.tar.gz`. Running
  `install-linux.sh` again with the same tarball rebuilds `vendorfw/` only.
- Collect again after a macOS update that changes the tuning. A newer bundle
  for the same AID replaces the old one.
- The tarball and the backups hold this Mac's own calibration. Keep them on
  the Mac and do not share them.
