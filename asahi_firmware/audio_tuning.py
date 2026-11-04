# SPDX-License-Identifier: MIT
#
# Based on aurora-audio-dsp by saku (MIT): the collection of the machine's
# own AID<n> tuning folder through the device tree's `acoustic-id`, and of the
# per-unit `speaker-thiele-small` calibration, follows saku's
# tools/macos-collector/collect-audio-tuning.sh.
#
# Copyright (c) 2026 saku
# Copyright (c) 2026 The Aurora Silicon Contributors
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
"""This Mac's own speaker tuning, for the Linux speaker protection.

The device tree's audio node names the tuning folder (`acoustic-id` 35
selects /System/Library/Audio/Tunings/AID35) and, on Macs with speaker
calibration, carries the per-unit `speaker-thiele-small` record. Both are
copied unchanged, read-only, into the per-machine vendor firmware under
`apple/audio-tuning/`, with a manifest of sizes and SHA-256 hashes, and into
the raw fallback archive under `audio-tuning/`. Nothing is shipped: the data
comes from the user's own system volume and stays on the user's own ESP.

Collection never stops an installation; Linux falls back to its family
profiles without it.
"""
import hashlib, json, logging, os, plistlib, subprocess

from .core import FWFile

log = logging.getLogger("asahi_firmware.audio_tuning")

TUNINGS_ROOT = "/System/Library/Audio/Tunings"
PACKAGE_PREFIX = "apple/audio-tuning/"
FALLBACK_DIR = "audio-tuning"
MANIFEST = "manifest.json"
SPTS = "speaker-thiele-small.bin"
DATABASE = "DeviceDSPDatabase.plist"


def config_name(acoustic):
    return f"Config/AID{acoustic}.plist"


def database_entry(data, acoustic):
    """This Mac's entry of the DSP database, as a plist with that one key."""
    root = plistlib.loads(data)
    if not isinstance(root, dict):
        raise ValueError("DSP database is not a dictionary")
    key = f"AID{acoustic}"
    if key not in root:
        return None
    return plistlib.dumps({key: root[key]}, fmt=plistlib.FMT_XML)
MAX_FILES = 1024
MAX_BYTES = 64 << 20
BASED_ON = "aurora-audio-dsp by saku (MIT)"


def acoustic_id(data):
    """The device tree stores `acoustic-id` as one little-endian 32-bit word."""
    if not isinstance(data, bytes) or len(data) != 4:
        return None
    value = int.from_bytes(data, "little")
    return value if 0 < value < 100000 else None


def admitted(relative):
    parts = relative.split("/")
    if not relative or relative.startswith("/") or "\\" in relative or "\0" in relative:
        return False
    if any(p in ("", ".", "..") for p in parts):
        return False
    return not any(p.startswith("._") or p == ".DS_Store" for p in parts)


def probe(run=subprocess.run):
    """(acoustic-id bytes, speaker-thiele-small bytes or None), or None."""
    p = run(["ioreg", "-a", "-r", "-p", "IODeviceTree", "-n", "audio", "-k", "acoustic-id"],
            capture_output=True)
    if p.returncode != 0 or not p.stdout.strip():
        return None
    found = []
    for node in plistlib.loads(p.stdout):
        if isinstance(node.get("acoustic-id"), bytes):
            spts = node.get("speaker-thiele-small")
            found.append((node["acoustic-id"], spts if isinstance(spts, bytes) else None))
    if len(found) != 1:
        if found:
            log.warning("Several audio nodes carry acoustic-id; speaker tuning not collected")
        return None
    return found[0]


def read_folder(path):
    """Regular files of a tuning folder by relative path; links within the
    folder are kept as copies of their targets."""
    files = {}
    total = 0
    root = os.path.realpath(path)
    for parent, dirs, names in os.walk(root, followlinks=False):
        for name in sorted(names):
            full = os.path.join(parent, name)
            rel = os.path.relpath(full, root)
            if not admitted(rel):
                continue
            real = os.path.realpath(full)
            if os.path.commonpath([real, root]) != root or not os.path.isfile(real):
                raise ValueError(f"tuning entry leaves its folder: {rel}")
            data = open(real, "rb").read()
            total += len(data)
            if len(files) >= MAX_FILES or total > MAX_BYTES:
                raise ValueError("tuning folder over budget")
            files[rel] = data
    return files


def manifest(aid, acoustic, files, spts, build, selection=None):
    selection = selection or {}
    return {
        "schema": 1,
        "kind": "aurora-audio-tuning",
        "acoustic_id": acoustic,
        "aid": aid,
        "macos_build": build,
        "speaker_thiele_small": None if spts is None else {
            "path": SPTS, "bytes": len(spts), "sha256": hashlib.sha256(spts).hexdigest()},
        "device_dsp_database": DATABASE if DATABASE in selection else None,
        "config": config_name(acoustic) if config_name(acoustic) in selection else None,
        "files": [{"path": f"{aid}/{rel}", "bytes": len(files[rel]),
                   "sha256": hashlib.sha256(files[rel]).hexdigest()}
                  for rel in sorted(files)]
                 + [{"path": name, "bytes": len(selection[name]),
                     "sha256": hashlib.sha256(selection[name]).hexdigest()}
                    for name in sorted(selection)],
        "based_on": BASED_ON,
    }


