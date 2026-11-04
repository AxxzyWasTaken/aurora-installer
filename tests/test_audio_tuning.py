# SPDX-License-Identifier: MIT
"""Speaker tuning collection, on synthetic data only.

Based on aurora-audio-dsp by saku (MIT). No Apple tuning file is used or
stored by these tests.
"""
import hashlib
import json
import os
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
    (root / "Config").mkdir(exist_ok=True)
    (root / "Config" / f"{aid}.plist").write_bytes(b"synthetic volume config")
    database = {aid: {"Built-in Speaker": {"48k - General": {"Graph": "synthetic.dspg"}}},
                "AID999": {"Built-in Speaker": {}}}
    (root / "DeviceDSPDatabase.plist").write_bytes(plistlib.dumps(database, fmt=plistlib.FMT_BINARY))
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
                "apple/audio-tuning/Config/AID35.plist",
                "apple/audio-tuning/DeviceDSPDatabase.plist",
                "apple/audio-tuning/manifest.json",
                "apple/audio-tuning/speaker-thiele-small.bin",
            ])
            files = dict(col.files())
            meta = json.loads(files["apple/audio-tuning/manifest.json"].data)
            self.assertEqual(meta["aid"], "AID35")
            self.assertEqual(meta["macos_build"], "00A000")
            self.assertEqual(meta["based_on"], "aurora-audio-dsp by saku (MIT)")
            self.assertEqual(meta["device_dsp_database"], "DeviceDSPDatabase.plist")
            self.assertEqual(meta["config"], "Config/AID35.plist")
            self.assertEqual(meta["schema"], 2)
            self.assertIs(meta["complete"], True)
            self.assertEqual(meta["source_file_count"], 2)
            self.assertEqual(meta["source_file_count"],
                             sum(r["path"].startswith("AID35/") for r in meta["files"]))
            entry = plistlib.loads(files["apple/audio-tuning/DeviceDSPDatabase.plist"].data)
            self.assertEqual(list(entry), ["AID35"])
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


AID35 = [{"acoustic-id": b"\x23\0\0\0"}]


def collect(root):
    return AudioTuningFWCollection(tunings_root=str(root), run=fake_run(AID35))


def fallback(tmp):
    """A collected bundle written out as the fallback archive's directory."""
    root = pathlib.Path(tmp)
    tunings(root)
    col = collect(root)
    out = root / "fallback"
    assert col.write_fallback(str(out))
    return out, out / "audio-tuning"


def rewrite(bundle, edit):
    path = bundle / "manifest.json"
    meta = json.loads(path.read_bytes())
    edit(meta)
    path.write_text(json.dumps(meta))


