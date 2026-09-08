#!/usr/bin/env python3
"""Tracked working-tree source metrics, separate from vendor/data/cache footprint."""

from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
import os
import subprocess
import sys


LANGUAGES = {
    '.zig': 'Zig', '.c': 'C/C++', '.h': 'C/C++', '.cpp': 'C/C++', '.hpp': 'C/C++',
    '.vert': 'GLSL', '.frag': 'GLSL', '.comp': 'GLSL', '.glsl': 'GLSL', '.geom': 'GLSL',
    '.sh': 'Shell', '.py': 'Python', '.js': 'JavaScript/TypeScript', '.ts': 'JavaScript/TypeScript',
    '.nix': 'Nix', '.css': 'UI markup/style', '.rcss': 'UI markup/style',
    '.rml': 'UI markup/style', '.html': 'UI markup/style',
}
CONFIG = {'.json', '.jsonc', '.yaml', '.yml', '.toml', '.zon', '.lock'}


def main():
    root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
    output = Path(sys.argv[1] if len(sys.argv) > 1 else 'CODEBASE_REPORT.md').absolute()
    tracked = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).split(b'\0')
    counts = defaultdict(lambda: [0, 0, 0])
    excluded = defaultdict(lambda: [0, 0])
    for raw_path in sorted(set(tracked) - {b''}):
        relative = Path(os.fsdecode(raw_path))
        file = root / relative
        if file.absolute() == output or relative == Path('CODEBASE_REPORT.md'):
            continue
        if file.is_symlink() or not file.is_file():
            excluded['Symlink/submodule/missing (not traversed)'][0] += 1
            continue
        data = file.read_bytes()
        language = LANGUAGES.get(file.suffix)
        if relative.parts[0] == 'libs' and relative.parts[:2] != ('libs', 'rmlui_bridge'):
            category = 'Vendored source'
        elif file.suffix == '.md':
            category, language = 'Documentation', 'Markdown'
        elif file.suffix in CONFIG:
            category, language = 'Configuration/data', 'Configuration/data'
        elif relative.parts[0] in ('scripts', '.github', '.githooks') or file.suffix == '.nix':
            category = 'Project tooling'
        else:
            category = 'Project source'
        if language:
            try:
                data.decode('utf-8')
                if b'\0' in data:
                    language = None
            except UnicodeDecodeError:
                language = None
        if not language:
            excluded['Binary/media/other (no source-line claim)'][0] += 1
            excluded['Binary/media/other (no source-line claim)'][1] += len(data)
            continue
        metrics = counts[(category, language)]
        metrics[0] += 1
        metrics[1] += data.count(b'\n') + bool(data and not data.endswith(b'\n'))
        metrics[2] += len(data)

    report = [
        '# Codebase Report', '', f'Generated: {datetime.now(timezone.utc).isoformat()}', '',
        'Scope: Git-tracked paths, reading current working-tree contents (including local edits).',
        'Untracked files and this report are excluded. Source extensions are allowlisted and UTF-8/NUL checked.',
        'Physical lines include comments and blank lines; these are not executable LOC or complexity scores.',
        'Vendored `libs/` code is separate; `libs/rmlui_bridge/` is project-owned glue.', '',
        '| Category | Language | Files | Physical lines | Bytes |',
        '| --- | --- | ---: | ---: | ---: |',
    ]
    for (category, language), (files, lines, size) in sorted(counts.items()):
        report.append(f'| {category} | {language} | {files} | {lines} | {size} |')
    report += ['', '## Non-Source Footprint', '', '| Category | Paths | Bytes |', '| --- | ---: | ---: |']
    for category, (files, size) in sorted(excluded.items()):
        report.append(f'| {category} | {files} | {size} |')
    report += ['', '## Local Cache And Build Footprint', '',
               'Allocated KiB from `du -sk`, not source lines. Symlinks are not followed.',
               'Nothing is cleaned, retired, or deleted. Untracked cache/output contents are counted only here.', '',
               '| Path | Allocated KiB |', '| --- | ---: |']
    for name in ('.zig-cache', 'zig-cache', '.devenv', '.direnv', 'zig-out'):
        file = root / name
        if file.is_symlink():
            size = 'symlink (not traversed)'
        elif not file.exists():
            size = 'absent'
        else:
            result = subprocess.run(['du', '-sk', '--', str(file)], capture_output=True, text=True)
            size = result.stdout.split()[0] if result.returncode == 0 else 'unavailable'
        report.append(f'| `{name}` | {size} |')
    if output.is_symlink():
        raise ValueError('Refusing to overwrite a symlink')
    output.write_text('\n'.join(report) + '\n')
    print(f'Report written to {output}')


if __name__ == '__main__':
    main()
