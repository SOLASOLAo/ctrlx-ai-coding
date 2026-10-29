# ctrlX typed native readback (2026-10-10)
import os, sys, traceback, scriptengine as script_engine

PROJECT_FILE_PATH = "{PROJECT_FILE_PATH}"

try:
    project = script_engine.projects.primary
    if project is None or os.path.normcase(os.path.abspath(project.path)) != os.path.normcase(os.path.abspath(PROJECT_FILE_PATH)):
        raise RuntimeError('The expected project must already be primary; disconnect never opens a project')
    application = project.active_application
    if application is None:
        applications = [obj for obj in project.get_children(True) if getattr(obj, 'is_application', False)]
        if len(applications) != 1:
            raise RuntimeError('Select exactly one target Application before disconnecting')
        application = applications[0]
    online = with_executor(script_engine.online.create_online_application, application)
    logged_in = with_executor(lambda: online.is_logged_in)
    if logged_in is not True and logged_in is not False:
        raise RuntimeError('Native login state is unavailable')
    if logged_in:
        with_executor(online.logout)
    if with_executor(lambda: online.is_logged_in) is not False:
        raise RuntimeError('Logout was not verified; do not close or replace this project')
    print('Logged In After: False')
    print('SCRIPT_SUCCESS: Native logout readback verified.')
    sys.exit(0)
except Exception:
    print('SCRIPT_ERROR: ' + traceback.format_exc())
    sys.exit(1)
