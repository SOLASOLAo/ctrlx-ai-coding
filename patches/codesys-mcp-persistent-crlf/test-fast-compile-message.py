"""Offline regression tests for the bounded ctrlX compile-message helper."""

from __future__ import print_function

import argparse
import os
import re
import textwrap


BUILD_GUID = "97f48d64-a2a3-4856-b640-75c046e37ea9"
ADDITIONAL_GUID = "220493a1-f49b-4416-9a3f-a545db707cbe"


class StubSystem(object):
    def __init__(
        self,
        build_rows,
        additional_rows=None,
        build_warning_objects=None,
        additional_warning_objects=None,
        warning_exception_category=None,
    ):
        self.build_rows = list(build_rows)
        self.additional_rows = list(additional_rows or [])
        self.build_warning_objects = list(build_warning_objects or [])
        self.additional_warning_objects = list(additional_warning_objects or [])
        self.warning_exception_category = warning_exception_category
        self.warning_calls = []

    def get_messages(self, category):
        value = str(category).lower()
        if BUILD_GUID in value:
            return list(self.build_rows)
        if ADDITIONAL_GUID in value:
            return list(self.additional_rows)
        return []

    def get_message_objects(self, category, severity):
        value = str(category).lower()
        category_name = None
        rows = []
        if BUILD_GUID in value:
            category_name = "Build"
            rows = self.build_warning_objects
        elif ADDITIONAL_GUID in value:
            category_name = "Additional code checks"
            rows = self.additional_warning_objects
        self.warning_calls.append((category_name, str(severity)))
        if category_name == self.warning_exception_category:
            raise RuntimeError("synthetic warning query failure")
        return list(rows)


class StubMessage(object):
    def __init__(self, text, severity="Warning"):
        self.text = text
        self.severity = severity


class StubSeverity(object):
    Warning = "Warning"


class StubScriptEngine(object):
    Severity = StubSeverity

    def __init__(self, system):
        self.system = system

    @staticmethod
    def Guid(value):
        return value


