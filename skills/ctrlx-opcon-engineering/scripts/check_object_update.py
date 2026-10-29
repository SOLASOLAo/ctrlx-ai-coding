"""Read-only CpStudio OOD/library version plan and saved-selection check."""
import argparse
import json
import pathlib
import re
import sys
import uuid
import xml.etree.ElementTree as ET


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){3}", value):
        raise ValueError("Expected an exact four-part version, not latest or a version family")
    return value


def selections(path):
    root = ET.parse(path).getroot()
    if root.tag != "ObjectVersions":
        raise ValueError("Expected a native ObjectVersions.xml")
    result = {}
    for node in root.findall("Object"):
        ooid = str(uuid.UUID(node.attrib["ooid"]))
        if ooid in result:
            raise ValueError("Duplicate OOID in saved selections: " + ooid)
        result[ooid] = dict(name=node.attrib["name"], version=version(node.attrib["version"]))
    return result


def inspect(ood, versions, target_version, expected_current=None, library_version=None,
            after_versions=None):
    ood = pathlib.Path(ood).resolve()
    root = ET.parse(ood).getroot()
    if root.tag != "Object":
        raise ValueError("Expected a CpStudio Object definition")
    ooid = str(uuid.UUID(root.attrib["refId"]))
    target = version(target_version)
    if version(root.attrib["version"]) != target:
        raise ValueError("Source OOD does not match the exact requested target version")
    before = selections(versions)
    if ooid not in before:
        raise ValueError("Target OOID is not in this project; use the component-install workflow")
    current = before[ooid]
    if current["name"] != root.attrib["objectName"]:
        raise ValueError("Saved object name and source identity differ; review the migration")
    if expected_current is not None and current["version"] != version(expected_current):
        raise ValueError("Current saved object version changed; refresh the update plan")
    result = dict(readOnly=True, object=dict(ooid=ooid, name=current["name"],
                  currentVersion=current["version"], targetVersion=target, source=str(ood)),
                  library=None, savedSelectionVerified=False, nativeReloadVerified=False)
    descriptor = ood.parent / "Library" / "Library.osd"
    if descriptor.exists():
        libraries = ET.parse(descriptor).getroot().findall("./PlcContentDef/Library")
        if len(libraries) != 1:
            raise ValueError("This checker requires one native library entry; inspect this descriptor natively")
        library = libraries[0].attrib
        if library_version is None or version(library["version"]) != version(library_version):
            raise ValueError("Declare the exact PLC library version separately from the OOD version")
        library_file = (descriptor.parent / library["file"]).resolve()
        if not library_file.is_file():
            raise ValueError("Declared native library file is missing: " + str(library_file))
        result["library"] = dict(version=library["version"], file=str(library_file),
                                 vendor=library.get("vendor", ""), descriptor=str(descriptor))
    elif library_version is not None:
        raise ValueError("A PLC library version was supplied but Library/Library.osd is missing")
    if after_versions is not None:
        after = selections(after_versions)
        expected = dict(before)
        expected[ooid] = dict(name=current["name"], version=target)
        if after != expected:
            raise ValueError("Saved selection has the wrong target or an unplanned object/dependency change")
        result["savedSelectionVerified"] = True
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ood", required=True)
    parser.add_argument("--versions", required=True, help="Saved or preserved before ObjectVersions.xml")
    parser.add_argument("--target-version", required=True)
    parser.add_argument("--expected-current")
    parser.add_argument("--library-version")
    parser.add_argument("--after-versions", help="Saved after ObjectVersions.xml; rejects unrelated changes")
    args = parser.parse_args()
    try:
        result = inspect(args.ood, args.versions, args.target_version, args.expected_current,
                         args.library_version, args.after_versions)
    except (OSError, ValueError, KeyError, ET.ParseError) as error:
        print("Object update check stopped: " + str(error), file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
