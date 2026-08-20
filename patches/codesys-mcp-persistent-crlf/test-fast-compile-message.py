"""Offline regression tests for the bounded ctrlX compile-message helper."""

from __future__ import print_function

import argparse
import os


BUILD_GUID = "97f48d64-a2a3-4856-b640-75c046e37ea9"
ADDITIONAL_GUID = "220493a1-f49b-4416-9a3f-a545db707cbe"


class StubSystem(object):
    def __init__(self, build_rows, additional_rows=None):
        self.build_rows = list(build_rows)
        self.additional_rows = list(additional_rows or [])

    def get_messages(self, category):
        value = str(category).lower()
        if BUILD_GUID in value:
            return list(self.build_rows)
        if ADDITIONAL_GUID in value:
            return list(self.additional_rows)
        return []


class StubScriptEngine(object):
    def __init__(self, system):
        self.system = system

    @staticmethod
    def Guid(value):
        return value


def load_helper(path, build_rows, additional_rows=None):
    namespace = {
        "__name__": "patched_message_utils",
        "basestring": str,
        "unicode": str,
        "_to_unicode": lambda value: str(value),
        "script_engine": StubScriptEngine(StubSystem(build_rows, additional_rows)),
    }
    with open(path, "r", encoding="utf-8") as handle:
        source = handle.read()
    exec(compile(source, path, "exec"), namespace)
    return namespace


def assert_counts(namespace, errors, warnings, verified=True):
    snapshot = namespace["msg_fast_compile_snapshot"]()
    assert snapshot["verified"] is verified, snapshot
    assert snapshot["errorCount"] == errors, snapshot
    assert snapshot["warningCount"] == warnings, snapshot
    entries = namespace["msg_fast_structured_entries"](snapshot)
    actual_errors = len([entry for entry in entries if entry["severity"] == "error"])
    actual_warnings = len([entry for entry in entries if entry["severity"] == "warning"])
    assert actual_errors == errors, entries
    assert actual_warnings == warnings, entries
    return snapshot, entries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("message_utils", help="Patched _message_utils.py path")
    args = parser.parse_args()
    path = os.path.abspath(args.message_utils)

    clean = load_helper(
        path,
        ["Generate code...", "Build complete -- 0 errors, 7 warnings : Ready for download"]
        + ["Warning detail %d" % index for index in range(1, 8)],
    )
    _, clean_entries = assert_counts(clean, 0, 7)
    assert clean_entries[0]["text"] == "Warning detail 1", clean_entries

    failed = load_helper(
        path,
        [
            "Build complete -- 2 errors, 1 warnings : No download possible",
            "C0004: Missing member A",
            "C0018: Unknown identifier B",
        ],
    )
    _, failed_entries = assert_counts(failed, 2, 1)
    assert "C0004: Missing member A" in failed_entries[0]["text"], failed_entries

    current = load_helper(path, ["Application is current"])
    assert_counts(current, 0, 0)

    dual_summary = load_helper(
        path,
        [
            "Compile complete -- 503 errors, 411 warnings",
            "Build complete -- 2 errors, 0 warnings : No download possible",
        ],
    )
    dual_snapshot, _ = assert_counts(dual_summary, 503, 411)
    assert dual_snapshot["categoryResults"][0]["summarySource"] == "Compile complete", dual_snapshot

    unknown = load_helper(path, ["Generate code..."])
    snapshot = unknown["msg_fast_compile_snapshot"]()
    entries = unknown["msg_fast_structured_entries"](snapshot)
    assert snapshot["verified"] is False, snapshot
    assert len(entries) == 1 and entries[0]["severity"] == "error", entries

    print("fast compile message regression: OK")


if __name__ == "__main__":
    main()
