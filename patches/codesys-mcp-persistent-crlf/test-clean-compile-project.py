#!/usr/bin/env python3
"""Pure-offline regression for the clean_compile_project IronPython asset."""

import ast
import contextlib
import io
import json
import os
import re
import sys
import types


class FakeSystem(object):
    def __init__(self, fail_clear=False):
        self.fail_clear = fail_clear
        self.clear_calls = []

    def clear_messages(self, category):
        self.clear_calls.append(category)
        if self.fail_clear:
            raise RuntimeError("clear failed")

    def get_messages(self, category):
        return []


class FakeApplication(object):
    is_application = True

    def __init__(self, fail_clean=False, fail_build=False):
        self.fail_clean = fail_clean
        self.fail_build = fail_build
        self.clean_calls = 0
        self.build_calls = 0

    def get_name(self):
        return "Application"

    def clean(self):
        self.clean_calls += 1
        if self.fail_clean:
            raise RuntimeError("clean failed")

    def build(self):
        self.build_calls += 1
        if self.fail_build:
            raise RuntimeError("build failed")


class MissingCleanApplication(object):
    is_application = True

    def __init__(self):
        self.build_calls = 0

    def get_name(self):
        return "Application"

    def build(self):
        self.build_calls += 1


class FakeProject(object):
    def __init__(self, path, app, dirty_values=None):
        self.path = path
        self.active_application = app
        self._dirty_values = list(dirty_values or [False, False])
        self._dirty_reads = 0

    @property
    def dirty(self):
        index = min(self._dirty_reads, len(self._dirty_values) - 1)
        self._dirty_reads += 1
        return self._dirty_values[index]

    def get_children(self, recursive):
        return [self.active_application]


def summary(warnings=2, errors=0, explicit=True):
    rows = ["warning-%d" % index for index in range(warnings)]
    return {
        "verified": True,
        "errorCount": errors,
        "warningCount": warnings,
        "messageCount": warnings,
        "diagnosticRows": rows,
        "diagnosticRowsComplete": True,
        "categoryResults": [
            {
                "category": "Build",
                "readError": None,
                "summarySource": "Build complete" if explicit else None,
                "errors": errors if explicit else None,
                "warnings": warnings if explicit else None,
            },
            {
                "category": "Additional code checks",
                "readError": None,
                "summarySource": None,
                "errors": 0,
                "warnings": 0,
            },
        ],
    }


def run_asset(asset_path, *, dirty_values=None, path_override=None,
              app=None, fail_clear=False, warnings=2, errors=0,
              explicit=True, typed_verified=True):
    project_path = os.path.abspath("clean-build-fixture.project")
    app = app or FakeApplication()
    project = FakeProject(path_override or project_path, app, dirty_values)
    system = FakeSystem(fail_clear=fail_clear)
    scriptengine = types.ModuleType("scriptengine")
    scriptengine.system = system
    previous_scriptengine = sys.modules.get("scriptengine")
    sys.modules["scriptengine"] = scriptengine

    snapshot = summary(warnings=warnings, errors=errors, explicit=explicit)
    records = [{"severity": "warning", "text": "warning-%d" % index}
               for index in range(warnings)] if typed_verified else []
    typed = {
        "typedRecordsVerified": typed_verified,
        "records": records,
        "messageCount": len(records) if typed_verified else warnings,
        "diagnosticRows": [record["text"] for record in records]
        if typed_verified else snapshot["diagnosticRows"],
        "diagnosticRowsComplete": True,
        "warningQueryCount": 2 if warnings else 0,
        "warningObjectCount": warnings,
        "warningCollectionReason": "WARNING_COLLECTION_VERIFIED"
        if typed_verified else "WARNING_QUERY_FAILED",
    }
    namespace = {
        "PROJECT_FILE_PATH": project_path,
        "ensure_project_open": lambda value: project,
        "msg_fast_compile_categories": lambda: [
            ("build-guid", "Build"),
            ("checks-guid", "Additional code checks"),
        ],
        "msg_fast_compile_snapshot": lambda categories: dict(snapshot),
        "msg_fast_structured_entries": lambda value: [],
        "msg_fast_prepare_typed_warning_records": lambda *args: dict(typed),
        "msg_fast_summary_wire": lambda value: dict(
            (key, item) for key, item in value.items() if key != "details"),
        "_to_unicode": str,
        "_json_default": str,
        "unicode": str,
    }
    capture = io.StringIO()
    exit_code = None
    try:
        with open(asset_path, "r", encoding="utf-8") as handle:
            source = handle.read()
        with contextlib.redirect_stdout(capture):
            try:
                exec(compile(source, asset_path, "exec"), namespace)
            except SystemExit as exc:
                exit_code = int(exc.code)
    finally:
        if previous_scriptengine is None:
            del sys.modules["scriptengine"]
        else:
            sys.modules["scriptengine"] = previous_scriptengine
    output = capture.getvalue()
    match = re.search(
        r"### CLEAN_COMPILE_SUMMARY_START ###\n(.*?)\n"
        r"### CLEAN_COMPILE_SUMMARY_END ###", output, re.DOTALL)
    payload = json.loads(match.group(1)) if match else None
    return exit_code, output, payload, app, project, system


