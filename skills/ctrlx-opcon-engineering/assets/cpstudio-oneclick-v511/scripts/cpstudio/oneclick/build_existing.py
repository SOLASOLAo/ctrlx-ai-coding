# -*- coding: utf-8 -*-
"""Execute in the existing PLE ScriptEngine; never opens another IDE/project."""
from __future__ import print_function
import datetime
import json
import os
import shutil
import traceback
import scriptengine as se

try:
    unicode
except NameError:
    unicode = str

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, 'job.json'), 'rb') as stream:
    job = json.load(stream)
phase = job['phase']
output = os.path.join(HERE, phase + '.json')
result = dict(operationId=job['operationId'], phase=phase,
              startedUtc=str(datetime.datetime.utcnow()), complete=False,
              physicalOperations=False)

def normalized(path):
    return os.path.normcase(os.path.abspath(path))

def sources(app):
    records = {}
    def walk(obj, path):
        name = unicode(obj.get_name())
        path = path + '/' + name if path else name
        code = {}
        for key in ('textual_declaration', 'textual_implementation'):
            try:
                section = getattr(obj, key, None)
                text = unicode(section.text).replace('\r\n', '\n').replace('\r', '\n') if section is not None else ''
                if text: code[key] = text
            except Exception:
                # Native SFC/folder nodes do not expose every textual section.
                # Required objects must still exist; SFC graphs are checked separately.
                pass
        if code: records[path] = code
        for child in obj.get_children(False):
            if path == 'Application' and unicode(child.get_name()) in ('Library Manager', 'Task Configuration', 'Symbols'):
                continue
            walk(child, path)
    walk(app, '')
    return records

def hardware(project):
    scope = dict(AUDIT_PROJECT=project.path, unicode=unicode,
                 AUDIT_OUTPUT=os.path.join(HERE, phase + '-hardware.json'))
    script = os.path.join(job['engineeringRoot'], 'scripts', 'plc', 'read_offline_hardware.py')
    with open(script, 'rb') as stream:
        code = stream.read().decode('utf-8-sig')
    exec(compile(code, script, 'exec'), scope)
    return scope['result']

def bound_mappings(snapshot):
    return sorted((m['device'], m['connector'], m['identifier'], m['variable'],
                   m['automatic_address'], m['manual_address'], m['maps_existing'])
                  for m in snapshot['mappings'] if m['variable'])

def symbols(app):
    configs = [x for x in app.get_children(False) if getattr(x, 'is_symbol_config', False)]
    if len(configs) != 1: raise RuntimeError('Expected one native Symbol Configuration')
    config = configs[0]
    properties = ('client_side_layout_calculator_guid', 'enable_direct_io_access', 'content_feature_flags',
                  'symbol_attribute_filter_type', 'symbol_attribute_filter_data', 'symbol_comment_filter_type')
    settings = dict((name, unicode(getattr(config, name))) for name in properties)
    accesses = []
    for kind, collection in [('symbols', config.get_only_configured_signatures()), ('types', config.get_only_configured_datatypes())]:
        for signature in collection:
            for variable in signature.variables:
                accesses.append((kind, unicode(signature.full_qualified_name), unicode(signature.library_id),
                                 unicode(variable.name), unicode(variable.configured_access)))
    return dict(settings=settings, accesses=sorted(accesses))

