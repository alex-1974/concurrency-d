#!/usr/bin/env python3
"""Build a Git-tree or working-tree package and an independent consumer."""
import argparse
import io
import json
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('compiler', help='dmd, ldc2, or a path to either compiler')
    parser.add_argument('--tree', default='HEAD', help='Git tree/commit to export; defaults to HEAD')
    parser.add_argument('--worktree', action='store_true',
                        help='validate the current working-tree package files')
    parser.add_argument('--expect-version', help='Require this version in the exported dub.sdl')
    args = parser.parse_args()
    compiler = Path(args.compiler).name
    if compiler == 'ldmd2':
        compiler = 'dmd'
    if compiler not in ('dmd', 'ldc2'):
        parser.error('compiler must resolve to dmd or ldc2')
    if args.worktree:
        version_manifest = (ROOT / 'dub.sdl').read_text()
    else:
        version_manifest = subprocess.check_output(
            ['git', 'show', f'{args.tree}:dub.sdl'], cwd=ROOT, text=True)
    source_version = re.search(r'^version \"([^\"]+)\"$', version_manifest, re.MULTILINE)
    assert source_version, 'source package manifest has no version'
    expected_version = args.expect_version or source_version.group(1)
    required = {'README.md', 'LICENSE', 'CHANGELOG.md', 'dub.sdl',
                'docs/EXECUTOR.md', 'docs/M0-PERFORMANCE-QUALIFICATION.md',
                'docs/V0.2-RELEASE-QUALIFICATION.md',
                'docs/V0.3-RELEASE-QUALIFICATION.md',
                'source/concurrency/package.d'}
    if args.worktree:
        if args.tree != 'HEAD':
            parser.error('--worktree cannot be combined with --tree')
        tree_label = 'WORKTREE'
        consumer_source = (ROOT / 'tests/public_api/main.d').read_bytes()
        package_paths = required | {
            path.relative_to(ROOT).as_posix() for path in (ROOT / 'source').rglob('*.d')
        }
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode='w') as tar:
            for name in sorted(package_paths):
                tar.add(ROOT / name, arcname=name, recursive=False)
        archive = buffer.getvalue()
    else:
        tree = subprocess.check_output(
            ['git', 'rev-parse', args.tree + '^{tree}'], cwd=ROOT, text=True).strip()
        tree_label = tree
        consumer_source = subprocess.check_output(
            ['git', 'show', f'{args.tree}:tests/public_api/main.d'], cwd=ROOT)
        tracked = subprocess.check_output(
            ['git', 'ls-tree', '-r', '--name-only', tree], cwd=ROOT, text=True).splitlines()
        leaked = [p for p in tracked if p.startswith(('research/', 'docs/research/', 'tools/research/'))]
        assert not leaked, 'research belongs in concurrency-d-research: ' + str(leaked)
        archive = subprocess.check_output(['git', 'archive', '--format=tar', tree], cwd=ROOT)
    with tempfile.TemporaryDirectory(prefix='concurrency-package-') as tmp:
        package = Path(tmp) / 'package'
        package.mkdir()
        with tarfile.open(fileobj=io.BytesIO(archive)) as tar:
            files = {m.name for m in tar.getmembers() if m.isfile()}
            assert required <= files, 'missing archive files: ' + str(required - files)
            unexpected = {f for f in files if f not in required and not (f.startswith('source/') and f.endswith('.d'))}
            assert not unexpected, 'unexpected archive files: ' + str(unexpected)
            tar.extractall(package, filter='data')
        manifest = (package / 'dub.sdl').read_text()
        assert 'license "MIT"' in manifest and 'benchmark' not in manifest
        version = re.search(r'^version "([^"]+)"$', manifest, re.MULTILINE)
        assert version, 'exported manifest has no version'
        assert version.group(1) == expected_version, (
            f'exported version {version.group(1)} != expected {expected_version}')
        assert 'MIT License' in (package / 'LICENSE').read_text()
        def run(command, cwd):
            subprocess.run(command, cwd=cwd, check=True, timeout=180)
        run(['dub', 'build', '--compiler=' + compiler, '--build=release'], package)
        consumer = Path(tmp) / 'consumer'
        (consumer / 'source').mkdir(parents=True)
        (consumer / 'source/app.d').write_bytes(consumer_source)
        (consumer / 'dub.json').write_text(json.dumps({
            'name': 'archive-public-consumer', 'targetType': 'executable',
            'dependencies': {'concurrency-d': {'path': str(package)}}}))
        run(['dub', 'run', '--compiler=' + compiler, '--build=release'], consumer)
        print(f'PACKAGE_GATE_PASS tree={tree_label} version={version.group(1)} compiler={compiler} files={len(files)}; archive and external consumer only, no registry release claim')


if __name__ == '__main__':
    main()
