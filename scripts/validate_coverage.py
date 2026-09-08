#!/usr/bin/env python3
"""Reject empty/non-project Cobertura reports instead of inventing coverage."""

from pathlib import Path
import sys
from defusedxml import DefusedXmlException, ElementTree as ET


def validate(report, root, required_scopes=()):
    # kcov emits a Cobertura DOCTYPE; allow it, but never entities or external reads.
    tree = ET.parse(report, forbid_dtd=False, forbid_entities=True, forbid_external=True).getroot()
    sources = [Path(node.text) for node in tree.findall('./sources/source') if node.text]
    lines = {}
    for entry in tree.findall('.//class'):
        filename = Path(entry.attrib['filename'])
        candidates = [root / filename, *(source / filename for source in sources)]
        project_file = None
        for candidate in candidates:
            try:
                relative = candidate.resolve().relative_to(root)
            except ValueError:
                continue
            if relative.parts[0] in ('src', 'modules') or relative.parts[:2] == ('libs', 'rmlui_bridge'):
                if candidate.is_file() and candidate.suffix in ('.zig', '.c', '.h', '.cpp', '.hpp'):
                    project_file = relative
                    break
        if project_file is None:
            continue
        for line in entry.findall('./lines/line'):
            number, hits = int(line.attrib['number']), int(line.attrib['hits'])
            if number <= 0 or hits < 0:
                raise ValueError('Invalid line coverage data')
            key = (project_file, number)
            lines[key] = max(lines.get(key, 0), hits)
    if not lines:
        raise ValueError('Report contains no instrumented project source lines')
    missing = set(required_scopes) - {filename.parts[0] for filename, _ in lines}
    if missing:
        raise ValueError(f'Report contains no instrumented lines for required scopes: {", ".join(sorted(missing))}')
    covered = sum(hits > 0 for hits in lines.values())
    file_count = len({filename for filename, _ in lines})
    print(f'Validated project line coverage: {covered}/{len(lines)} lines hit '
          f'({100 * covered / len(lines):.2f}%) across {file_count} files')
    return covered, len(lines)


if __name__ == '__main__':
    try:
        validate(Path(sys.argv[1]), Path.cwd().resolve(), required_scopes=('src', 'modules'))
    except DefusedXmlException:
        print('Coverage unavailable: unsafe XML rejected', file=sys.stderr)
        sys.exit(1)
    except (OSError, ET.ParseError, ValueError, KeyError) as error:
        print(f'Coverage unavailable: {error}', file=sys.stderr)
        sys.exit(1)
