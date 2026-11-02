#!/usr/bin/env python3
"""Public synthetic OTA update-archive vectors for the native stub stage.

The archive has the layout of Apple's macOS 14.8.3 update archive for the
M3 Macs: restore files under AssetData/boot and AssetData/Restore, an update
identity, and a Recovery image stored as a BXDIFF50 patch with no control
data whose output is one PBZX stream of XZ and stored chunks.
"""
import argparse
import base64
import hashlib
import io
import json
import lzma
import plistlib
import struct
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Tests/AuroraAppleInstallerTrustCoreTests/Fixtures/native-update-archive.json"

CHUNK = 4096
XZ_INPUT = (b"Aurora update archive recovery chunk " * 200)[:CHUNK]
# One XZ stream with no integrity check, as Apple's PBZX chunks have. The
# bytes are fixed so that the vectors don't depend on the local liblzma.
XZ_CHUNK = bytes.fromhex(
    "fd377a585a000000ff12d9410200210116000000742fe5a3e00fff003f5d00209d4a4711"
    "8d8debbaf4130889b5a88123f5047ee1cb7372b1a07afee112c76903843aef3d5323a596"
    "b3a291464f8da184648ddeae636f1157c4a6a9d57c000000000153802000000028b19b58"
    "a8000afc020000000000595a"
)
RECOVERY_MEMBER = "AssetData/payloadv2/basesystem_patches/arm64eBaseSystem.dmg"
BOOTABILITY = "AssetData/Restore/BootabilityBundle/"
FRAMEWORK = BOOTABILITY + "Restore/Bootability/BootabilityBrain.framework/"


def recovery_image(stored=CHUNK, trailer=b"koly"):
    """An image of an XZ chunk, a stored chunk and a short stored tail."""
    tail = b"i" * 512 + trailer + bytes(508)
    body = b"r" * stored
    return XZ_INPUT + body + tail, [(XZ_INPUT, XZ_CHUNK), (body, None), (tail, None)]


def patch_stream(image, chunks, control=0, corrupt=False):
    size = max(len(output) for output, _ in chunks)
    stream = bytearray(b"pbzx" + struct.pack(">Q", size))
    for output, stored in chunks:
        body = stored if stored is not None else output
        if corrupt and stored is None and output.startswith(b"r"):
            body = b"R" + body[1:]
        stream += struct.pack(">QQ", len(output), len(body)) + body
    header = b"BXDIFF50" + bytes(8) + struct.pack("<3Q", len(image), control, len(stream))
    return header + hashlib.sha1(image).digest() + bytes(stream)


def manifest(base_system=True):
    def identity(board, device, behavior, variant, components):
        return dict(
            ApBoardID=board,
            ApChipID="0x8122",
            Info=dict(
                BuildNumber="23J220", DeviceClass=device, RestoreBehavior=behavior, Variant=variant
            ),
            Manifest={key: dict(Info=info) for key, info in components.items()},
        )

    # BaseSystem, OS and RestoreRamDisk name files outside AssetData/boot,
    # as in Apple's archive; the stub copies none of them.
    update = {
        "BaseSystem": dict(Path="../Restore/022-20791-031.dmg"),
        "KernelCache": dict(Path="kernelcache.release.mac15g"),
        "iBoot": dict(Path="Firmware/all_flash/iBoot.j613.RELEASE.im4p", IsLoadedByiBoot=True),
        "AOP": dict(Path="Firmware/AOP/aopfw.im4p", IsFUDFirmware=True),
        "RestoreRamDisk": dict(Path="../usr/standalone/update/ramdisk/arm64eSURamDisk.dmg"),
        "OS": dict(Path="../Restore/094-04655-023.dmg"),
        "Cryptex1,SystemOS": dict(Path="excluded-cryptex.dmg"),
    }
    if not base_system:
        del update["BaseSystem"]
    selected = identity("0x30", "j613ap", "Update", "macOS Customer Software Update", update)
    erase = identity(
        "0x30", "j613ap", "Erase", "macOS Customer", {"KernelCache": dict(Path="decoy.im4p")}
    )
    other = identity("0x32", "j615ap", "Update", "macOS Customer Software Update", update)
    return dict(BuildIdentities=[erase, other, selected]), selected