try:
    project = se.projects.primary
    if project is None or normalized(project.path) != normalized(job['project']):
        raise RuntimeError('Wrong primary project; expected ' + job['project'])
    app = project.active_application
    if app is None: raise RuntimeError('No active PLC application')
    online = se.online.create_online_application(app)
    if online.is_logged_in: raise RuntimeError('PLC application is online; log out first')
    result['project'] = unicode(project.path)
    result['offline'] = True
    if phase == 'preflight': project.save()
    current = sources(app)
    current_hardware = hardware(project)
    current_symbols = symbols(app)
    result.update(sources=current, hardware=current_hardware,
                  symbols=current_symbols, sourceCount=len(current))
    if phase == 'preflight':
        if any(x[0] == 'types' and x[1].startswith('.') and x[2] not in ('', 'None')
               for x in current_symbols['accesses']):
            raise RuntimeError('Symbol library namespaces are unresolved in this session; run native compile_project once, then start a new operation')
        for path in job['preserveObjects']:
            if path not in current: raise RuntimeError('Required protected object is missing: ' + path)
        backup = os.path.join(HERE, 'before.project')
        shutil.copyfile(project.path, backup)
        result['checkpoint'] = backup
    elif phase == 'build':
        with open(os.path.join(HERE, 'preflight.json'), 'rb') as stream:
            before = json.load(stream)
        if before['operationId'] != job['operationId'] or not before['complete']:
            raise RuntimeError('Preflight does not belong to this operation')
        lost = [p for p in job['preserveObjects'] if current.get(p) != before['sources'].get(p)]
        if lost: raise RuntimeError('Export changed protected PLC source: ' + '; '.join(lost))
        for hook in job['hooks']:
            code = current.get(hook['object'])
            if code is None: raise RuntimeError('Required hook object is missing: ' + hook['object'])
            text = '\n'.join(code.values())
            for token in hook['tokens']:
                if token not in text: raise RuntimeError('Required hook token is missing: ' + token)
        if bound_mappings(current_hardware) != bound_mappings(before['hardware']):
            raise RuntimeError('Export changed existing I/O bindings; inspect before building')
        if current_symbols['settings'] != before['symbols']['settings']:
            raise RuntimeError('Export changed Symbol Configuration settings')
        result['protectedSourcesPreserved'] = True
        result['existingIoBindingsPreserved'] = True
        result['boundIoCount'] = len(bound_mappings(current_hardware))
        result['configuredSymbolAccessCount'] = len(current_symbols['accesses'])
        categories = [c for c in se.system.get_message_categories()
                      if se.system.get_message_category_description(c) in ('Build', 'Additional code checks')]
        for category in categories: se.system.clear_messages(category)
        app.clean()
        app.build()
        # A fresh PLE session can register compiler categories only on its first build.
        categories = [c for c in se.system.get_message_categories()
                      if se.system.get_message_category_description(c) in ('Build', 'Additional code checks')]
        if not categories: raise RuntimeError('Compiler message categories are unavailable after native build')
        messages = [dict(severity=str(m.severity), text=unicode(m.text))
                    for c in categories for m in se.system.get_message_objects(c)]
        result['messages'] = messages
        result['errors'] = sum(m['severity'].lower() == 'error' for m in messages)
        result['warnings'] = sum(m['severity'].lower() == 'warning' for m in messages)
        # The existing adapter baseline collapses whitespace; native m.text has
        # a double space in the vendor OPC.UA warning. Keep raw messages above.
        signature = lambda text: ' '.join(unicode(text).split())
        expected = sorted(signature(text) for text in job['allowedWarnings'])
        actual = sorted(signature(m['text']) for m in messages if m['severity'].lower() == 'warning')
        result['warningBaselineMatches'] = actual == expected
        if result['errors']: raise RuntimeError('Fresh PLC build has errors')
        if actual != expected: raise RuntimeError('Fresh build warnings differ from the reviewed baseline')
        # Library-qualified type names can temporarily have an empty namespace
        # after Export/failed compilation. Compare the freshly compiled Symbol
        # model, retaining the original checkpoint and exact access rights.
        current_symbols = symbols(app)
        result['symbols'] = current_symbols
        result['configuredSymbolAccessCount'] = len(current_symbols['accesses'])
        if current_symbols['settings'] != before['symbols']['settings']:
            raise RuntimeError('Build changed Symbol Configuration settings')
        if not set(tuple(x) for x in before['symbols']['accesses']).issubset(set(current_symbols['accesses'])):
            raise RuntimeError('Export removed or changed an existing configured symbol access')
        result['existingSymbolAccessesPreserved'] = True
        project.save()
    else:
        raise RuntimeError('Unknown phase: ' + phase)
    result['saved'] = not project.dirty
    if not result['saved']: raise RuntimeError('Project remains dirty after save')
    result['complete'] = True
except Exception:
    result['exception'] = traceback.format_exc()
finally:
    result['finishedUtc'] = str(datetime.datetime.utcnow())
    temporary = output + '.tmp'
    with open(temporary, 'wb') as stream:
        stream.write(json.dumps(result, ensure_ascii=True, indent=2).encode('utf-8'))
    if os.path.exists(output): os.remove(output)
    os.rename(temporary, output)
    print('CPSTUDIO_ONECLICK ' + json.dumps(dict((k,v) for k,v in result.items()
                                             if k not in ('sources','hardware','symbols','messages')), ensure_ascii=True))
if not result['complete']: raise RuntimeError(result.get('exception', 'One-click phase failed'))
