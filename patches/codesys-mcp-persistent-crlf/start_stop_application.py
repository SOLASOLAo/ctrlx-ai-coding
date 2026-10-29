# ctrlX typed native readback (2026-10-10)
import os, sys, traceback, scriptengine as script_engine

PROJECT_FILE_PATH = "{PROJECT_FILE_PATH}"
APP_ACTION = "{APP_ACTION}"

try:
    project = script_engine.projects.primary
    if project is None or os.path.normcase(os.path.abspath(project.path)) != os.path.normcase(os.path.abspath(PROJECT_FILE_PATH)):
        raise RuntimeError('The expected project must already be primary; start/stop never opens a project')
    action = APP_ACTION.lower()
    if action not in ('start', 'stop'):
        raise ValueError('Expected start or stop')
    application = project.active_application
    if application is None:
        applications = [obj for obj in project.get_children(True) if getattr(obj, 'is_application', False)]
        if len(applications) != 1:
            raise RuntimeError('Select exactly one target Application before start/stop')
        application = applications[0]
    online = with_executor(script_engine.online.create_online_application, application)
    if with_executor(lambda: online.is_logged_in) is not True:
        raise RuntimeError('The target must be logged in before verifying start/stop')
    state = str(with_executor(lambda: online.application_state)).lower()
    if state not in ('run', 'stop'):
        raise RuntimeError('Native application state is not RUN or STOP: ' + state)
    expected = 'run' if action == 'start' else 'stop'
    if state != expected:
        with_executor(online.start if action == 'start' else online.stop)
    after = str(with_executor(lambda: online.application_state)).lower()
    if with_executor(lambda: online.is_logged_in) is not True or after != expected:
        raise RuntimeError('Native start/stop readback did not confirm the requested state')
    print('State After: ' + after)
    print('Logged In After: True')
    print('SCRIPT_SUCCESS: Native start/stop readback verified.')
    sys.exit(0)
except Exception:
    print('SCRIPT_ERROR: ' + traceback.format_exc())
    sys.exit(1)
