import sys, scriptengine as script_engine, os, traceback, json
import tempfile
import uuid as _build_uuid
import datetime as _build_datetime

try:
    import StringIO  # IronPython 2.7 / Python 2
except ImportError:
    try:
        from io import StringIO as _IOStringIO
        class StringIO(object):
            class StringIO(_IOStringIO):
                pass
    except Exception:
        StringIO = None

# ctrlX clean compile tool contract v1 (2026-08-28)
# This is an explicit, opt-in semantic rebuild.  The ordinary compile_project
# remains the faster one-Build path.  This producer invokes application.clean()
# exactly once, then application.build() exactly once.  It never saves the
# project and never invokes any alternative code-generation entry point.
CLEAN_COMPILE_CONTRACT_ID = u"ctrlx-clean-compile-v1"

_COMPILE_DEBUG_PATH = os.path.join(
    tempfile.gettempdir(), 'codesys-mcp-clean-compile-debug.txt')
_ORIG_STDOUT = sys.stdout
_DEBUG_BUFFER = StringIO.StringIO() if StringIO is not None else None


class _Tee(object):
    def __init__(self, *sinks):
        self._sinks = sinks

    def write(self, data):
        for sink in self._sinks:
            try:
                sink.write(data)
            except Exception:
                pass

    def flush(self):
        for sink in self._sinks:
            try:
                if hasattr(sink, 'flush'):
                    sink.flush()
            except Exception:
                pass


if _DEBUG_BUFFER is not None:
    sys.stdout = _Tee(_ORIG_STDOUT, _DEBUG_BUFFER)


def _flush_debug_to_file():
    if _DEBUG_BUFFER is None:
        return
    try:
        content = _DEBUG_BUFFER.getvalue()
        if isinstance(content, unicode):
            content = content.encode('utf-8')
        with open(_COMPILE_DEBUG_PATH, 'wb') as handle:
            handle.write(content)
    except Exception:
        pass


def _normalized_path(value):
    return os.path.normcase(os.path.abspath(value))


def _read_project_path(project):
    try:
        value = getattr(project, 'path')
    except AttributeError:
        raise RuntimeError(
            "Project path is unavailable; refusing semantic rebuild.")
    except Exception as path_error:
        raise RuntimeError(
            "Could not verify the active project path: %s" % path_error)
    if value is None or not unicode(value).strip():
        raise RuntimeError(
            "Active project path is empty; refusing semantic rebuild.")
    return _normalized_path(unicode(value))


def _read_project_dirty(project, phase):
    try:
        return bool(getattr(project, 'dirty'))
    except AttributeError:
        raise RuntimeError(
            "Project dirty state is unavailable %s semantic rebuild." % phase)
    except Exception as dirty_error:
        raise RuntimeError(
            "Could not verify project dirty state %s semantic rebuild: %s" %
            (phase, dirty_error))


def _write_wire(value):
    # IronPython 2 stdout accepts UTF-8 bytes; the offline CPython 3 regression
    # uses a text stream.  Keep the producer byte-for-byte equivalent on both.
    if sys.version_info[0] >= 3 and isinstance(value, bytes):
        value = value.decode('utf-8')
    sys.stdout.write(value)


