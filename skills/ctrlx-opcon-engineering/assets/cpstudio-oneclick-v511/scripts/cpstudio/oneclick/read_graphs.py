"""Read SFC graphs through the already-running PLE REST service; GET requests only."""
import importlib.util
import json
import pathlib
import sys
import urllib.parse
import urllib.request


def snapshot(job, get):
    project = get('/projects/current')
    if pathlib.Path(project['path']).resolve() != pathlib.Path(job['project']).resolve():
        raise RuntimeError('REST service has a different primary project')
    if project['profileName'] != job['profile']:
        raise RuntimeError('REST service has a different PLE profile')
    app = get('/devices/Device/Plc%20Logic/Application')
    if app.get('isOnline') is not False:
        raise RuntimeError('REST cannot confirm that Application is offline')
    graphs = {}
    for item in job['graphicalObjects']:
        node = get(item['apiPath'])
        if node['language'] != 'SFC' or not node['implementation']:
            raise RuntimeError('Expected a readable SFC graph: ' + item['path'])
        graphs[item['path']] = node
    return dict(operationId=job['operationId'], graphs=graphs)


def verify(before, after, graph_key):
    if before['operationId'] != after['operationId'] or before['graphs'].keys() != after['graphs'].keys():
        raise RuntimeError('Graph checkpoint does not belong to this operation')
    for path, old in before['graphs'].items():
        new = after['graphs'][path]
        if graph_key(old['implementation']) != graph_key(new['implementation']):
            raise RuntimeError('Export changed a protected SFC graph: ' + path)
        if sorted(old['children']) != sorted(new['children']):
            raise RuntimeError('Export changed SFC action/transition children: ' + path)
        for key in old:
            if key not in ('implementation', 'declaration', 'children') and old[key] != new.get(key):
                raise RuntimeError('Export changed SFC properties: ' + path + ' / ' + key)


def load_graph_key(engineering_root):
    source = pathlib.Path(engineering_root) / 'scripts' / 'plc' / 'sfc_graph_key.py'
    if not source.is_file():
        source = pathlib.Path(__file__).resolve().parent.parent.parent / 'plc' / 'sfc_graph_key.py'
    if not source.is_file():
        raise FileNotFoundError('Copy the maintained scripts/plc/sfc_graph_key.py with read_graphs.py: ' + str(source))
    spec = importlib.util.spec_from_file_location('oneclick_sfc_graph_key', source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.graph_key


def main():
    job_file = pathlib.Path(sys.argv[1]).resolve()
    phase = sys.argv[2]
    if phase not in ('before', 'after'): raise RuntimeError('Unknown graph checkpoint phase')
    job = json.loads(job_file.read_text(encoding='utf-8-sig'))
    base = urllib.parse.urlparse(job['restBase'])
    if base.scheme != 'http' or base.hostname not in ('localhost', '127.0.0.1'):
        raise RuntimeError('Only the existing local engineering REST service may be used')
    http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    def get(path):
        with http.open(job['restBase'].rstrip('/') + path, timeout=20) as response:
            return json.load(response)
    observed = snapshot(job, get)
    if phase == 'after':
        graph_key = load_graph_key(job['engineeringRoot'])
        before = json.loads((job_file.parent / 'before-graphs.json').read_text(encoding='utf-8'))
        verify(before, observed, graph_key)
    target = job_file.parent / (phase + '-graphs.json')
    target.write_text(json.dumps(observed, indent=2, ensure_ascii=True), encoding='utf-8')
    print('SFC graphs checked: ' + str(len(observed['graphs'])))


if __name__ == '__main__':
    main()
