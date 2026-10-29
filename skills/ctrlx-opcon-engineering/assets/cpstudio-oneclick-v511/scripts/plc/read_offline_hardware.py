# -*- coding: utf-8 -*-
"""Read the already-open native IDE project, including bit subchannels.

IronPython ScriptEngine. Inject AUDIT_PROJECT and AUDIT_OUTPUT. Does not open,
save, edit, or use online APIs. IOE and PLE own their respective project types.
"""
import json
import os
import scriptengine as se

p = se.projects.primary
if p is None or os.path.normcase(p.path) != os.path.normcase(AUDIT_PROJECT):
    raise RuntimeError('Open project does not match AUDIT_PROJECT')

devices = []
mappings = []

def channel(q, device_path, connector, parent_parameter):
    if q.is_mappable_io:
        m = q.io_mapping
        mappings.append(dict(
            device=device_path, connector=connector,
            identifier=unicode(q.identifier),
            name=unicode(getattr(q, 'name', getattr(q, 'visible_name', ''))),
            bits=int(q.bit_size), direction=unicode(parent_parameter.channel_type),
            variable=unicode(m.variable or ''),
            automatic_address=unicode(m.automatic_iec_address),
            manual_address=unicode(m.manual_iec_address),
            maps_existing=bool(m.maps_to_existing_variable)))
    if q.has_sub_elements:
        for i in range(q.Count):
            channel(q[i], device_path, connector, parent_parameter)

def walk(obj, prefix):
    path = prefix + '/' + unicode(obj.get_name())
    if getattr(obj, 'is_device', False):
        ident = obj.get_device_identification()
        devices.append(dict(path=path, type=int(ident.type), id=unicode(ident.id), version=unicode(ident.version)))
        for ci, c in enumerate(obj.connectors):
            for q in c.host_parameters:
                channel(q, path, ci, q)
    for child in obj.get_children(False):
        walk(child, path)

for obj in p.get_children(False):
    walk(obj, '')
result = dict(project=unicode(p.path), dirty=bool(p.dirty), devices=devices, mappings=mappings)
with open(AUDIT_OUTPUT, 'wb') as f:
    f.write(json.dumps(result, indent=2, ensure_ascii=True).encode('utf-8'))
print('OFFLINE_HARDWARE devices=%d mappings=%d bound=%d' % (len(devices), len(mappings), sum(bool(x['variable']) for x in mappings)))
print('SCRIPT_SUCCESS')
