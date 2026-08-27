# ctrlX semantic snapshot contract v1 (2026-08-27)
"""Read-only ctrlX semantic mapping producer (IronPython 2.7 compatible).

The server injects _text_utils.py, require_project_open.py and
find_object_by_path.py before this template. Inputs contain locations only;
expected mappings and pass/fail values are deliberately not accepted.
"""

import base64
import json
import os
import sys
import traceback


MAPPING_SCOPES_B64 = "{MAPPING_SCOPES_B64}"
MAPPING_TARGETS_B64 = "{MAPPING_TARGETS_B64}"
SEMANTIC_CONTRACT_ID = "ctrlx-semantic-snapshot-v1"
MAX_MAPPING_RECORDS = 2048
MAX_VISITED_OBJECTS = 8192
_traversal_failures = []


def _record_traversal_failure(stage, error):
    if len(_traversal_failures) >= 128:
        return
    _traversal_failures.append({
        u"stage": _coerce_text(stage),
        u"errorType": _coerce_text(type(error).__name__),
    })


def _coerce_text(value):
    if value is None:
        return u""
    try:
        if isinstance(value, unicode):
            return value
        return _to_unicode(unicode(value))
    except Exception:
        try:
            return _to_unicode(repr(value))
        except Exception:
            return u""


def _object_name(value):
    try:
        return _coerce_text(value.get_name())
    except Exception:
        return _coerce_text(getattr(value, "name", u""))


def _children(value):
    if not hasattr(value, "get_children"):
        return []
    try:
        return list(value.get_children(False))
    except Exception as error:
        _record_traversal_failure(u"get_children", error)
        return []


def _mapping_binding(mapping):
    for attribute in ("variable", "mapped_variable", "symbol"):
        if not hasattr(mapping, attribute):
            continue
        try:
            return True, attribute, _coerce_text(getattr(mapping, attribute))
        except Exception:
            continue
    return False, None, None


def _path_parts(value):
    return [
        part.strip()
        for part in _coerce_text(value).replace(",", "/").split("/")
        if part.strip()
    ]


def _resolve_tree_channel(device, channel_path):
    path_parts = _path_parts(channel_path)
    if path_parts and all([part.isdigit() for part in path_parts]):
        current = device
        for part in path_parts:
            children = _children(current)
            index = int(part)
            if index < 0 or index >= len(children):
                return None, None
            current = children[index]
        return current, "tree-index"
    try:
        value = find_object_by_path_robust(device, channel_path, "channel")
        if value is not None:
            return value, "tree-path"
    except Exception as error:
        _record_traversal_failure(u"find_tree_channel", error)
    return None, None


def _parameter_sets(device):
    values = []
    if hasattr(device, "device_parameters"):
        try:
            values.append((u"device_parameters", None, list(device.device_parameters)))
        except Exception as error:
            _record_traversal_failure(u"device_parameters", error)
    if hasattr(device, "connectors"):
        try:
            for connector_index, connector in enumerate(device.connectors):
                if hasattr(connector, "host_parameters"):
                    try:
                        values.append((
                            u"connector.host_parameters",
                            connector_index,
                            list(connector.host_parameters),
                        ))
                    except Exception as error:
                        _record_traversal_failure(u"connector.host_parameters", error)
        except Exception as error:
            _record_traversal_failure(u"connectors", error)
    return values


def _mappable_parameters(device):
    values = []
    seen = set()
    flattened_index = 0
    for set_kind, connector_index, parameters in _parameter_sets(device):
        for parameter_index, parameter in enumerate(parameters):
            try:
                if not bool(getattr(parameter, "is_mappable_io", False)):
                    continue
                parameter_id = _coerce_text(getattr(parameter, "id", u""))
                parameter_name = _coerce_text(getattr(parameter, "name", u""))
                identity = (
                    set_kind,
                    connector_index,
                    parameter_id,
                    parameter_name,
                    parameter_index,
                )
                if identity in seen:
                    continue
                seen.add(identity)
                values.append({
                    u"parameter": parameter,
                    u"setKind": set_kind,
                    u"connectorIndex": connector_index,
                    u"parameterIndex": parameter_index,
                    u"flattenedIndex": flattened_index,
                    u"parameterId": parameter_id,
                    u"parameterName": parameter_name,
                })
                flattened_index += 1
            except Exception as error:
                _record_traversal_failure(u"mappable_parameter", error)
                continue
    return values


