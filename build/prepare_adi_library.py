"""Plan required ADI IP packages and export pinned tracked sources, not EDA outputs."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import zipfile

COMMIT = '2156ac7e874a1dc321d9f64a325009fafe563419'


def plan(root, inventory):
    root = Path(root).resolve()
    library = root / 'library'
    locations = {}
    for makefile in library.rglob('Makefile'):
        if not (makefile.parent / (makefile.parent.name + '_ip.tcl')).is_file():
            continue
        match = re.search(r'^LIBRARY_NAME\s*:?=\s*(\w+)\s*$', makefile.read_text(), re.M)
        if match:
            locations.setdefault(match[1], []).append(makefile.parent.relative_to(library).as_posix())
    required = sorted({row['vlnv'].split(':')[2] for row in inventory['instances']
                       if row['vlnv'].startswith('analog.com:user:')})
    direct = []
    for name in required:
        if len(locations.get(name, [])) != 1:
            raise ValueError('Missing or ambiguous component: ' + name)
        direct.append(locations[name][0])
    order, visiting, done = [], set(), set()
    dependencies = {}

    def visit(name):
        parts = PurePosixPath(name).parts
        if not re.fullmatch(r'[A-Za-z0-9_/]+', name) or '..' in parts or name.startswith('/'):
            raise ValueError('Nonliteral or escaping dependency: ' + name)
        if name in visiting:
            raise ValueError('Library dependency cycle: ' + name)
        if name in done:
            return
        folder = library / name
        makefile = folder / 'Makefile'
        script = folder / (folder.name + '_ip.tcl')
        if not makefile.is_file() or not script.is_file():
            raise ValueError('Missing dependency source: ' + name)
        visiting.add(name)
        deps = []
        for match in re.finditer(r'^XILINX_(?:LIB|INTERFACE)_DEPS\s*(?:\+=|:=|=)\s*(.*?)\s*$',
                                 makefile.read_text(), re.M):
            deps.extend(match[1].split('#', 1)[0].split())
        dependencies[name] = deps
        for dep in deps:
            visit(dep)
        visiting.remove(name)
        done.add(name)
        order.append(name)

    # Exact path identities avoid the original helper's regexp deduplication.
    for name in ['interfaces', 'jesd204/interfaces'] + direct:
        visit(name)
    return {'status': 'ADI_SOURCE_PACKAGING_PLAN', 'direct_components': required,
            'direct_paths': direct, 'order': order, 'dependencies': dependencies,
            'eda_executed': False, 'official_board_build_executed': False}


def prepare(adi_root, inventory_path, out):
    adi_root, out = Path(adi_root).resolve(), Path(out).resolve()
    if out.exists():
        raise FileExistsError('Use a fresh output directory')
    revision = subprocess.check_output(['git', '-C', str(adi_root), 'rev-parse', 'HEAD'], text=True).strip()
    if revision != COMMIT:
        raise ValueError('ADI commit differs')
    dirty = subprocess.check_output(['git', '-C', str(adi_root), 'status', '--porcelain',
                                     '--untracked-files=no'], text=True)
    if dirty:
        raise ValueError('ADI tracked source differs')
    inventory_path = Path(inventory_path).resolve()
    inventory = json.loads(inventory_path.read_text(encoding='utf-8'))
    out.mkdir(parents=True)
    archive = out / 'adi_tracked.zip'
    subprocess.run(['git', '-C', str(adi_root), 'archive', '--format=zip',
                    '--output', str(archive), COMMIT], check=True)
    source = out / 'source'
    with zipfile.ZipFile(archive) as entries:
        for item in entries.infolist():
            if not (source / item.filename).resolve().is_relative_to(source):
                raise ValueError('Archive path escapes source directory')
        entries.extractall(source)
    # Compute dependencies from the archive, never local generated Makefiles.
    result = plan(source, inventory)
    for name in result['order']:
        if (source / 'library' / name / 'component.xml').exists():
            raise ValueError('Archive unexpectedly contains a packaged component: ' + name)
    with archive.open('rb') as stream:
        archive_digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    result.update({'commit': revision, 'source_root': str(source),
                   'archive_sha256': archive_digest,
                   'inventory_sha256': hashlib.sha256(inventory_path.read_bytes()).hexdigest()})
    (out / 'plan.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--adi-root', type=Path, required=True)
    parser.add_argument('--inventory', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'src/platform/inputs_inventory.json')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.adi_root, args.inventory, args.out), indent=2))


if __name__ == '__main__':
    main()
