"""Offline source/configuration boundary checks; never contacts an engineering session."""
import re
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NATIVE = "http://www.inosoft.com/DTD/SmartForms"
WPF = "http://schemas.microsoft.com/winfx/2006/xaml/presentation"
ATTACHED = "clr-namespace:OpCon.WpfIntegration;assembly=OpCon.WpfIntegration"


def main():
    runtime = "\n".join((ROOT / name).read_text(encoding="utf-8-sig") for name in (
        "NativeMarkup.cs", "NativeReadSet.cs", "NativePlacement.cs", "WpfViewHost.cs"))
    forbidden = r"PerformClick|SendInput|SendMessage|BindingFlags|GetField\s*\(|VWSet|SetTokenRequest|TcpClient|OpcClient|\.Editable(?:State|Value)\s*="
    assert not re.search(forbidden, runtime), "Runtime contains a forbidden command/transport/reflection path"
    template = (ROOT / "examples/IntegrationPage.sfc").read_text(encoding="utf-8-sig")
    template = template.replace("<%=@ownerObject.ExtensionInstance.HmiFullName%>", "Offline.UnitA.Extension")
    page = ET.fromstring(template)
    controls = page.find(f"{{{NATIVE}}}SmartControl/{{{NATIVE}}}property.Controls")
    assert controls is not None
    native = {c.attrib["Name"]: c for c in controls if c.tag.rsplit("}", 1)[-1] != "WpfViewHost"}
    assert len(native) == 3
    assert all(c.attrib.get("UseTokenHandling") == "True" for c in native.values())
    host = next(c for c in controls if c.tag.endswith("}WpfViewHost"))
    assert host.attrib["ItemPrefix"] == "Offline.UnitA.Extension"
    assert host.attrib["HeartbeatItem"] == "Status.ScanCount"
    layout = ET.parse(ROOT / "examples/IntegrationDemo.xaml").getroot()
    names = [e.attrib[f"{{{ATTACHED}}}NativeSlot.ControlName"] for e in layout.iter()
             if f"{{{ATTACHED}}}NativeSlot.ControlName" in e.attrib]
    assert set(names) == set(native) and len(names) == len(set(names))
    assert {c.attrib["ManualFunctionName"] for c in native.values() if c.tag.endswith("}Mod_ManualFunctionKey")} == {"Pulse", "Hold"}
    text_root = ET.parse(ROOT / "examples/Texts.osd").getroot()
    groups = {g.attrib["name"]: {t.attrib["name"]: t for t in g.findall("HmiText")}
              for g in text_root.iter("HmiTextGroup")}
    for element in layout.iter():
        assert element.tag != f"{{{WPF}}}Button", "Sample command input must remain a real native control"
        group = element.attrib.get(f"{{{ATTACHED}}}NativeText.Group")
        key = element.attrib.get(f"{{{ATTACHED}}}NativeText.Key")
        if key:
            entry = groups[group][key]
            assert {t.attrib["lcid"] for t in entry.findall("Text")} == {"1033", "2052"}
    print("OFFLINE package checks: native siblings, token handling, slots, prefix, heartbeat, bilingual resources and no command/transport bypass")


if __name__ == "__main__":
    main()