def _resolve_connector_channel(device, channel_path):
    parameters = _mappable_parameters(device)
    path_parts = _path_parts(channel_path)
    requested_name = path_parts[-1] if path_parts else _coerce_text(channel_path).strip()
    selected = None
    if len(path_parts) == 1 and path_parts[0].isdigit():
        flattened_index = int(path_parts[0])
        for parameter_info in parameters:
            if parameter_info[u"flattenedIndex"] == flattened_index:
                selected = parameter_info
                break
    if selected is None:
        for parameter_info in parameters:
            parameter = parameter_info[u"parameter"]
            candidates = []
            for attribute in ("name", "visible_name", "identifier"):
                try:
                    value = getattr(parameter, attribute, None)
                    if value is not None:
                        candidates.append(_coerce_text(value))
                except Exception:
                    pass
            if requested_name in candidates or channel_path in candidates:
                selected = parameter_info
                break
    if selected is None or not hasattr(selected[u"parameter"], "io_mapping"):
        return None
    selected[u"mapping"] = selected[u"parameter"].io_mapping
    return selected


def _read_target(primary_project, target, index):
    device_path = _coerce_text(target.get("devicePath", u"")).strip()
    channel_path = _coerce_text(target.get("channelPath", u"")).strip()
    record = {
        u"recordKind": u"explicit-target",
        u"targetIndex": index,
        u"devicePath": device_path,
        u"channelPath": channel_path,
        u"channelIdentity": u"target:%06d" % index,
        u"resolved": False,
        u"mappingReadable": False,
        u"actualVariable": None,
    }
    if not device_path or not channel_path:
        record[u"error"] = u"devicePath and channelPath must be non-empty."
        return record
    try:
        device = find_object_by_path_robust(primary_project, device_path, "device")
        if device is None:
            record[u"error"] = u"Device was not found."
            return record
        mapping, resolver = _resolve_tree_channel(device, channel_path)
        parameter_info = None
        if mapping is None:
            parameter_info = _resolve_connector_channel(device, channel_path)
            if parameter_info is not None:
                mapping = parameter_info[u"mapping"]
                resolver = "connector-parameter"
        if mapping is None:
            record[u"error"] = u"Channel was not found through tree or connector parameters."
            return record
        readable, binding_source, actual_variable = _mapping_binding(mapping)
        record[u"resolved"] = True
        record[u"resolver"] = resolver
        record[u"deviceName"] = _object_name(device)
        record[u"channelName"] = (
            parameter_info[u"parameterName"]
            if parameter_info is not None
            else _object_name(mapping)
        )
        record[u"mappingReadable"] = readable
        record[u"bindingSource"] = binding_source
        record[u"actualVariable"] = actual_variable
        if parameter_info is not None:
            record[u"parameterIndex"] = parameter_info[u"parameterIndex"]
            record[u"parameterId"] = parameter_info[u"parameterId"]
            record[u"connectorIndex"] = parameter_info[u"connectorIndex"]
        if not readable:
            record[u"error"] = u"Resolved channel exposes no readable mapping attribute."
        return record
    except Exception as error:
        record[u"error"] = _coerce_text(error)
        return record


def _append_record(records, record):
    if len(records) >= MAX_MAPPING_RECORDS:
        raise ValueError(
            "Semantic mapping snapshot exceeds the %d-record read-only limit."
            % MAX_MAPPING_RECORDS
        )
    records.append(record)