try:
    print("DEBUG: clean_compile_project script: Project='%s'" % PROJECT_FILE_PATH)
    expected_project_path = _normalized_path(PROJECT_FILE_PATH)
    primary_project = ensure_project_open(PROJECT_FILE_PATH)
    project_name = os.path.basename(PROJECT_FILE_PATH)

    active_project_path_before = _read_project_path(primary_project)
    identity_preflight_verified = (
        active_project_path_before == expected_project_path)
    if not identity_preflight_verified:
        raise RuntimeError(
            "Active project identity mismatch before semantic rebuild.")

    project_is_dirty = _read_project_dirty(primary_project, 'before')
    if project_is_dirty:
        raise RuntimeError(
            "Project is dirty before semantic rebuild; refusing implicit save. "
            "Save through the owning workflow or reopen the project first.")

    target_app = None
    app_name = "N/A"
    try:
        target_app = primary_project.active_application
        if target_app:
            app_name = getattr(
                target_app, 'get_name', lambda: "Unnamed App (Active)")()
    except Exception as active_error:
        print("WARN: Could not get active application: %s. Searching..." %
              active_error)

    if not target_app:
        try:
            for child in primary_project.get_children(True):
                if (hasattr(child, 'is_application') and
                        child.is_application and
                        hasattr(child, 'clean') and
                        hasattr(child, 'build')):
                    target_app = child
                    app_name = getattr(
                        child, 'get_name', lambda: "Unnamed App")()
                    break
        except Exception as find_error:
            print("WARN: Error finding application object: %s" % find_error)

    if not target_app:
        raise RuntimeError(
            "No application exposing clean() and build() was found in '%s'." %
            project_name)
    if not hasattr(target_app, 'clean'):
        raise TypeError(
            "Application '%s' exposes no clean(); semantic rebuild unavailable." %
            app_name)
    if not hasattr(target_app, 'build'):
        raise TypeError(
            "Application '%s' exposes no build(); semantic rebuild unavailable." %
            app_name)

    expected_category_names = ('Build', 'Additional code checks')
    fast_categories = msg_fast_compile_categories()
    actual_category_names = tuple([
        category_name for category_guid, category_name in fast_categories])
    expected_category_coverage = (
        actual_category_names == expected_category_names)
    if not expected_category_coverage:
        raise RuntimeError(
            "Expected compile categories %r, but adapter resolved %r; "
            "refusing semantic rebuild." %
            (expected_category_names, actual_category_names))

    category_clear_results = []
    for category_guid, category_name in fast_categories:
        clear_succeeded = False
        clear_error_text = None
        clear_readback_succeeded = False
        clear_readback_error_text = None
        rows_remaining_after_clear = None
        try:
            script_engine.system.clear_messages(category_guid)
            clear_succeeded = True
        except Exception as clear_error:
            clear_error_text = unicode(clear_error)
        if clear_succeeded:
            try:
                rows_remaining_after_clear = 0
                rows_after_clear = script_engine.system.get_messages(
                    category_guid)
                if rows_after_clear is not None:
                    for ignored_row in rows_after_clear:
                        rows_remaining_after_clear += 1
                clear_readback_succeeded = True
            except Exception as clear_readback_error:
                clear_readback_error_text = unicode(clear_readback_error)
        cleared_and_verified = (
            clear_succeeded and
            clear_readback_succeeded and
            rows_remaining_after_clear == 0)
        category_clear_results.append({
            'category': category_name,
            'succeeded': clear_succeeded,
            'error': clear_error_text,
            'readbackSucceeded': clear_readback_succeeded,
            'readbackError': clear_readback_error_text,
            'rowsRemainingAfterClear': rows_remaining_after_clear,
            'clearedAndVerified': cleared_and_verified,
        })

    all_expected_categories_cleared = (
        expected_category_coverage and
        len(category_clear_results) == len(expected_category_names) and
        all([item.get('clearedAndVerified') is True
             for item in category_clear_results]))
    if not all_expected_categories_cleared:
        clear_failures = [
            "%s: clearError=%s, readbackError=%s, rowsRemaining=%r" %
            (item.get('category'), item.get('error'),
             item.get('readbackError'), item.get('rowsRemainingAfterClear'))
            for item in category_clear_results
            if item.get('clearedAndVerified') is not True]
        raise RuntimeError(
            "Could not clear and verify every expected compile category; "
            "refusing semantic rebuild: %s" % '; '.join(clear_failures))

    import time as _build_time
    build_token = _build_uuid.uuid4().hex
    started_at_utc = _build_datetime.datetime.utcnow().strftime(
        '%Y-%m-%dT%H:%M:%S.%fZ')
    clean_invocation_count = 0
    build_invocation_count = 0
    clean_succeeded = False
    build_succeeded = False

    clean_started = _build_time.time()
    clean_invocation_count += 1
    target_app.clean()
    clean_succeeded = True
    clean_elapsed_seconds = round(_build_time.time() - clean_started, 3)
    print("DEBUG: clean() executed once for application '%s'." % app_name)

    build_started = _build_time.time()
    build_invocation_count += 1
    target_app.build()
    build_succeeded = True
    build_elapsed_seconds = round(_build_time.time() - build_started, 3)
    print("DEBUG: build() executed once for application '%s'." % app_name)
    _flush_debug_to_file()

    snapshot_started = _build_time.time()
    compile_summary = msg_fast_compile_snapshot(fast_categories)
    compile_summary['cleanElapsedSeconds'] = clean_elapsed_seconds
    compile_summary['buildElapsedSeconds'] = build_elapsed_seconds
    compile_summary['snapshotElapsedSeconds'] = round(
        _build_time.time() - snapshot_started, 3)
    category_results = compile_summary.get('categoryResults', []) or []
    result_by_name = dict((item.get('category'), item)
                          for item in category_results)
    all_expected_categories_read = (
        len(category_results) == len(expected_category_names) and
        all([
            name in result_by_name and
            result_by_name[name].get('readError') is None
            for name in expected_category_names]))
    build_category_result = result_by_name.get('Build', {})
    explicit_build_summary = (
        build_category_result.get('summarySource') in
        ('Compile complete', 'Build complete') and
        build_category_result.get('errors') is not None and
        build_category_result.get('warnings') is not None)

    active_project_path_after = _read_project_path(primary_project)
    identity_postflight_verified = (
        active_project_path_after == expected_project_path and
        active_project_path_after == active_project_path_before)
    project_dirty_after = _read_project_dirty(primary_project, 'after')
    dirty_postflight_verified = (project_dirty_after is False)

    dirty_preflight_verified = (project_is_dirty is False)
    invocation_contract_verified = (
        clean_succeeded and
        build_succeeded and
        clean_invocation_count == 1 and
        build_invocation_count == 1)
    patch_preflight_verified = (
        identity_preflight_verified and
        dirty_preflight_verified and
        expected_category_coverage and
        all_expected_categories_cleared and
        invocation_contract_verified and
        all_expected_categories_read and
        explicit_build_summary and
        identity_postflight_verified and
        dirty_postflight_verified)
    fresh_evidence_verified = (
        patch_preflight_verified and
        compile_summary.get('verified') is True)

    warning_count = int(compile_summary.get('warningCount', 0) or 0)
    error_count = int(compile_summary.get('errorCount', 0) or 0)
    diagnostic_rows = compile_summary.get('diagnosticRows', []) or []
    diagnostic_rows_complete = (
        compile_summary.get('diagnosticRowsComplete') is True)
    typed_warning_outcome = msg_fast_prepare_typed_warning_records(
        fresh_evidence_verified,
        error_count,
        warning_count,
        fast_categories,
        diagnostic_rows,
        diagnostic_rows_complete)
    typed_records_verified = (
        typed_warning_outcome.get('typedRecordsVerified') is True)
    typed_records = typed_warning_outcome.get('records', []) or []
    diagnostic_rows = typed_warning_outcome.get('diagnosticRows', []) or []
    diagnostic_rows_complete = (
        typed_warning_outcome.get('diagnosticRowsComplete') is True)
    if typed_records_verified:
        # records already carry the exact warning texts.  Do not duplicate up
        # to 256 KiB of the same strings in diagnosticRows across the MCP wire.
        diagnostic_rows = []
        diagnostic_rows_complete = True
    message_count = error_count + warning_count
    warning_details_complete = typed_records_verified
    message_evidence_complete = (
        fresh_evidence_verified and
        all_expected_categories_read and
        explicit_build_summary)
    semantic_rebuild_verified = (
        invocation_contract_verified and
        message_evidence_complete and
        identity_preflight_verified and
        identity_postflight_verified and
        dirty_preflight_verified and
        dirty_postflight_verified)

    compile_summary['contractVersion'] = 1
    compile_summary['contractId'] = CLEAN_COMPILE_CONTRACT_ID
    compile_summary['producer'] = 'codesys-persistent.clean_compile_project'
    compile_summary['adapterPatchId'] = CLEAN_COMPILE_CONTRACT_ID
    compile_summary['cleanInvocation'] = (
        'application.clean' if clean_succeeded else None)
    compile_summary['buildInvocation'] = (
        'application.build' if build_succeeded else None)
    compile_summary['cleanInvocationCount'] = clean_invocation_count
    compile_summary['buildInvocationCount'] = build_invocation_count
    compile_summary['cleanSucceeded'] = clean_succeeded
    compile_summary['buildSucceeded'] = build_succeeded
    compile_summary['semanticRebuildVerified'] = semantic_rebuild_verified
    compile_summary['messageEvidenceComplete'] = message_evidence_complete
    compile_summary['warningDetailsComplete'] = warning_details_complete
    compile_summary['fresh'] = fresh_evidence_verified
    compile_summary['projectFilePath'] = expected_project_path
    compile_summary['buildToken'] = build_token
    compile_summary['startedAtUtc'] = started_at_utc
    compile_summary['completedAtUtc'] = (
        _build_datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%S.%fZ'))
    compile_summary['identityPreflightVerified'] = identity_preflight_verified
    compile_summary['identityPostflightVerified'] = identity_postflight_verified
    compile_summary['dirtyPreflightVerified'] = dirty_preflight_verified
    compile_summary['dirtyPostflightVerified'] = dirty_postflight_verified
    compile_summary['expectedCategoryCoverageVerified'] = (
        expected_category_coverage)
    compile_summary['categoryClearResults'] = category_clear_results
    compile_summary['allExpectedCategoriesCleared'] = (
        all_expected_categories_cleared)
    compile_summary['allExpectedCategoriesRead'] = all_expected_categories_read
    compile_summary['explicitBuildSummaryVerified'] = explicit_build_summary
    compile_summary['patchPreflightVerified'] = patch_preflight_verified
    compile_summary['verified'] = semantic_rebuild_verified
    compile_summary['messageCount'] = message_count
    compile_summary['recordsComplete'] = message_evidence_complete
    compile_summary['typedRecordsVerified'] = typed_records_verified
    compile_summary['diagnosticRowsComplete'] = diagnostic_rows_complete
    compile_summary['diagnosticRows'] = diagnostic_rows
    compile_summary['records'] = typed_records
    compile_summary['warningQueryCount'] = int(
        typed_warning_outcome.get('warningQueryCount', 0) or 0)
    compile_summary['warningObjectCount'] = int(
        typed_warning_outcome.get('warningObjectCount', 0) or 0)
    compile_summary['warningCollectionReason'] = (
        typed_warning_outcome.get(
            'warningCollectionReason', 'WARNING_COLLECTION_UNKNOWN'))

    # Never re-label Information rows as warnings.  When the fixed-category
    # Warning-object query is complete, both the wire message list and summary
    # use exactly the same typed warning records.  Otherwise emit no wire
    # records; the numeric summary remains authoritative and bounded
    # diagnosticRows remain explicitly untyped diagnostics in the summary.
    if typed_records_verified:
        messages = [
            {
                'category': 'Compiler warning',
                'severity': 'warning',
                'text': record.get('text'),
            }
            for record in typed_records]
    else:
        messages = []

    for entry in messages:
        for key in ('text', 'object', 'severity', 'category', 'code'):
            if key in entry:
                entry[key] = _to_unicode(entry[key])

    messages_json = json.dumps(
        messages, ensure_ascii=False, default=_json_default)
    if isinstance(messages_json, unicode):
        messages_json = messages_json.encode('utf-8')
    summary_json = json.dumps(
        msg_fast_summary_wire(compile_summary),
        ensure_ascii=False,
        default=_json_default)
    if isinstance(summary_json, unicode):
        summary_json = summary_json.encode('utf-8')
    sys.stdout.write("### CLEAN_COMPILE_SUMMARY_START ###\n")
    _write_wire(summary_json)
    sys.stdout.write("\n### CLEAN_COMPILE_SUMMARY_END ###\n")
    sys.stdout.write("### COMPILE_MESSAGES_START ###\n")
    _write_wire(messages_json)
    sys.stdout.write("\n### COMPILE_MESSAGES_END ###\n")
    sys.stdout.flush()

    print("SCRIPT_SUCCESS: Application semantic rebuild completed.")
    print("DEBUG: post-mortem debug trace at %s" % _COMPILE_DEBUG_PATH)
    _flush_debug_to_file()
    sys.stdout = _ORIG_STDOUT
    sys.exit(0)
except Exception as error:
    detailed_error = traceback.format_exc()
    error_message = (
        "Error performing semantic rebuild for project %s: %s\n%s" %
        (PROJECT_FILE_PATH, error, detailed_error))
    print(error_message)
    print("SCRIPT_ERROR: %s" % error_message)
    _flush_debug_to_file()
    sys.stdout = _ORIG_STDOUT
    sys.exit(1)
