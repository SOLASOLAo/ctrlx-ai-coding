import tempfile
from pathlib import Path
import unittest

from create_library_example import EXAMPLES, EXAMPLE_ROOT, create_example


class ExampleCopyTests(unittest.TestCase):
    def test_each_example_is_copied_without_runtime_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            for name in EXAMPLES:
                target = Path(temporary) / name
                files = create_example(name, target)
                self.assertIn("README.md", files)
                self.assertTrue(any(path.endswith(".st") for path in files))
                for relative in files:
                    self.assertEqual((target / relative).read_bytes(), (EXAMPLE_ROOT / name / relative).read_bytes())
                self.assertFalse(any(target.rglob("*.pyc")))

    def test_preview_does_not_create_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "preview"
            self.assertTrue(create_example("inntai", target, preview=True))
            self.assertFalse(target.exists())

    def test_existing_work_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary)
            original = target / "user.st"
            original.write_text("user code", encoding="utf-8")
            with self.assertRaises(ValueError):
                create_example("machinecommon", target)
            self.assertEqual(list(target.iterdir()), [original])
            self.assertEqual(original.read_text(encoding="utf-8"), "user code")

    def test_source_overlap_is_refused(self):
        with self.assertRaises(ValueError):
            create_example("ind360", EXAMPLE_ROOT / "ind360" / "nested", preview=True)


if __name__ == "__main__":
    unittest.main()