def _enumerate_scope_node(
    node,
    scope_index,
    scope_device_path,
    relative_segments,
    index_path,
    records,
    visited,
):
    identity = id(node)
    if identity in visited:
        return
    visited.add(identity)
    if len(visited) > MAX_VISITED_OBJECTS:
        raise ValueError(
            "Semantic mapping scope exceeds the %d-object traversal limit."
            % MAX_VISITED_OBJECTS
        )

    relative_path = u"/".join(relative_segments)
    index_path_text = u"/".join([unicode(value) for value in index_path])
    node_name = _object_name(node)
    readable, binding_source, actual_variable = _mapping_binding(node)
    if readable and index_path:
        _append_record(records, {
            u"recordKind": u"scope-channel",
            u"scopeIndex": scope_index,
            u"scopeDevicePath": scope_device_path,
            u"relativeDevicePath": relative_path,
            u"deviceIndexPath": index_path_text,
            u"deviceName": node_name,
            u"sourceKind": u"tree-channel",
            u"channelIdentity": u"scope:%06d:tree:%s" % (
                scope_index,
                index_path_text,
            ),
            u"channelName": node_name,
            u"resolved": True,
            u"mappingReadable": True,
            u"bindingSource": binding_source,
            u"actualVariable": actual_variable,
        })

    for parameter_info in _mappable_parameters(node):
        parameter = parameter_info[u"parameter"]
        if not hasattr(parameter, "io_mapping"):
            _record_traversal_failure(
                u"mappable_parameter.io_mapping",
                RuntimeError("Mappable parameter exposes no io_mapping attribute."),
            )
            continue
        readable, binding_source, actual_variable = _mapping_binding(parameter.io_mapping)
        connector_index = parameter_info[u"connectorIndex"]
        connector_text = (
            u"device" if connector_index is None else u"connector-%06d" % connector_index
        )
        parameter_identity = parameter_info[u"parameterId"] or parameter_info[u"parameterName"]
        _append_record(records, {
            u"recordKind": u"scope-channel",
            u"scopeIndex": scope_index,
            u"scopeDevicePath": scope_device_path,
            u"relativeDevicePath": relative_path,
            u"deviceIndexPath": index_path_text,
            u"deviceName": node_name,
            u"sourceKind": u"connector-parameter",
            u"parameterSetKind": parameter_info[u"setKind"],
            u"connectorIndex": connector_index,
            u"parameterIndex": parameter_info[u"parameterIndex"],
            u"parameterId": parameter_info[u"parameterId"],
            u"parameterName": parameter_info[u"parameterName"],
            u"channelIdentity": u"scope:%06d:%s:%s:%s:%06d" % (
                scope_index,
                index_path_text,
                connector_text,
                parameter_identity,
                parameter_info[u"parameterIndex"],
            ),
            u"channelName": parameter_info[u"parameterName"],
            u"resolved": True,
            u"mappingReadable": readable,
            u"bindingSource": binding_source,
            u"actualVariable": actual_variable,
            u"error": (
                None
                if readable
                else u"Mappable parameter exposes no readable mapping attribute."
            ),
        })

    for child_index, child in enumerate(_children(node)):
        child_name = _object_name(child) or _coerce_text(type(child).__name__)
        _enumerate_scope_node(
            child,
            scope_index,
            scope_device_path,
            relative_segments + [child_name],
            index_path + [child_index],
            records,
            visited,
        )


def _read_scope(primary_project, scope, scope_index, records):
    device_path = _coerce_text(scope.get("devicePath", u"")).strip()
    scope_record = {
        u"scopeIndex": scope_index,
        u"devicePath": device_path,
        u"recursive": True,
        u"resolved": False,
        u"recordStart": len(records),
        u"recordCount": 0,
    }
    if not device_path:
        scope_record[u"error"] = u"devicePath must be non-empty."
        return scope_record
    if scope.get("recursive") is not True:
        scope_record[u"error"] = u"recursive must be true."
        return scope_record
    if scope.get("includeAllMappableChannels") is not True:
        scope_record[u"error"] = u"includeAllMappableChannels must be true."
        return scope_record
    try:
        root = find_object_by_path_robust(primary_project, device_path, "device")
        if root is None:
            scope_record[u"error"] = u"Scope root was not found."
            return scope_record
        _enumerate_scope_node(root, scope_index, device_path, [], [], records, set())
        scope_record[u"resolved"] = True
        scope_record[u"rootName"] = _object_name(root)
        scope_record[u"recordCount"] = len(records) - scope_record[u"recordStart"]
        return scope_record
    except Exception as error:
        scope_record[u"error"] = _coerce_text(error)
        scope_record[u"recordCount"] = len(records) - scope_record[u"recordStart"]
        return scope_record


