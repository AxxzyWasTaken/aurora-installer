# SPDX-License-Identifier: MIT
"""Speaker tuning collection, on synthetic data only.

Based on aurora-audio-dsp by saku (MIT). No Apple tuning file is used or
stored by these tests.
"""
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from asahi_firmware import audio_tuning  # noqa: E402
from asahi_firmware.audio_tuning import AudioTuningFWCollection  # noqa: E402


def fake_run(nodes, build=b"00A000\n"):
    def run(args, capture_output=True):
        if args[0] == "ioreg":
            return subprocess.CompletedProcess(args, 0, plistlib.dumps(nodes, fmt=plistlib.FMT_XML), b"")
        if args[0] == "sysctl":
            return subprocess.CompletedProcess(args, 0, build, b"")
        raise AssertionError(args)
    return run


def tunings(root, aid="AID35"):
    folder = root / aid
    (folder / "DSP" / "Strips").mkdir(parents=True)
    (folder / "ADM").mkdir()
    (folder / "ADM" / "config.plist").write_bytes(b"synthetic config")
    (folder / "DSP" / "Strips" / "aid35-aufx-spp3-appl.plist").write_bytes(b"synthetic spp3")
    (folder / "DSP" / "Strips" / "._aid35-aufx-spp3-appl.plist").write_bytes(b"sidecar")
    (folder / ".DS_Store").write_bytes(b"finder")
    return folder


class AudioTuningTest(unittest.TestCase):
    def test_acoustic_id_is_one_little_endian_word(self):
        self.assertEqual(audio_tuning.acoustic_id(b"\x23\0\0\0"), 35)
        self.assertIsNone(audio_tuning.acoustic_id(b"\x23"))
        self.assertIsNone(audio_tuning.acoustic_id(b"\0\0\0\0"))

    def test_laptop_collects_folder_record_and_manifest(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            spts = bytes(range(16))
            col = AudioTuningFWCollection(
                tunings_root=str(root),
                run=fake_run([{"acoustic-id": b"\x23\0\0\0", "speaker-thiele-small": spts}]))
            names = sorted(n for n, _ in col.files())
            self.assertEqual(names, [
                "apple/audio-tuning/AID35/ADM/config.plist",
                "apple/audio-tuning/AID35/DSP/Strips/aid35-aufx-spp3-appl.plist",
                "apple/audio-tuning/manifest.json",
                "apple/audio-tuning/speaker-thiele-small.bin",
            ])
            files = dict(col.files())
            meta = json.loads(files["apple/audio-tuning/manifest.json"].data)
            self.assertEqual(meta["aid"], "AID35")
            self.assertEqual(meta["macos_build"], "00A000")
            self.assertEqual(meta["based_on"], "aurora-audio-dsp by saku (MIT)")
            self.assertEqual(meta["speaker_thiele_small"]["sha256"], hashlib.sha256(spts).hexdigest())
            for rec in meta["files"]:
                data = files["apple/audio-tuning/" + rec["path"]].data
                self.assertEqual(rec["sha256"], hashlib.sha256(data).hexdigest())

            # The fallback archive round-trips through the Linux-side update.
            out = root / "fallback"
            self.assertTrue(col.write_fallback(str(out)))
            again = AudioTuningFWCollection(str(out))
            self.assertEqual(sorted(n for n, _ in again.files()), names)
            (out / "audio-tuning" / "AID35" / "ADM" / "config.plist").write_bytes(b"changed")
            self.assertEqual(AudioTuningFWCollection(str(out)).files(), [])

    def test_desktop_without_calibration_still_gets_tuning(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root, "AID12")
            col = AudioTuningFWCollection(
                tunings_root=str(root), run=fake_run([{"acoustic-id": b"\x0c\0\0\0"}]))
            names = [n for n, _ in col.files()]
            self.assertIn("apple/audio-tuning/AID12/ADM/config.plist", names)
            self.assertNotIn("apple/audio-tuning/speaker-thiele-small.bin", names)

    def test_absent_or_ambiguous_nodes_collect_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            self.assertEqual(AudioTuningFWCollection(tunings_root=str(root), run=fake_run([])).files(), [])
            two = [{"acoustic-id": b"\x23\0\0\0"}, {"acoustic-id": b"\x09\0\0\0"}]
            self.assertEqual(AudioTuningFWCollection(tunings_root=str(root), run=fake_run(two)).files(), [])
            missing = [{"acoustic-id": b"\x09\0\0\0"}]
            self.assertEqual(AudioTuningFWCollection(tunings_root=str(root), run=fake_run(missing)).files(), [])

    def test_links_out_of_the_folder_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            folder = tunings(root)
            (root / "outside").write_bytes(b"x")
            (folder / "escape").symlink_to(root / "outside")
            col = AudioTuningFWCollection(
                tunings_root=str(root), run=fake_run([{"acoustic-id": b"\x23\0\0\0"}]))
            self.assertEqual(col.files(), [])


if __name__ == "__main__":
    unittest.main()
