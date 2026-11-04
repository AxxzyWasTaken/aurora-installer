# Speaker tuning collection

Based on [aurora-audio-dsp](#attribution) by saku (MIT). The collection described here follows saku's `tools/macos-collector/collect-audio-tuning.sh`, and saku is the co-author of this specification and of the installer commits that implement it.

## Purpose

macOS protects and voices each Mac's internal speakers with tuning that belongs to that Mac: a per-model tuning folder and, on Macs with speaker calibration, a per-unit factory calibration record. The Linux speaker protection (speakerguardd v2) and the speaker graph read their parameters from these files, so that Linux uses the same limits macOS uses on the same machine.

The installer copies both, read-only, from the user's own running macOS into the per-machine vendor firmware on the ESP, next to the Wi-Fi, Bluetooth and camera firmware it already collects. Nothing is shipped: no installer package, release asset, repository or test fixture carries Apple tuning data. Tests use synthetic files.

## Inputs

| Input | Source | Present on |
|---|---|---|
| `acoustic-id` | device tree `/product/audio` (one audio node; a little-endian 32-bit word) | every Mac with built-in audio |
| tuning folder | `/System/Library/Audio/Tunings/AID<acoustic-id>/`, every regular file, recursively | every Mac with an `acoustic-id` |
| `speaker-thiele-small` | the same device-tree node, raw bytes | Macs with speaker calibration (MacBook Air and Pro); absent on Mac mini, iMac and Mac Studio |

- The tuning folder is read from the sealed, read-only system volume, with the same protected-tree reader the installer uses for system Wi-Fi firmware.
- AppleDouble (`._*`) and `.DS_Store` sidecars are skipped. A link is kept only when it names a file inside the folder, and is stored as a copy of that file.
- A Mac without speaker calibration still gets its tuning folder. A Mac without an `acoustic-id`, or without a folder for it, gets nothing and installs normally.
- Collection never stops an installation. A failure, an ambiguous device tree (two audio nodes with an `acoustic-id`) or an implausible input leaves the tuning out entirely, never partly. Linux then uses its family fallback profiles. Cancellation still ends the step.
- Bounds: at most 1024 files and 64 MiB per folder, and 4 KiB for the calibration record. The largest folder seen so far is 34 files and 2.4 MB.

## Outputs

The files go into the vendor firmware package (`vendorfw/firmware.tar`, `vendorfw/firmware.cpio` and its `manifest.txt` with SHA-256 per file), under `apple/audio-tuning/`. They also go into the raw fallback archive (`asahi/all_firmware.tar.gz`), under `audio-tuning/`:

```
apple/audio-tuning/
  manifest.json
  speaker-thiele-small.bin        (only when the Mac has one)
  AID<n>/ADM/config.plist
  AID<n>/DSP/Graphs/builtin_speaker_out.dspg
  AID<n>/DSP/Strips/builtin_speaker_out_general.austrip
  AID<n>/DSP/Strips/aid<n>-aufx-spp3-appl.plist
  AID<n>/...                       (every file of the folder, unchanged)
```

On Linux the package is unpacked under `/lib/firmware/vendor/`, so the bundle is `/lib/firmware/vendor/apple/audio-tuning/`. The ESP copy in `vendorfw/firmware.tar` is the source of truth when that tree is absent. A firmware rebuild from the fallback archive (`asahi_firmware.update`) re-verifies every file against `manifest.json` before it repackages them; a changed file leaves the tuning out.

### `manifest.json`, schema 1

```json
{
  "schema": 1,
  "kind": "aurora-audio-tuning",
  "acoustic_id": 35,
  "aid": "AID35",
  "macos_build": "25G83",
  "speaker_thiele_small": {"path": "speaker-thiele-small.bin", "bytes": 138, "sha256": "…"},
  "files": [{"path": "AID35/ADM/config.plist", "bytes": 1234, "sha256": "…"}],
  "based_on": "aurora-audio-dsp by saku (MIT)"
}
```

- `speaker_thiele_small` is `null` on Macs without calibration.
- `macos_build` is the running macOS build the folder was read from. A later macOS update can change the tuning, and re-running the firmware step collects the new set.
- Paths are relative to the manifest's directory. Readers must reject absolute paths, `.` or `..` components, and any file whose size or SHA-256 differs from the manifest.

The bundle is a superset of the one saku's collector writes (`audio-tuning-AID<n>/` with `AID<n>/`, `speaker-thiele-small.bin` and `metadata.json`), and the Linux reader accepts both layouts.

## Implementations

- Native installer (Swift): `NativeAudioTuningInputs`, called from `NativeVendorFirmware` as the `vendor_audio_tuning` phase.
- Python installer and firmware rebuild: `asahi_firmware/audio_tuning.py` (`AudioTuningFWCollection`), called from `stub.py` and `asahi_firmware/update.py`.
- Linux reader and validator: `aurora-speaker-tuning` in aurora-silicon/speakerguardd (v2 branch). It loads the bundle from `/lib/firmware/vendor/apple/audio-tuning/`, from the ESP's `vendorfw/firmware.tar`, or from saku's collector bundle. It verifies the manifest, parses binary and XML property lists, and exposes the protection parameter sets and the speaker graph and strip definitions.

## Privacy

The installer reads only `acoustic-id` and `speaker-thiele-small` from the device tree, and only the selected tuning folder. It reads no serial numbers or other identifiers. The calibration record is factory measurement data (driver resistance and calibration temperature per speaker). It stays on the user's machine, like the other factory calibration the installer already stores.

## Attribution

The approach, the device-tree properties used, the folder layout and the bundle format come from aurora-audio-dsp by saku, released under the MIT license:

```
MIT License

Copyright (c) 2026 saku

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