def main():
    asset_path = os.path.abspath(sys.argv[1])
    with open(asset_path, "r", encoding="utf-8") as handle:
        source = handle.read()
    tree = ast.parse(source)
    call_names = [
        node.func.attr
        for node in ast.walk(tree)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
    ]
    assert "clean_all" not in call_names
    assert "generate_code" not in call_names
    assert source.count("target_app.clean()") == 1
    assert source.count("target_app.build()") == 1
    assert ".save(" not in source

    code, output, payload, app, project, system = run_asset(asset_path)
    assert code == 0, output
    assert app.clean_calls == 1 and app.build_calls == 1
    assert len(system.clear_calls) == 2
    assert payload["cleanInvocation"] == "application.clean"
    assert payload["buildInvocation"] == "application.build"
    assert payload["cleanInvocationCount"] == 1
    assert payload["buildInvocationCount"] == 1
    assert payload["semanticRebuildVerified"] is True
    assert payload["messageEvidenceComplete"] is True
    assert payload["warningDetailsComplete"] is True
    assert payload["identityPreflightVerified"] is True
    assert payload["identityPostflightVerified"] is True
    assert payload["dirtyPostflightVerified"] is True

    dirty_app = FakeApplication()
    code, output, payload, app, _, system = run_asset(
        asset_path, dirty_values=[True], app=dirty_app)
    assert code == 1 and payload is None
    assert app.clean_calls == 0 and app.build_calls == 0
    assert len(system.clear_calls) == 0

    mismatch_app = FakeApplication()
    code, output, payload, app, _, system = run_asset(
        asset_path, path_override=os.path.abspath("wrong.project"),
        app=mismatch_app)
    assert code == 1 and payload is None
    assert app.clean_calls == 0 and app.build_calls == 0

    missing_clean = MissingCleanApplication()
    code, output, payload, app, _, _ = run_asset(
        asset_path, app=missing_clean)
    assert code == 1 and payload is None and app.build_calls == 0

    failing_clean = FakeApplication(fail_clean=True)
    code, output, payload, app, _, _ = run_asset(
        asset_path, app=failing_clean)
    assert code == 1 and payload is None
    assert app.clean_calls == 1 and app.build_calls == 0

    failing_build = FakeApplication(fail_build=True)
    code, output, payload, app, _, _ = run_asset(
        asset_path, app=failing_build)
    assert code == 1 and payload is None
    assert app.clean_calls == 1 and app.build_calls == 1

    clear_app = FakeApplication()
    code, output, payload, app, _, _ = run_asset(
        asset_path, app=clear_app, fail_clear=True)
    assert code == 1 and payload is None
    assert app.clean_calls == 0 and app.build_calls == 0

    code, output, payload, app, _, _ = run_asset(
        asset_path, typed_verified=False)
    assert code == 0, output
    assert app.clean_calls == 1 and app.build_calls == 1
    assert payload["semanticRebuildVerified"] is True
    assert payload["messageEvidenceComplete"] is True
    assert payload["warningDetailsComplete"] is False
    assert payload["typedRecordsVerified"] is False
    assert payload["verified"] is True
    untyped_wire = re.search(
        r"### COMPILE_MESSAGES_START ###\n(.*?)\n"
        r"### COMPILE_MESSAGES_END ###", output, re.DOTALL)
    assert untyped_wire is not None and json.loads(untyped_wire.group(1)) == []

    code, output, payload, app, _, _ = run_asset(
        asset_path, errors=1, typed_verified=False)
    assert code == 0, output
    assert payload["errorCount"] == 1
    assert payload["semanticRebuildVerified"] is True
    assert payload["messageEvidenceComplete"] is True
    assert payload["warningDetailsComplete"] is False

    code, output, payload, app, _, _ = run_asset(
        asset_path, explicit=False)
    assert code == 0, output
    assert payload["semanticRebuildVerified"] is False
    assert payload["explicitBuildSummaryVerified"] is False

    code, output, payload, app, _, _ = run_asset(
        asset_path, dirty_values=[False, True])
    assert code == 0, output
    assert payload["semanticRebuildVerified"] is False
    assert payload["dirtyPostflightVerified"] is False

    typed_wire = re.search(
        r"### COMPILE_MESSAGES_START ###\n(.*?)\n"
        r"### COMPILE_MESSAGES_END ###", run_asset(asset_path)[1], re.DOTALL)
    assert typed_wire is not None
    wire_records = json.loads(typed_wire.group(1))
    assert [record["text"] for record in wire_records] == [
        "warning-0", "warning-1"]

    print("clean compile producer invocation/identity/dirty/message regression: OK")


if __name__ == "__main__":
    main()