class CompletenessTest(unittest.TestCase):
    """A short read never becomes a bundle, and a bundle that cannot prove
    it is complete is refused."""

    def assertNothing(self, col):
        self.assertEqual(col.files(), [])
        self.assertEqual(col.bundle, {})

    @unittest.skipIf(os.geteuid() == 0, "root reads unreadable directories")
    def test_unlistable_directory_fails_the_collection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            strips = tunings(root) / "DSP" / "Strips"
            strips.chmod(0)
            try:
                with self.assertLogs("asahi_firmware.audio_tuning", "WARNING"):
                    self.assertNothing(collect(root))
            finally:
                strips.chmod(0o755)

    def test_directory_link_fails_the_collection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            folder = tunings(root)
            (folder / "Linked").symlink_to(folder / "DSP", target_is_directory=True)
            self.assertNothing(collect(root))

    def test_dangling_or_special_link_fails_the_collection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            folder = tunings(root)
            (folder / "ADM" / "gone.plist").symlink_to(folder / "ADM" / "missing.plist")
            self.assertNothing(collect(root))

    def test_link_within_the_folder_is_a_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            folder = tunings(root)
            (folder / "ADM" / "alias.plist").symlink_to("config.plist")
            files = dict(collect(root).files())
            self.assertEqual(files["apple/audio-tuning/AID35/ADM/alias.plist"].data,
                             b"synthetic config")
            meta = json.loads(files["apple/audio-tuning/manifest.json"].data)
            self.assertEqual(meta["source_file_count"], 3)

    def test_missing_config_or_database_entry_is_no_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            (root / "Config" / "AID35.plist").unlink()
            self.assertNothing(collect(root))
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            (root / "DeviceDSPDatabase.plist").write_bytes(
                plistlib.dumps({"AID999": {}}, fmt=plistlib.FMT_BINARY))
            self.assertNothing(collect(root))
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            (root / "DeviceDSPDatabase.plist").unlink()
            self.assertNothing(collect(root))

    def test_oversized_config_is_no_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            (root / "Config" / "AID35.plist").write_bytes(b"x" * ((1 << 20) + 1))
            self.assertNothing(collect(root))

    def test_short_count_is_refused_by_the_writer(self):
        with self.assertRaises(ValueError):
            audio_tuning.tree(35, {"a": b"1"}, None, "00A000",
                              {"DeviceDSPDatabase.plist": b"d", "Config/AID35.plist": b"c"},
                              source_count=2)

    def test_update_accepts_the_intact_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, _ = fallback(tmp)
            self.assertEqual(len(AudioTuningFWCollection(str(out)).files()), 5)

    def test_update_refuses_inconsistent_manifests(self):
        def drop_folder_record(meta):
            meta["files"] = [r for r in meta["files"] if r["path"] != "AID35/ADM/config.plist"]

        def drop_config(meta):
            meta["files"] = [r for r in meta["files"] if r["path"] != "Config/AID35.plist"]

        def stray(meta):
            meta["files"].append({"path": "elsewhere/x", "bytes": 0,
                                  "sha256": hashlib.sha256(b"").hexdigest()})

        edits = {
            "incomplete": lambda m: m.update(complete=False),
            "no completeness flag": lambda m: m.pop("complete"),
            "no count": lambda m: m.pop("source_file_count"),
            "count too high": lambda m: m.update(source_file_count=3),
            "folder record dropped": drop_folder_record,
            "config dropped": drop_config,
            "config null": lambda m: m.update(config=None),
            "database null": lambda m: m.update(device_dsp_database=None),
            "aid mismatch": lambda m: m.update(aid="AID99"),
            "old schema": lambda m: m.update(schema=1),
            "path outside the layout": stray,
            "huge record": lambda m: m["files"][0].update(bytes=(64 << 20) + 1),
        }
        for name, edit in edits.items():
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                out, bundle = fallback(tmp)
                rewrite(bundle, edit)
                self.assertNothing(AudioTuningFWCollection(str(out)))

    def test_update_refuses_linked_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            out, bundle = fallback(tmp)
            entry = bundle / "AID35" / "ADM" / "config.plist"
            copy = pathlib.Path(tmp) / "copy"
            copy.write_bytes(entry.read_bytes())
            entry.unlink()
            entry.symlink_to(copy)
            self.assertNothing(AudioTuningFWCollection(str(out)))

    def test_collection_failure_never_raises_and_leaves_nothing(self):
        """The invariant the installer relies on: any failure is logged,
        no partial bundle is kept, and the installation carries on."""
        def broken(args, capture_output=True):
            raise OSError("ioreg failed")
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertLogs("asahi_firmware.audio_tuning", "WARNING"):
                col = AudioTuningFWCollection(tunings_root=tmp, run=broken)
            self.assertNothing(col)
            self.assertFalse(col.write_fallback(tmp))
            self.assertFalse((pathlib.Path(tmp) / "audio-tuning").exists())

    def test_fallback_write_failure_leaves_no_partial_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = pathlib.Path(tmp)
            tunings(root)
            col = collect(root)
            out = root / "fallback"
            # A file where AID35/ must be a directory stops the write midway.
            (out / "audio-tuning").mkdir(parents=True)
            (out / "audio-tuning" / "AID35").write_bytes(b"in the way")
            with self.assertLogs("asahi_firmware.audio_tuning", "WARNING"):
                self.assertFalse(col.write_fallback(str(out)))
            self.assertFalse((out / "audio-tuning").exists())


if __name__ == "__main__":
    unittest.main()