def archive(recovery_member, bootability=True, base_system=True):
    document, _ = manifest(base_system)
    version = dict(
        ProductVersion="14.8.3", ProductUserVisibleVersion="14.8.3", ProductBuildVersion="23J220"
    )
    files = {
        "META-INF/com.apple.ZipMetadata.plist": plistlib.dumps(dict(TotalUncompressedBytes=0)),
        "AssetData/Info.plist": plistlib.dumps(dict(Build="23J220")),
        "AssetData/boot/BuildManifest.plist": plistlib.dumps(document),
        "AssetData/boot/SystemVersion.plist": plistlib.dumps(version),
        "AssetData/boot/RestoreVersion.plist": plistlib.dumps(dict(RestoreLongVersion="23J220")),
        "AssetData/boot/PlatformSupport.plist": plistlib.dumps(dict(SupportedModelProperties=[])),
        "AssetData/boot/usr/standalone/bootcaches.plist": plistlib.dumps(dict(bless2={})),
        "AssetData/boot/Firmware/Manifests/restore/macOS Customer Software Update/"
        "apticket.j613ap.im4m": b"update restore manifest",
        "AssetData/boot/Firmware/Manifests/restore/macOS Customer/decoy.im4m": b"erase manifest",
        "AssetData/boot/kernelcache.release.mac15g": b"synthetic update kernel",
        "AssetData/boot/Firmware/all_flash/iBoot.j613.RELEASE.im4p": b"synthetic iboot",
        "AssetData/boot/Firmware/AOP/aopfw.im4p": b"synthetic aop firmware",
        "AssetData/Restore/BaseSystem.chunklist": b"chunklist",
        "AssetData/Restore/BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache":
            b"update trust cache",
        FRAMEWORK + "Versions/A/BootabilityBrain": b"synthetic bootability brain",
        FRAMEWORK + "Versions/A/Resources/Info.plist": b"synthetic resource",
        RECOVERY_MEMBER: recovery_member,
    }
    links = {
        FRAMEWORK + "BootabilityBrain": b"Versions/Current/BootabilityBrain",
        FRAMEWORK + "Resources": b"Versions/Current/Resources",
        FRAMEWORK + "Versions/Current": b"A",
    }
    files.update(links)
    if recovery_member is None:
        del files[RECOVERY_MEMBER]
    if not bootability:
        for name in [name for name in files if name.startswith(BOOTABILITY)]:
            del files[name]
        links = {}
    directories = sorted(
        {"/".join(name.split("/")[: index + 1]) + "/" for name in files for index in range(2)
         if name.count("/") > index}
    )
    output = io.BytesIO()
    with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_STORED) as z:
        for name in directories:
            member = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            member.external_attr = (0o040755 << 16) | 0x10
            z.writestr(member, b"")
        for name, data in sorted(files.items()):
            member = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
            member.compress_type = zipfile.ZIP_STORED
            member.external_attr = (0o120755 if name in links else 0o100644) << 16
            z.writestr(member, data)
    return output.getvalue()


def vectors():
    # The full image's stored chunk is cached as a range of its own: 64 KiB
    # or more.
    image, chunks = recovery_image(stored=96 * 1024)
    small, small_chunks = recovery_image()
    unmarked, unmarked_chunks = recovery_image(trailer=b"none")
    assert lzma.decompress(XZ_CHUNK) == XZ_INPUT

    def encoded(data):
        return base64.b64encode(data).decode()

    _, selected = manifest()
    delta = patch_stream(small, small_chunks, control=1)
    result = [
        dict(name="full", archive=encoded(archive(patch_stream(image, chunks)))),
        dict(name="delta", archive=encoded(archive(delta))),
        # Update archives that can't build a stub, each missing more than the
        # whole Recovery image.
        dict(name="no-image", archive=encoded(archive(None, bootability=False))),
        dict(
            name="delta-incomplete",
            archive=encoded(archive(delta, bootability=False, base_system=False)),
        ),
        dict(
            name="corrupt",
            archive=encoded(archive(patch_stream(small, small_chunks, corrupt=True))),
        ),
        dict(name="no-trailer", archive=encoded(archive(patch_stream(unmarked, unmarked_chunks)))),
    ]
    return dict(
        vectors=result,
        expectedManifest=base64.b64encode(
            plistlib.dumps(dict(BuildIdentities=[selected]))
        ).decode(),
        recoveryBytes=len(image),
        recoverySHA256=hashlib.sha256(image).hexdigest(),
        recoverySHA1=hashlib.sha1(image).hexdigest(),
        xzChunk=base64.b64encode(XZ_CHUNK).decode(),
        xzInput=base64.b64encode(XZ_INPUT).decode(),
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true")
    arguments = parser.parse_args()
    encoded = json.dumps(vectors(), sort_keys=True, separators=(",", ":")) + "\n"
    if arguments.write:
        OUTPUT.write_text(encoded)
    elif OUTPUT.read_text() != encoded:
        raise SystemExit("stale native update-archive vectors")
    print("Verified native update-archive vectors")


if __name__ == "__main__":
    main()
