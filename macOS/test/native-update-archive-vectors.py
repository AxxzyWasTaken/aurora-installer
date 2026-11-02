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
FRAMEWORK = "AssetData/Restore/BootabilityBundle/Restore/Bootability/BootabilityBrain.framework/"


def recovery_image():
    tail = b"i" * 512 + b"koly" + bytes(508)
    return XZ_INPUT + b"r" * CHUNK + tail, [(XZ_INPUT, XZ_CHUNK), (b"r" * CHUNK, None), (tail, None)]


def patch_stream(image, chunks, control=0, corrupt=False):
    stream = bytearray(b"pbzx" + struct.pack(">Q", CHUNK))
    for output, stored in chunks:
        body = stored if stored is not None else output
        if corrupt and stored is None and output.startswith(b"r"):
            body = b"R" + body[1:]
        stream += struct.pack(">QQ", len(output), len(body)) + body
    header = b"BXDIFF50" + bytes(8) + struct.pack("<3Q", len(image), control, len(stream))
    return header + hashlib.sha1(image).digest() + bytes(stream)


def manifest():
    def identity(board, device, behavior, variant, components):
        return dict(
            ApBoardID=board,
            ApChipID="0x8122",
            Info=dict(
                BuildNumber="23J220", DeviceClass=device, RestoreBehavior=behavior, Variant=variant
            ),
            Manifest={key: dict(Info=info) for key, info in components.items()},
        )

    update = {
        "BaseSystem": dict(Path="../Restore/022-00000-000.dmg"),
        "KernelCache": dict(Path="kernelcache.release.mac15g"),
        "iBoot": dict(Path="Firmware/all_flash/iBoot.j613.RELEASE.im4p", IsLoadedByiBoot=True),
        "AOP": dict(Path="Firmware/AOP/aopfw.im4p", IsFUDFirmware=True),
        "RestoreRamDisk": dict(Path="excluded-ramdisk.dmg"),
        "OS": dict(Path="excluded-os.dmg"),
        "Cryptex1,SystemOS": dict(Path="excluded-cryptex.dmg"),
    }
    selected = identity("0x30", "j613ap", "Update", "macOS Customer Software Update", update)
    erase = identity(
        "0x30", "j613ap", "Erase", "macOS Customer", {"KernelCache": dict(Path="decoy.im4p")}
    )
    other = identity("0x32", "j615ap", "Update", "macOS Customer Software Update", update)
    return dict(BuildIdentities=[erase, other, selected]), selected


def archive(recovery_member):
    document, _ = manifest()
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
    image, chunks = recovery_image()
    assert lzma.decompress(XZ_CHUNK) == XZ_INPUT
    _, selected = manifest()
    result = [
        dict(name="full", archive=base64.b64encode(archive(patch_stream(image, chunks))).decode()),
        dict(
            name="delta",
            archive=base64.b64encode(archive(patch_stream(image, chunks, control=1))).decode(),
        ),
        dict(
            name="corrupt",
            archive=base64.b64encode(archive(patch_stream(image, chunks, corrupt=True))).decode(),
        ),
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