def _decode_array(encoded_value, name, maximum):
    raw_value = base64.b64decode(encoded_value)
    if not isinstance(raw_value, unicode):
        raw_value = raw_value.decode("utf-8")
    value = json.loads(raw_value)
    if not isinstance(value, list):
        raise ValueError("%s must decode to a JSON array." % name)
    if len(value) > maximum:
        raise ValueError("%s exceeds the %d-item read-only limit." % (name, maximum))
    return value


def _read_project_dirty(primary_project):
    try:
        return True, bool(primary_project.dirty)
    except Exception:
        pass
    return False, None


try:
    scopes = _decode_array(MAPPING_SCOPES_B64, "mappingScopes", 64)
    targets = _decode_array(MAPPING_TARGETS_B64, "mappingTargets", 512)
    if not scopes and not targets:
        raise ValueError("At least one mapping scope or explicit mapping target is required.")
    primary_project = require_project_open(PROJECT_FILE_PATH)
    dirty_before_verified, dirty_before = _read_project_dirty(primary_project)

    records = []
    scope_records = []
    for scope_index, scope in enumerate(scopes):
        if not isinstance(scope, dict):
            scope_records.append({
                u"scopeIndex": scope_index,
                u"resolved": False,
                u"recordCount": 0,
                u"error": u"Mapping scope is not an object.",
            })
            continue
        scope_records.append(_read_scope(primary_project, scope, scope_index, records))
    for target_index, target in enumerate(targets):
        if not isinstance(target, dict):
            _append_record(records, {
                u"recordKind": u"explicit-target",
                u"targetIndex": target_index,
                u"resolved": False,
                u"mappingReadable": False,
                u"actualVariable": None,
                u"error": u"Mapping target is not an object.",
            })
            continue
        _append_record(records, _read_target(primary_project, target, target_index))

    records.sort(key=lambda item: (
        _coerce_text(item.get(u"channelIdentity", u"")),
        _coerce_text(item.get(u"devicePath", u"")),
        _coerce_text(item.get(u"channelPath", u"")),
    ))
    # A project can become dirty while the mapping tree is being traversed.
    # Read the ScriptEngine state again after traversal; the server also runs
    # one final mapping/dirty probe after both REST reads.
    dirty_after_verified, dirty_after = _read_project_dirty(primary_project)
    dirty_verified = dirty_before_verified and dirty_after_verified
    if dirty_before is True or dirty_after is True:
        project_dirty = True
    elif dirty_verified:
        project_dirty = False
    else:
        project_dirty = None
    records_complete = (
        dirty_verified and
        project_dirty is False and
        len(_traversal_failures) == 0 and
        len(scope_records) == len(scopes) and
        all([item.get(u"resolved") is True for item in scope_records]) and
        all([
            item.get(u"resolved") is True and
            item.get(u"mappingReadable") is True
            for item in records
        ])
    )
    emit_result({
        u"contractVersion": 1,
        u"contractId": SEMANTIC_CONTRACT_ID,
        u"producer": u"codesys-persistent.get_ctrlx_semantic_snapshot",
        u"adapterPatchId": SEMANTIC_CONTRACT_ID,
        u"projectFilePath": _coerce_text(os.path.abspath(PROJECT_FILE_PATH)),
        u"dirtyStateVerified": dirty_verified,
        u"projectDirty": project_dirty,
        u"dirtyCheckCount": 2,
        u"dirtyBefore": dirty_before,
        u"dirtyAfter": dirty_after,
        u"scopeCount": len(scopes),
        u"explicitTargetCount": len(targets),
        u"recordCount": len(records),
        u"recordLimit": MAX_MAPPING_RECORDS,
        u"traversalFailureCount": len(_traversal_failures),
        u"recordsComplete": records_complete,
        u"scopes": scope_records,
        u"mappings": records,
    })
    print("SCRIPT_SUCCESS: read-only ctrlX semantic mapping snapshot complete.")
    sys.exit(0)
except Exception as error:
    detailed_error = traceback.format_exc()
    print("SCRIPT_ERROR: semantic snapshot failed: %s\n%s" % (error, detailed_error))
    sys.exit(1)