def load_helper(
    path,
    build_rows,
    additional_rows=None,
    build_warning_objects=None,
    additional_warning_objects=None,
    warning_exception_category=None,
):
    stub_system = StubSystem(
        build_rows,
        additional_rows,
        build_warning_objects,
        additional_warning_objects,
        warning_exception_category,
    )
    namespace = {
        "__name__": "patched_message_utils",
        "basestring": str,
        "unicode": str,
        "_to_unicode": lambda value: str(value),
        "script_engine": StubScriptEngine(stub_system),
        "_stub_system": stub_system,
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


def isolated_fresh_v2_flags(snapshot, allowed_sources):
    """Isolate the summary gate while all other fresh-v2 facts are true."""
    build_result = snapshot["categoryResults"][0]
    explicit_summary = (
        build_result["summarySource"] in allowed_sources
        and build_result["errors"] is not None
        and build_result["warnings"] is not None
    )
    patch_preflight = explicit_summary
    fresh = patch_preflight and snapshot["verified"] is True
    return fresh, patch_preflight


def prepare_typed(namespace, fresh, errors, warnings, diagnostics=None, complete=True):
    categories = namespace["msg_fast_compile_categories"]()
    return namespace["msg_fast_prepare_typed_warning_records"](
        fresh,
        errors,
        warnings,
        categories,
        list(diagnostics or []),
        complete,
    )


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
        allowed_fresh_sources,
    ) == (True, True)
    explicit_zero_typed = prepare_typed(explicit_zero, True, 0, 0)
    assert explicit_zero_typed["typedRecordsVerified"] is True, explicit_zero_typed
    assert explicit_zero_typed["records"] == [], explicit_zero_typed
    assert explicit_zero["_stub_system"].warning_calls == [], explicit_zero_typed

    clean = load_helper(
        path,
        ["Generate code...", "Build complete -- 0 errors, 7 warnings : Ready for download"]
        + ["Warning detail %d" % index for index in range(1, 8)],
    )
    clean_snapshot, clean_entries = assert_counts(clean, 0, 7)
    assert clean_entries[0]["text"] == "Warning detail 1", clean_entries
    assert clean_snapshot["diagnosticRows"][0] == "[Build] Warning detail 1", clean_snapshot
    assert clean_snapshot["diagnosticRowsComplete"] is True, clean_snapshot
    assert isolated_fresh_v2_flags(
        clean_snapshot,
        allowed_fresh_sources,
    ) == (True, True)
    clean_untyped = prepare_typed(
        clean,
        True,
        0,
        7,
        clean_snapshot["diagnosticRows"],
        clean_snapshot["diagnosticRowsComplete"],
    )
    assert clean_untyped["typedRecordsVerified"] is False, clean_untyped
    assert clean_untyped["warningCollectionReason"] == "WARNING_OBJECT_COUNT_MISMATCH", clean_untyped
    assert clean_untyped["diagnosticRows"] == clean_snapshot["diagnosticRows"], clean_untyped

    failed = load_helper(
        path,
        [
            "Build complete -- 2 errors, 1 warnings : No download possible",
            "C0004: Missing member A",
            "C0018: Unknown identifier B",
        ],
    )
    failed_snapshot, failed_entries = assert_counts(failed, 2, 1)
    assert "C0004: Missing member A" in failed_entries[0]["text"], failed_entries
    assert isolated_fresh_v2_flags(
        failed_snapshot,
        allowed_fresh_sources,
    ) == (True, True)
    failed_typed = prepare_typed(failed, True, 2, 1, failed_snapshot["diagnosticRows"])
    assert failed_typed["typedRecordsVerified"] is False, failed_typed
    assert failed_typed["warningCollectionReason"] == "WARNING_COLLECTION_ERRORS_PRESENT", failed_typed
    assert failed["_stub_system"].warning_calls == [], failed_typed

    ambiguous = load_helper(
        path,
        [
            "Build complete -- 0 errors, 1 warnings : Ready for download",
            "Warning detail",
            "Unclassified informational row",
        ],
    )
    ambiguous_snapshot, ambiguous_entries = assert_counts(ambiguous, 0, 1)
    assert ambiguous_snapshot["detailCount"] == 2, ambiguous_snapshot
    assert ambiguous_snapshot["diagnosticRowsComplete"] is True, ambiguous_snapshot
    assert isolated_fresh_v2_flags(
        ambiguous_snapshot,
        allowed_fresh_sources,
    ) == (True, True)

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
        allowed_fresh_sources,
    ) == (False, False)

    exact = load_helper(
        path,
        ["Build complete -- 0 errors, 3 warnings : Ready for download"],
        build_warning_objects=[
            StubMessage("First warning"),
            StubMessage("第二条警告 😀\ncontinued"),
        ],
        additional_warning_objects=[StubMessage("Additional check warning")],
    )
    exact_typed = prepare_typed(exact, True, 0, 3, ["old untyped row"])
    assert exact_typed["typedRecordsVerified"] is True, exact_typed
    assert exact_typed["messageCount"] == 3, exact_typed
    assert exact_typed["warningQueryCount"] == 2, exact_typed
    assert exact_typed["warningObjectCount"] == 3, exact_typed
    assert exact_typed["records"] == [
        {"severity": "warning", "text": "First warning"},
        {"severity": "warning", "text": "第二条警告 😀 continued"},
        {"severity": "warning", "text": "Additional check warning"},
    ], exact_typed
    assert exact_typed["diagnosticRows"] == [
        "First warning",
        "第二条警告 😀 continued",
        "Additional check warning",
    ], exact_typed
    assert exact["_stub_system"].warning_calls == [
        ("Build", "Warning"),
        ("Additional code checks", "Warning"),
    ], exact["_stub_system"].warning_calls

    mismatch = load_helper(
        path,
        [],
        build_warning_objects=[StubMessage("only one")],
    )
    mismatch_typed = prepare_typed(mismatch, True, 0, 2, ["bounded diagnostic"])
    assert mismatch_typed["typedRecordsVerified"] is False, mismatch_typed
    assert mismatch_typed["records"] == [], mismatch_typed
    assert mismatch_typed["diagnosticRows"] == ["bounded diagnostic"], mismatch_typed
    assert mismatch_typed["warningCollectionReason"] == "WARNING_OBJECT_COUNT_MISMATCH", mismatch_typed

    query_failure = load_helper(
        path,
        [],
        build_warning_objects=[StubMessage("one")],
        warning_exception_category="Additional code checks",
    )
    query_failure_typed = prepare_typed(query_failure, True, 0, 1, ["bounded diagnostic"])
    assert query_failure_typed["typedRecordsVerified"] is False, query_failure_typed
    assert query_failure_typed["records"] == [], query_failure_typed
    assert query_failure_typed["warningCollectionReason"] == "WARNING_QUERY_FAILED", query_failure_typed

    sensitive = load_helper(
        path,
        [],
        build_warning_objects=[StubMessage("credential password=do-not-emit")],
    )
    sensitive_typed = prepare_typed(sensitive, True, 0, 1, ["safe diagnostic"])
    assert sensitive_typed["typedRecordsVerified"] is False, sensitive_typed
    assert sensitive_typed["records"] == [], sensitive_typed
    assert sensitive_typed["warningCollectionReason"] == "WARNING_RECORD_TEXT_SENSITIVE", sensitive_typed

    oversized = load_helper(
        path,
        [],
        build_warning_objects=[StubMessage("x" * 4097)],
    )
    oversized_typed = prepare_typed(oversized, True, 0, 1, ["safe diagnostic"])
    assert oversized_typed["typedRecordsVerified"] is False, oversized_typed
    assert oversized_typed["records"] == [], oversized_typed
    assert oversized_typed["warningCollectionReason"] == "WARNING_RECORD_TEXT_TOO_LARGE", oversized_typed

    aggregate_oversized = load_helper(
        path,
        [],
        build_warning_objects=[
            StubMessage(("x" * 4080) + ("-%02d" % index))
            for index in range(65)
        ],
    )
    aggregate_oversized_typed = prepare_typed(
        aggregate_oversized,
        True,
        0,
        65,
        ["safe diagnostic"],
    )
    assert aggregate_oversized_typed["typedRecordsVerified"] is False, aggregate_oversized_typed
    assert aggregate_oversized_typed["records"] == [], aggregate_oversized_typed
    assert aggregate_oversized_typed["warningCollectionReason"] == "WARNING_RECORDS_TOO_LARGE", aggregate_oversized_typed

    wrong_severity = load_helper(
        path,
        [],
        build_warning_objects=[StubMessage("not a warning object", severity="Information")],
    )
    wrong_severity_typed = prepare_typed(wrong_severity, True, 0, 1, ["safe diagnostic"])
    assert wrong_severity_typed["typedRecordsVerified"] is False, wrong_severity_typed
    assert wrong_severity_typed["warningCollectionReason"] == "WARNING_RECORD_SEVERITY_INVALID", wrong_severity_typed

    not_fresh = load_helper(path, [], build_warning_objects=[StubMessage("one")])
    not_fresh_typed = prepare_typed(not_fresh, False, 0, 1, ["safe diagnostic"])
    assert not_fresh_typed["typedRecordsVerified"] is False, not_fresh_typed
    assert not_fresh["_stub_system"].warning_calls == [], not_fresh_typed

    too_many = load_helper(path, [], build_warning_objects=[StubMessage("one")])
    too_many_typed = prepare_typed(too_many, True, 0, 2049, ["safe diagnostic"])
    assert too_many_typed["typedRecordsVerified"] is False, too_many_typed
    assert too_many_typed["warningCollectionReason"] == "WARNING_COUNT_OUT_OF_RANGE", too_many_typed
    assert too_many["_stub_system"].warning_calls == [], too_many_typed

    redacted = load_helper(
        path,
        [
            "Build complete -- 0 errors, 1 warnings : Ready for download",
            "password=must-not-leak",
        ],
    )
    redacted_snapshot, redacted_entries = assert_counts(redacted, 0, 1)
    assert redacted_snapshot["diagnosticRows"] == [
        "[redacted sensitive diagnostic row]"
    ], redacted_snapshot
    assert redacted_entries[0]["text"] == "[redacted sensitive diagnostic row]", redacted_entries

    unknown = load_helper(path, ["Generate code..."])
    snapshot = unknown["msg_fast_compile_snapshot"]()
    entries = unknown["msg_fast_structured_entries"](snapshot)
    assert snapshot["verified"] is False, snapshot
    assert len(entries) == 1 and entries[0]["severity"] == "error", entries

    bounded = load_helper(
        path,
        ["Build complete -- 0 errors, 101 warnings : Ready for download"]
        + ["Warning detail %d" % index for index in range(1, 102)],
    )
    bounded_snapshot, _ = assert_counts(bounded, 0, 101)
    assert len(bounded_snapshot["diagnosticRows"]) == 100, bounded_snapshot
    assert bounded_snapshot["diagnosticRowsComplete"] is False, bounded_snapshot

    with open(compile_project_path, "r", encoding="utf-8") as handle:
        compile_source = handle.read()
    assert "ctrlX fixed-category typed warning producer v1 (2026-08-28)" in compile_source
    assert "msg_fast_prepare_typed_warning_records(" in compile_source
    assert "compile_summary['typedRecordsVerified'] = typed_records_verified" in compile_source
    assert "compile_summary['diagnosticRowsComplete'] = diagnostic_rows_complete" in compile_source
    assert "compile_summary['records'] = typed_records" in compile_source
    assert "compile_summary['warningQueryCount']" in compile_source
    wire_marker = "# ctrlX typed warning wire alignment v1 (2026-08-28)"
    assert wire_marker in compile_source
    wire_marker_index = compile_source.index(wire_marker)
    wire_start = compile_source.rfind("\n", 0, wire_marker_index) + 1
    wire_end = compile_source.index("    compile_summary['contractVersion']", wire_start)
    wire_source = textwrap.dedent(compile_source[wire_start:wire_end])
    wire_namespace = {
        "typed_records_verified": True,
        "typed_records": [
            {"severity": "warning", "text": "OPC.UA.DA warning one"},
            {"severity": "warning", "text": "OPC.UA.DA warning two"},
        ],
        "error_count": 0,
        "warning_count": 2,
        "messages": [
            {"severity": "warning", "text": "CLASS information row"},
            {"severity": "warning", "text": "CHAR information row"},
        ],
    }
    exec(wire_source, wire_namespace)
    assert [item["text"] for item in wire_namespace["messages"]] == [
        "OPC.UA.DA warning one",
        "OPC.UA.DA warning two",
    ], wire_namespace["messages"]
    wire_namespace.update({
        "typed_records_verified": False,
        "error_count": 2500,
        "warning_count": 2500,
        "messages": [{"text": "must be discarded"}],
    })
    exec(wire_source, wire_namespace)
    assert wire_namespace["messages"] == [], wire_namespace["messages"]

    print("fast compile message + strict fresh-v2 regression: OK")


if __name__ == "__main__":
    main()
