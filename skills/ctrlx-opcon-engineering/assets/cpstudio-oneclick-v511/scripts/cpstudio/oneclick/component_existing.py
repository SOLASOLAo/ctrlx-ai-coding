# -*- coding: utf-8 -*-
"""Native offline component file wrapper. No project/session/online lifecycle."""
from __future__ import print_function
import datetime
import hashlib
import json
import os
import traceback
import scriptengine as se
from System.Diagnostics import Process

try:
    unicode
except NameError:
    unicode = str

HERE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(HERE, 'job.json'), 'rb') as stream:
    job = json.loads(stream.read().decode('utf-8-sig'))
output = os.path.join(HERE, 'component.json')
result = dict(operationId=job['operationId'], phase='component', complete=False,
              startedUtc=str(datetime.datetime.utcnow()))

def normalized(path):
    return os.path.normcase(os.path.realpath(path))

def inside(root, path):
    return normalized(path).startswith(normalized(root).rstrip(os.sep) + os.sep)

def require_project():
    project = se.projects.primary
    if project is None or normalized(project.path) != normalized(job['project']):
        raise RuntimeError('Wrong primary component project; never open or switch it here')
    applications = [node for node in project.get_children(True)
                    if getattr(node, 'is_application', False)]
    if job['projectRole'] == 'library' and applications:
        raise RuntimeError('Library role has an application; inspect the target')
    if job['projectRole'] == 'consumer' and not applications:
        raise RuntimeError('Consumer has no application to verify offline')
    for application in applications:
        if se.online.create_online_application(application).is_logged_in:
            raise RuntimeError('Component application is online; its owner must log out first')
    return project

try:
    pid = Process.GetCurrentProcess().Id
    if job['phase'] != 'component' or job['expectedPid'] != pid:
        raise RuntimeError('Component phase or native PID mismatch')
    role = job['projectRole']
    extension = '.library' if role == 'library' else '.project'
    if role not in ('library', 'consumer') or os.path.splitext(job['project'])[1].lower() != extension:
        raise RuntimeError('Unsupported component role or native extension')
    if not inside(job['isolatedRoot'], job['project']) or not inside(job['componentRoot'], job['project']):
        raise RuntimeError('Component project leaves the authorized isolated scope')
    reviewed = job['reviewedScript']
    source_file = os.path.join(job['componentRoot'], reviewed['path'])
    if not source_file.lower().endswith('.py') or not inside(job['componentRoot'], source_file) or not inside(os.path.join(job['componentRoot'], 'scripts', 'ple'), source_file):
        raise RuntimeError('Reviewed entry is outside scripts/ple')
    with open(os.path.join(HERE, 'component_payload.py'), 'rb') as stream:
        payload = stream.read()
    digest = hashlib.sha256(payload).hexdigest()
    if digest != reviewed['sha256'].lower():
        raise RuntimeError('Component payload no longer matches the reviewed file')
    project = require_project()
    if project.dirty:
        raise RuntimeError('Save the owned component through its existing workflow before dispatch')
    scope = dict(__name__='__main__', __file__=source_file, TARGET_PROJECT=project,
                 COMPONENT_JOB=job)
    # Trusted, reviewed native file: this is not a Python security sandbox.
    exec(compile(payload.decode('utf-8-sig'), source_file, 'exec'), scope)
    current = require_project()
    if current.dirty:
        raise RuntimeError('Reviewed component script must explicitly save its own changes')
    evidence = scope.get('COMPONENT_RESULT', scope.get('result', {}))
    json.dumps(evidence)  # Fail clearly for non-JSON evidence before writing a receipt.
    result.update(project=unicode(current.path), projectRole=role, pid=pid,
                  scriptSha256=digest, scriptReturned=True, saved=True,
                  offline=True, evidence=evidence)
    if role == 'library':
        info = current.get_project_info()
        result['libraryInfo'] = dict(title=unicode(info.title), company=unicode(info.company),
                                     version=unicode(info.version))
    result['complete'] = True
except Exception:
    result['exception'] = traceback.format_exc()
finally:
    result['finishedUtc'] = str(datetime.datetime.utcnow())
    temporary = output + '.tmp'
    with open(temporary, 'wb') as stream:
        stream.write(json.dumps(result, ensure_ascii=True, indent=2).encode('utf-8'))
    os.rename(temporary, output)
    print('COMPONENT_NATIVE ' + json.dumps(result, ensure_ascii=True))
if not result['complete']:
    raise RuntimeError(result.get('exception', 'Component file execution failed'))
