#!/usr/bin/env python3
"""Build an exported Git tree and an independent public API consumer."""
import argparse
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', choices=['dmd', 'ldc2'])
    parser.add_argument('--tree', default='HEAD', help='Git tree/commit to export; defaults to HEAD')
    args = parser.parse_args()
    tree = subprocess.check_output(['git', 'rev-parse', args.tree + '^{tree}'], cwd=ROOT, text=True).strip()
    archive = subprocess.check_output(['git', 'archive', '--format=tar', tree], cwd=ROOT)
    with tempfile.TemporaryDirectory(prefix='concurrency-package-') as tmp:
        package = Path(tmp) / 'package'
        package.mkdir()
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            files = {m.name for m in tar.getmembers() if m.isfile()}
            required = {'README.md', 'LICENSE', 'CHANGELOG.md', 'dub.sdl',
                        'docs/EXECUTOR.md', 'source/concurrency/package.d'}
            assert required <= files, 'missing archive files: ' + str(required - files)
            unexpected = {f for f in files if f not in required and not (f.startswith('source/') and f.endswith('.d'))}
            assert not unexpected, 'unexpected archive files: ' + str(unexpected)
            tar.extractall(package, filter='data')
        manifest = (package / 'dub.sdl').read_text()
        assert 'license "MIT"' in manifest and 'benchmark' not in manifest
        assert 'MIT License' in (package / 'LICENSE').read_text()
        def run(command, cwd):
            subprocess.run(command, cwd=cwd, check=True, timeout=180)
        run(['dub', 'build', '--compiler=' + args.compiler, '--build=release'], package)
        consumer = Path(tmp) / 'consumer'
        (consumer / 'source').mkdir(parents=True)
        (consumer / 'source/app.d').write_bytes((ROOT / 'tests/public_api/main.d').read_bytes())
        (consumer / 'dub.json').write_text(json.dumps({
            'name': 'archive-public-consumer', 'targetType': 'executable',
            'dependencies': {'concurrency-d': {'path': str(package)}}}))
        run(['dub', 'run', '--compiler=' + args.compiler, '--build=release'], consumer)
        print(f'PACKAGE_GATE_PASS tree={tree} compiler={args.compiler} files={len(files)}; archive and external consumer only, no registry release claim')


if __name__ == '__main__':
    main()
