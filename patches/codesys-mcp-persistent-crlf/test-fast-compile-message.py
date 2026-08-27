"""Offline regression tests for the bounded ctrlX compile-message helper."""

from __future__ import print_function

import argparse
import os
import re


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


def fresh_summary_sources(compile_project_path):
    """Read the actual fresh-v2 allow-list from the patched compile script."""
    with open(compile_project_path, "r", encoding="utf-8") as handle:
        source = handle.read()
    marker = "ctrlX explicit Build summary only (2026-08-27)"
    assert marker in source, "strict Build-summary marker missing"
    match = re.search(
        r"explicit_build_summary\s*=\s*\(\s*"
        r"build_category_result\.get\('summarySource'\)\s+in\s*"
        r"\((.*?)\)\s+and",
        source,
        re.DOTALL,
    )
    assert match is not None, "fresh-v2 explicit-summary allow-list not found"
    return tuple(re.findall(r"'([^']+)'", match.group(1)))


def isolated_fresh_v2_flags(snapshot, entries, allowed_sources):
    """Isolate the summary gate while all other fresh-v2 facts are true."""
    build_result = snapshot["categoryResults"][0]
    explicit_summary = (
        build_result["summarySource"] in allowed_sources
        and build_result["errors"] is not None
        and build_result["warnings"] is not None
    )
    patch_preflight = explicit_summary
    fresh = patch_preflight and snapshot["verified"] is True
    records_complete = (
        fresh
        and snapshot["errorCount"] + snapshot["warningCount"] == 0
        and len(entries) == 0
    )
    return fresh, patch_preflight, records_complete


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("message_utils", help="Patched _message_utils.py path")
    parser.add_argument("compile_project", help="Patched compile_project.py path")
    args = parser.parse_args()
    path = os.path.abspath(args.message_utils)
    compile_project_path = os.path.abspath(args.compile_project)
    allowed_fresh_sources = fresh_summary_sources(compile_project_path)
    assert allowed_fresh_sources == ("Compile complete", "Build complete"), allowed_fresh_sources

    explicit_zero = load_helper(
        path,
        ["Build complete -- 0 errors, 0 warnings : Ready for download"],
    )
    explicit_zero_snapshot, explicit_zero_entries = assert_counts(explicit_zero, 0, 0)
    assert isolated_fresh_v2_flags(
        explicit_zero_snapshot,
        explicit_zero_entries,
        allowed_fresh_sources,
    ) == (True, True, True)

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

    # The bounded helper may retain a generic numeric row for diagnostics, but
    # fresh-v2 must never treat that unrelated 0/0 as same-call Build evidence.
    unrelated = load_helper(
        path,
        ["Unrelated maintenance task finished: 0 errors, 0 warnings"],
    )
    unrelated_snapshot, unrelated_entries = assert_counts(unrelated, 0, 0)
    unrelated_source = unrelated_snapshot["categoryResults"][0]["summarySource"]
    assert unrelated_source == "Other summary", unrelated_snapshot
    assert unrelated_source not in allowed_fresh_sources, unrelated_snapshot
    assert isolated_fresh_v2_flags(
        unrelated_snapshot,
        unrelated_entries,
        allowed_fresh_sources,
    ) == (False, False, False)

    unknown = load_helper(path, ["Generate code..."])
    snapshot = unknown["msg_fast_compile_snapshot"]()
    entries = unknown["msg_fast_structured_entries"](snapshot)
    assert snapshot["verified"] is False, snapshot
    assert len(entries) == 1 and entries[0]["severity"] == "error", entries

    print("fast compile message + strict fresh-v2 regression: OK")


if __name__ == "__main__":
    main()
