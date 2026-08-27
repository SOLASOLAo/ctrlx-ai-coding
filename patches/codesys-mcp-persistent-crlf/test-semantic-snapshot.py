"""Pure-offline regression for ctrlx-semantic-snapshot-v1 mapping facts.

Only stub ScriptEngine objects are used. No Node, MCP, PLE, REST endpoint or
engineering project is started.
"""

from __future__ import print_function

import argparse
import base64
import json
import os


class Mapping(object):
    def __init__(self, name, variable):
        self.name = name
        self.variable = variable

    def get_name(self):
        return self.name


class Parameter(object):
    def __init__(self, identity, name, variable):
        self.id = identity
        self.name = name
        self.visible_name = name
        self.identifier = name
        self.is_mappable_io = True
        self.io_mapping = Mapping(name, variable)


class Connector(object):
    def __init__(self, parameters):
        self.host_parameters = parameters


class Node(object):
    def __init__(self, name, children=None, connectors=None):
        self.name = name
        self.children = list(children or [])
        self.connectors = list(connectors or [])
        self.lookup = {}

    def get_name(self):
        return self.name

    def get_children(self, recursive):
        return list(self.children)


class BrokenNode(Node):
    def get_children(self, recursive):
        raise RuntimeError("fixture traversal failure")


class Project(Node):
    def __init__(self, path, dirty=True, expose_dirty=True):
        Node.__init__(self, "Fixture")
        self.path = path
        if expose_dirty:
            self.dirty = dirty


class DirtyDuringTraversalProject(Node):
    def __init__(self, path):
        Node.__init__(self, "Fixture")
        self.path = path
        self.lookup = {}
        self.dirty_reads = 0

    @property
    def dirty(self):
        self.dirty_reads += 1
        return self.dirty_reads > 1