def tree(acoustic, files, spts, build, selection=None):
    """Relative path -> bytes for one bundle: AID<n>/..., the selection
    data, the record, the manifest."""
    selection = selection or {}
    for name in selection:
        if name not in (DATABASE, config_name(acoustic)):
            raise ValueError(f"unexpected selection file {name!r}")
    if not files or len(files) > MAX_FILES:
        raise ValueError("empty or oversized tuning folder")
    if spts is not None and not 0 < len(spts) <= 4096:
        raise ValueError("implausible speaker-thiele-small")
    aid = f"AID{acoustic}"
    out = {}
    for rel, data in files.items():
        if not admitted(rel):
            raise ValueError(f"inadmissible tuning path {rel!r}")
        out[f"{aid}/{rel}"] = data
    out.update(selection)
    if spts is not None:
        out[SPTS] = spts
    out[MANIFEST] = json.dumps(manifest(aid, acoustic, files, spts, build, selection),
                               indent=2, sort_keys=True).encode("utf-8")
    return out


def os_build(run=subprocess.run):
    p = run(["sysctl", "-n", "kern.osversion"], capture_output=True)
    value = p.stdout.decode("ascii", "replace").strip() if p.returncode == 0 else ""
    return value if value.isalnum() and len(value) <= 16 else "unknown"


class AudioTuningFWCollection(object):
    """Live collection on macOS (path None), or re-collection from an
    extracted fallback archive (path = the directory holding audio-tuning/)."""

    def __init__(self, path=None, tunings_root=TUNINGS_ROOT, run=subprocess.run):
        self.fwfiles = []
        self.bundle = {}
        try:
            if path is None:
                self.load(tunings_root, run)
            else:
                self.update(os.path.join(path, FALLBACK_DIR))
        except Exception as e:
            log.warning(f"Speaker tuning not collected: {e}")
            self.fwfiles = []
            self.bundle = {}

    def files(self):
        return self.fwfiles

    def _publish(self, bundle):
        self.bundle = bundle
        self.fwfiles = [(PACKAGE_PREFIX + rel, FWFile(PACKAGE_PREFIX + rel, data))
                        for rel, data in sorted(bundle.items())]

    def load(self, tunings_root, run):
        props = probe(run)
        if props is None:
            log.info("No device-tree acoustic-id; no speaker tuning to collect")
            return
        acoustic = acoustic_id(props[0])
        if acoustic is None:
            raise ValueError("malformed acoustic-id")
        folder = os.path.join(tunings_root, f"AID{acoustic}")
        if not os.path.isdir(folder):
            log.info(f"No tuning folder {folder}")
            return
        files = read_folder(folder)
        selection = {}
        db_path = os.path.join(tunings_root, DATABASE)
        if os.path.isfile(db_path):
            entry = database_entry(open(db_path, "rb").read(), acoustic)
            if entry is not None:
                selection[DATABASE] = entry
        cfg_path = os.path.join(tunings_root, config_name(acoustic))
        if os.path.isfile(cfg_path):
            selection[config_name(acoustic)] = open(cfg_path, "rb").read()
        self._publish(tree(acoustic, files, props[1], os_build(run), selection))
        log.info(f"  Collected speaker tuning AID{acoustic} ({len(files)} files)")

    def update(self, path):
        meta_path = os.path.join(path, MANIFEST)
        if not os.path.exists(meta_path):
            return
        meta = json.load(open(meta_path))
        if meta.get("schema") != 1 or meta.get("kind") != "aurora-audio-tuning":
            raise ValueError("unknown speaker tuning manifest")
        bundle = {}
        records = list(meta["files"])
        if meta.get("speaker_thiele_small"):
            records.append(meta["speaker_thiele_small"])
        for rec in records:
            rel = rec["path"]
            if not admitted(rel):
                raise ValueError(f"inadmissible tuning path {rel!r}")
            data = open(os.path.join(path, rel), "rb").read()
            if len(data) != rec["bytes"] or hashlib.sha256(data).hexdigest() != rec["sha256"]:
                raise ValueError(f"tuning file changed: {rel}")
            bundle[rel] = data
        bundle[MANIFEST] = open(meta_path, "rb").read()
        self._publish(bundle)

    def write_fallback(self, directory):
        """Write audio-tuning/ for the raw fallback archive under directory."""
        for rel, data in self.bundle.items():
            dest = os.path.join(directory, FALLBACK_DIR, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            with open(dest, "wb") as fd:
                fd.write(data)
        return bool(self.bundle)
