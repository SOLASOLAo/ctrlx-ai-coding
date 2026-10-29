# ctrlX typed native readback (2026-10-10)
import os, sys, traceback, json, scriptengine as script_engine

PROJECT_FILE_PATH = "{PROJECT_FILE_PATH}"

try:
    project = script_engine.projects.primary
    if project is None or os.path.normcase(os.path.abspath(project.path)) != os.path.normcase(os.path.abspath(PROJECT_FILE_PATH)):
        raise RuntimeError('The expected project must already be primary; library listing never opens a project')
    scope = project.active_application
    if scope is None:
        applications = [obj for obj in project.get_children(True) if getattr(obj, 'is_application', False)]
        if len(applications) > 1:
            raise RuntimeError('Select the intended Application before listing its libraries')
        scope = applications[0] if applications else project
    factory = getattr(scope, 'get_library_manager', None)
    if callable(factory):
        manager = factory()
    else:
        managers = [obj for obj in scope.get_children(True) if callable(getattr(obj, 'get_libraries', None))]
        if len(managers) != 1:
            raise RuntimeError('Cannot identify exactly one native Library Manager in the selected scope')
        manager = managers[0]
    if manager is None or not callable(getattr(manager, 'get_libraries', None)):
        raise RuntimeError('Native Library Manager enumeration is unavailable')
    references = manager.get_libraries()
    if references is None:
        raise RuntimeError('Native library enumeration returned no result')
    libraries = []
    for reference in references:
        identifier = _to_unicode(unicode(reference))
        entry = dict(name=identifier, identifier=identifier)
        for key in ('name', 'version', 'company'):
            value = getattr(reference, key, None)
            if value is not None:
                entry[key] = _to_unicode(unicode(value))
        libraries.append(entry)
    # Preserve the broker's IronPython UTF-8 wire contract, including non-ASCII names.
    text = json.dumps(libraries, ensure_ascii=False)
    if isinstance(text, unicode):
        text = text.encode('utf-8')
    sys.stdout.write('### LIBRARIES_START ###\n')
    sys.stdout.write(text)
    sys.stdout.write('\n### LIBRARIES_END ###\n')
    print('Library Count: %d' % len(libraries))
    print('SCRIPT_SUCCESS: Native Library Manager references read.')
    sys.exit(0)
except Exception:
    print('SCRIPT_ERROR: ' + traceback.format_exc())
    sys.exit(1)
