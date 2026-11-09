import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "local_payload_policy", ROOT / "Packaging/check-local-payload-policy.py")
POLICY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(POLICY)


class LocalPayloadPackagingPolicyTests(unittest.TestCase):
    def test_release_rejects_marker_in_app_or_helper(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, binary, helper = self.application(Path(temporary))
            POLICY.check(app, "disabled")
            for path in (binary, helper):
                path.write_bytes(POLICY.MARKER)
                with self.assertRaisesRegex(ValueError, "release application"):
                    POLICY.check(app, "disabled")
                path.write_bytes(b"release binary")

    def test_test_build_requires_compiled_source_developer_identity_and_seal(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, binary, _ = self.application(Path(temporary))
            with self.assertRaises(ValueError):
                POLICY.check(app, "enabled")
            binary.write_bytes(POLICY.MARKER)
            with self.assertRaises(ValueError):
                POLICY.check(app, "enabled")
            info = app / "Contents/Info.plist"
            value = plistlib.loads(info.read_bytes())
            value["AuroraDeveloperBuild"] = True
            info.write_bytes(plistlib.dumps(value))
            with self.assertRaisesRegex(ValueError, "seal"):
                POLICY.check(app, "enabled")
            release = app / "Contents/Resources/Release"
            release.mkdir(parents=True)
            for name in ("catalog.json", "catalog.json.sig"):
                (release / name).write_bytes(b"sealed fixture")
            POLICY.check(app, "enabled")

    @staticmethod
    def application(root):
        app = root / "Fixture.app"
        binary = app / "Contents/MacOS/Fixture"
        helper = app / "Contents/Library/LaunchServices/helper"
        for path in (binary, helper):
            path.parent.mkdir(parents=True)
            path.write_bytes(b"release binary")
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Fixture"}))
        return app, binary, helper
