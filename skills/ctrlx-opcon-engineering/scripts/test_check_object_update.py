import importlib.util
import pathlib
import tempfile
import unittest


HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("object_update", HERE / "check_object_update.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
OOID = "A83E0FBB-E37E-5713-A576-7181D60D3234"
OTHER = "DB1D3145-F4C9-4F63-923F-433A5042D360"


class UpdatePlanChecks(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        self.ood = self.root / "Component.ood"
        self.ood.write_text(f'<Object refId="{OOID}" objectName="Fixture" version="0.1.2.6"/>')
        library = self.root / "Library"
        library.mkdir()
        self.descriptor = library / "Library.osd"
        self.descriptor.write_text('<OpconStdDefinition><PlcContentDef><Library version="0.1.1.1" file="Fixture.compiled-library"/></PlcContentDef></OpconStdDefinition>')
        self.native = library / "Fixture.compiled-library"
        self.native.write_bytes(b"fixture only")
        self.before = self.root / "before.xml"
        self.after = self.root / "after.xml"
        self.write_versions(self.before, "0.1.2.5")

    def tearDown(self):
        self.temp.cleanup()

    def write_versions(self, path, target, other="1.0.2.2"):
        path.write_text(f'<ObjectVersions><Object ooid="{OOID}" name="Fixture" version="{target}"/><Object ooid="{OTHER}" name="Other" version="{other}"/></ObjectVersions>')

    def inspect(self, **overrides):
        args = dict(ood=self.ood, versions=self.before, target_version="0.1.2.6",
                    expected_current="0.1.2.5", library_version="0.1.1.1")
        args.update(overrides)
        return checker.inspect(**args)

    def test_ood_and_library_versions_remain_distinct(self):
        original = {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        result = self.inspect()
        self.assertEqual(result["object"]["targetVersion"], "0.1.2.6")
        self.assertEqual(result["library"]["version"], "0.1.1.1")
        self.assertFalse(result["nativeReloadVerified"])
        self.assertEqual(original, {p: p.read_bytes() for p in self.root.rglob("*") if p.is_file()})

    def test_latest_and_version_family_are_rejected(self):
        for value in ("latest", "0.1", "0.1.*"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                self.inspect(target_version=value)

    def test_wrong_source_target_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Source OOD"):
            self.inspect(target_version="0.1.2.7")

    def test_current_version_drift_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "Current saved"):
            self.inspect(expected_current="0.1.2.4")

    def test_wrong_library_version_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "PLC library version"):
            self.inspect(library_version="0.1.2.6")

    def test_missing_native_library_is_rejected(self):
        self.native.unlink()
        with self.assertRaisesRegex(ValueError, "file is missing"):
            self.inspect()

    def test_missing_target_is_not_silently_installed(self):
        self.before.write_text("<ObjectVersions/>")
        with self.assertRaisesRegex(ValueError, "component-install"):
            self.inspect()

    def test_exact_saved_migration_is_accepted_without_claiming_native_reload(self):
        self.write_versions(self.after, "0.1.2.6")
        result = self.inspect(after_versions=self.after)
        self.assertTrue(result["savedSelectionVerified"])
        self.assertFalse(result["nativeReloadVerified"])

    def test_unplanned_dependency_change_is_rejected(self):
        self.write_versions(self.after, "0.1.2.6", "1.0.2.3")
        with self.assertRaisesRegex(ValueError, "unplanned"):
            self.inspect(after_versions=self.after)

    def test_stale_saved_target_is_rejected(self):
        self.write_versions(self.after, "0.1.2.5")
        with self.assertRaisesRegex(ValueError, "wrong target"):
            self.inspect(after_versions=self.after)


if __name__ == "__main__":
    unittest.main()