def execute_snapshot(script_path, scopes, targets, project):
    capture = {}
    with open(script_path, "r", encoding="utf-8") as handle:
        source = handle.read()
    scope_payload = base64.b64encode(json.dumps(scopes).encode("utf-8")).decode("ascii")
    target_payload = base64.b64encode(json.dumps(targets).encode("utf-8")).decode("ascii")
    source = source.replace("{MAPPING_SCOPES_B64}", scope_payload)
    source = source.replace("{MAPPING_TARGETS_B64}", target_payload)

    def find_object(start, path, target_type):
        return start.lookup.get(path)

    def require_project(expected):
        if os.path.abspath(expected) != os.path.abspath(project.path):
            raise RuntimeError("wrong project")
        return project

    namespace = {
        "__name__": "semantic_snapshot_fixture",
        "unicode": str,
        "PROJECT_FILE_PATH": project.path,
        "_to_unicode": lambda value: str(value),
        "require_project_open": require_project,
        "find_object_by_path_robust": find_object,
        "emit_result": lambda value: capture.setdefault("result", value),
    }
    try:
        exec(compile(source, script_path, "exec"), namespace)
    except SystemExit as exit_value:
        assert exit_value.code == 0, exit_value.code
    assert "result" in capture, "semantic snapshot emitted no structured result"
    return capture["result"]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("snapshot_script", help="Patched get_ctrlx_semantic_snapshot.py path")
    args = parser.parse_args()
    script_path = os.path.abspath(args.snapshot_script)
    with open(script_path, "r", encoding="utf-8") as handle:
        source = handle.read()
    assert "ctrlX semantic snapshot contract v1 (2026-08-27)" in source
    assert ".save(" not in source, "read-only producer must not save the project"
    assert "expectedVariable" not in source, "producer must not accept expected values"
    assert "MAX_MAPPING_RECORDS = 2048" in source
    assert "MAPPING_SCOPES_B64" in source

    project_path = os.path.abspath(os.path.join(os.getcwd(), "fixture.project"))
    project = Project(project_path, dirty=False)
    tree_mapping = Mapping("Channel_1.Input", "GVL.TreeInput")
    connector_parameter = Parameter("p6", "Channel_6.Output", "Application.Peripherals.Out6")
    empty_parameter = Parameter("p7", "Channel_7.Output", "")
    module = Node(
        "Module",
        children=[tree_mapping],
        connectors=[Connector([connector_parameter, empty_parameter])],
    )
    coupler = Node("Coupler", children=[module])
    bus_root = Node("ethercat_master_instances_fixture", children=[coupler])
    project.lookup["Device/Realtime_Data/ethercat_master_instances_fixture"] = bus_root
    project.lookup["Device/Module"] = module
    module.lookup["Channel_1.Input"] = tree_mapping

    scopes = [{
        "devicePath": "Device/Realtime_Data/ethercat_master_instances_fixture",
        "recursive": True,
        "includeAllMappableChannels": True,
    }]
    result = execute_snapshot(script_path, scopes, [], project)
    assert result["contractVersion"] == 1, result
    assert result["contractId"] == "ctrlx-semantic-snapshot-v1", result
    assert result["producer"] == "codesys-persistent.get_ctrlx_semantic_snapshot", result
    assert result["adapterPatchId"] == "ctrlx-semantic-snapshot-v1", result
    assert result["dirtyStateVerified"] is True and result["projectDirty"] is False, result
    assert result["dirtyCheckCount"] == 2, result
    assert result["dirtyBefore"] is False and result["dirtyAfter"] is False, result
    assert result["scopeCount"] == 1 and result["explicitTargetCount"] == 0, result
    assert result["recordLimit"] == 2048 and result["recordCount"] == 3, result
    assert result["traversalFailureCount"] == 0, result
    assert result["recordsComplete"] is True, result
    assert result["scopes"][0]["resolved"] is True, result
    assert result["scopes"][0]["recordCount"] == 3, result
    assert [record["actualVariable"] for record in result["mappings"]] == [
        "Application.Peripherals.Out6",
        "",
        "GVL.TreeInput",
    ], result
    assert [record["sourceKind"] for record in result["mappings"]] == [
        "connector-parameter",
        "connector-parameter",
        "tree-channel",
    ], result
    assert result["mappings"][0]["relativeDevicePath"] == "Coupler/Module", result
    assert result["mappings"][0]["deviceIndexPath"] == "0/0", result
    assert result["mappings"][0]["parameterIndex"] == 0, result
    assert result["mappings"][0]["parameterId"] == "p6", result

    # A second read is byte-stable after excluding the absolute project fact.
    second = execute_snapshot(script_path, scopes, [], project)
    assert result["scopes"] == second["scopes"]
    assert result["mappings"] == second["mappings"]

    explicit = execute_snapshot(
        script_path,
        [],
        [{"devicePath": "Device/Module", "channelPath": "Channel_1.Input"}],
        project,
    )
    assert explicit["recordsComplete"] is True, explicit
    assert explicit["mappings"][0]["recordKind"] == "explicit-target", explicit
    assert explicit["mappings"][0]["actualVariable"] == "GVL.TreeInput", explicit

    missing_scope = execute_snapshot(
        script_path,
        [{
            "devicePath": "Device/Realtime_Data/Missing",
            "recursive": True,
            "includeAllMappableChannels": True,
        }],
        [],
        project,
    )
    assert missing_scope["recordsComplete"] is False, missing_scope
    assert missing_scope["scopes"][0]["resolved"] is False, missing_scope

    unknown_dirty = Project(project_path, expose_dirty=False)
    unknown_dirty.lookup["Device/Realtime_Data/ethercat_master_instances_fixture"] = bus_root
    no_dirty_result = execute_snapshot(script_path, scopes, [], unknown_dirty)
    assert no_dirty_result["dirtyStateVerified"] is False, no_dirty_result
    assert no_dirty_result["recordsComplete"] is False, no_dirty_result

    dirty_during = DirtyDuringTraversalProject(project_path)
    dirty_during.lookup["Device/Realtime_Data/ethercat_master_instances_fixture"] = bus_root
    dirty_during_result = execute_snapshot(script_path, scopes, [], dirty_during)
    assert dirty_during_result["dirtyStateVerified"] is True, dirty_during_result
    assert dirty_during_result["dirtyBefore"] is False, dirty_during_result
    assert dirty_during_result["dirtyAfter"] is True, dirty_during_result
    assert dirty_during_result["projectDirty"] is True, dirty_during_result
    assert dirty_during_result["recordsComplete"] is False, dirty_during_result

    broken_root = BrokenNode("BrokenBus")
    broken_project = Project(project_path, dirty=False)
    broken_project.lookup["Device/Realtime_Data/BrokenBus"] = broken_root
    broken_result = execute_snapshot(
        script_path,
        [{
            "devicePath": "Device/Realtime_Data/BrokenBus",
            "recursive": True,
            "includeAllMappableChannels": True,
        }],
        [],
        broken_project,
    )
    assert broken_result["traversalFailureCount"] == 1, broken_result
    assert broken_result["recordsComplete"] is False, broken_result

    print("read-only recursive ctrlX semantic snapshot + dirty-race regression: OK")


if __name__ == "__main__":
    main()
