#!/usr/bin/env python3
"""Offline regression checks; no builds, providers, GitHub mutations, or disk writes."""

import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import MagicMock, patch

from defusedxml import EntitiesForbidden

import static_pr_review
import validate_coverage
import codebase_report


class CoverageValidationTests(unittest.TestCase):
    def report(self, filename='src/main.zig', lines='<line number="1" hits="2"/>'):
        return io.StringIO(f'<coverage><packages><package><classes><class filename="{filename}">'
                           f'<lines>{lines}</lines></class></classes></package></packages></coverage>')

    def test_project_lines(self):
        with patch('builtins.print'):
            self.assertEqual(validate_coverage.validate(self.report(), Path.cwd()), (1, 1))

    def test_cobertura_doctype_without_external_reads(self):
        report = ('<?xml version="1.0"?>'
                  '<!DOCTYPE coverage SYSTEM "http://cobertura.sourceforge.net/xml/coverage-04.dtd">'
                  + self.report().getvalue())
        with patch('builtins.open', side_effect=AssertionError('Unexpected external file read')), \
             patch('socket.socket', side_effect=AssertionError('Unexpected network access')), \
             patch('builtins.print'):
            self.assertEqual(validate_coverage.validate(io.StringIO(report), Path.cwd()), (1, 1))

    def test_entities_rejected_without_disclosing_payload(self):
        declarations = {
            'internal': '<!ENTITY private_entity "private-value">',
            'external_file': '<!ENTITY private_entity SYSTEM "file:///private-file">',
            'external_http': '<!ENTITY private_entity SYSTEM "https://example.invalid/private-token">',
            'parameter': '<!ENTITY % private_entity SYSTEM "file:///private-file">%private_entity;',
            'billion_laughs': '<!ENTITY e0 "ha">' + ''.join(
                f'<!ENTITY e{i} "' + f'&e{i - 1};' * 10 + '">'
                for i in range(1, 10)) + '<!ENTITY private_entity "&e9;">',
        }
        for name, declaration in declarations.items():
            with self.subTest(name=name):
                report = (f'<!DOCTYPE coverage [{declaration}]>'
                          + self.report().getvalue().replace('<coverage>', '<coverage>&private_entity;'))
                with self.assertRaises(EntitiesForbidden), \
                     patch('builtins.open', side_effect=AssertionError('Unexpected external file read')), \
                     patch('socket.socket', side_effect=AssertionError('Unexpected network access')):
                    validate_coverage.validate(io.StringIO(report), Path.cwd())
                result = subprocess.run(
                    [sys.executable, '-B', 'scripts/validate_coverage.py', '/dev/stdin'],
                    input=report, capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, '')
                self.assertEqual(result.stderr, 'Coverage unavailable: unsafe XML rejected\n')

    def test_malformed_xml_fails_cleanly(self):
        result = subprocess.run(
            [sys.executable, '-B', 'scripts/validate_coverage.py', '/dev/stdin'],
            input='<coverage>', capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 1)
        self.assertIn('Coverage unavailable:', result.stderr)
        self.assertNotIn('Traceback', result.stderr)

    def test_no_lines(self):
        with self.assertRaises(ValueError):
            validate_coverage.validate(self.report(lines=''), Path.cwd())

    def test_vendor_only_is_not_project_coverage(self):
        with self.assertRaises(ValueError):
            validate_coverage.validate(self.report(filename='libs/stb/stb_image.h'), Path.cwd())

    def test_missing_project_file_is_not_coverage(self):
        with self.assertRaises(ValueError):
            validate_coverage.validate(self.report(filename='src/does-not-exist.zig'), Path.cwd())

    def test_negative_hits_rejected(self):
        with self.assertRaises(ValueError):
            validate_coverage.validate(self.report(lines='<line number="1" hits="-1"/>'), Path.cwd())

    def test_partial_scope_is_not_full_suite_coverage(self):
        with self.assertRaisesRegex(ValueError, 'required scopes: modules'):
            validate_coverage.validate(self.report(), Path.cwd(), required_scopes=('src', 'modules'))

    def test_native_debug_module_only_report_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'required scopes: src'):
            validate_coverage.validate(self.report(filename='modules/engine-core/src/root.zig'), Path.cwd(),
                                       required_scopes=('src', 'modules'))

    def test_full_suite_report_has_src_and_modules(self):
        report = self.report().getvalue().replace('</classes>',
            '<class filename="modules/engine-core/src/root.zig"><lines><line number="1" hits="1"/></lines></class></classes>')
        with patch('builtins.print'):
            self.assertEqual(validate_coverage.validate(io.StringIO(report), Path.cwd(),
                             required_scopes=('src', 'modules')), (2, 2))

    def test_existing_output_rejected_before_build(self):
        result = subprocess.run(['bash', 'scripts/collect_coverage.sh', '.'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn('no report is overwritten', result.stderr)

    def test_invalid_jobs_rejected_before_build(self):
        result = subprocess.run(['bash', 'scripts/collect_coverage.sh', '/nonexistent/zigcraft-offline-report'],
                                capture_output=True, text=True, env={**os.environ, 'ZIGCRAFT_TEST_JOBS': '0'})
        self.assertEqual(result.returncode, 2)
        self.assertIn('ZIGCRAFT_TEST_JOBS must be a positive integer', result.stderr)


class StaticReviewTests(unittest.TestCase):
    def run_review(self, message, finish_reason='stop'):
        response = MagicMock()
        response.read.return_value = json.dumps({'choices': [
            {'finish_reason': finish_reason, 'message': message},
        ]}).encode()
        opener = MagicMock()
        opener.open.return_value.__enter__.return_value = response
        # Only a dummy test credential is used; input/output and HTTP are mocked.
        with patch.dict('os.environ', {'ZHIPU_API_KEY': 'dummy-credential-for-offline-test'}, clear=True), \
             patch.object(sys, 'argv', ['review', '/input', '/output']), \
             patch.object(Path, 'stat', return_value=MagicMock(st_size=100)), \
             patch.object(Path, 'read_text', return_value=json.dumps({'pr_number': 1, 'head_sha': 'a' * 40, 'diff': 'untrusted text'})), \
             patch.object(Path, 'open', return_value=MagicMock()) as output, \
             patch.object(static_pr_review.urllib.request, 'build_opener', return_value=opener):
            static_pr_review.main()
            request = opener.open.call_args.args[0]
            payload = json.loads(request.data)
            self.assertEqual(request.full_url, 'https://open.bigmodel.cn/api/coding/paas/v4/chat/completions')
            self.assertNotIn('tools', payload)
            self.assertNotIn('dummy-credential-for-offline-test', request.data.decode())
            output.assert_called_once_with('x', encoding='utf-8')

    def test_fixed_endpoint_no_tools_or_key_in_prompt(self):
        self.run_review({'content': 'No findings identified; static diff only.'})

    def test_tool_response_rejected(self):
        with self.assertRaises(ValueError):
            self.run_review({'content': 'Run this', 'tool_calls': [{'name': 'bash'}]})

    def test_truncated_response_rejected(self):
        with self.assertRaises(ValueError):
            self.run_review({'content': 'Partial review'}, 'length')

    def test_credential_echo_rejected(self):
        with self.assertRaises(ValueError):
            self.run_review({'content': 'dummy-credential-for-offline-test'})

    def test_provider_redirect_rejected(self):
        with self.assertRaises(ValueError):
            static_pr_review.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://untrusted.invalid/')


class VisualComparisonTests(unittest.TestCase):
    def compare(self, status=0, metric='0 (0)', mean='0.5'):
        # Use an existing nonempty text file as the fixture. The fake decoder
        # neither reads image data nor creates an output; no files are changed.
        program = '''
        magick() {
          if [[ "$1" == identify ]]; then
            printf '1280x720'
          elif [[ "$1" == compare ]]; then
            printf '%s' "$TEST_METRIC" >&2
            return "$TEST_STATUS"
          else
            printf '%s' "$TEST_MEAN"
          fi
        }
        export -f magick
        bash scripts/compare_visual_golden.sh README.md README.md README.md
        '''
        result = subprocess.run(['bash', '-c', program], capture_output=True, text=True,
                                env={'PATH': os.environ['PATH'], 'TEST_STATUS': str(status),
                                     'TEST_METRIC': metric, 'TEST_MEAN': mean})
        return result.returncode

    def test_matching_images(self):
        self.assertEqual(self.compare(), 0)

    def test_small_scientific_notation_difference(self):
        self.assertEqual(self.compare(1, '0.1 (1.5e-06)'), 0)

    def test_decoder_error_cannot_pass_with_fake_metric(self):
        self.assertNotEqual(self.compare(2, '0 (0)'), 0)

    def test_missing_metric_rejected(self):
        self.assertNotEqual(self.compare(0, 'not a metric'), 0)

    def test_black_image_rejected(self):
        self.assertNotEqual(self.compare(mean='0'), 0)

    def test_difference_rejected(self):
        self.assertNotEqual(self.compare(1, '123 (0.5)'), 0)


class CodebaseReportTests(unittest.TestCase):
    def test_binary_vendor_and_cache_are_separate(self):
        files = {'src/main.zig': b'// source\n', 'libs/stb/stb.h': b'// vendor\n',
                 'assets/screenshot.png': b'\0\n\n\n' * 100, 'docs/guide.md': b'# Docs\n'}
        tracked = b'\0'.join(name.encode() for name in files) + b'\0'
        with patch.object(sys, 'argv', ['report', '/tmp/report.md']), \
             patch.object(subprocess, 'check_output', side_effect=['/project\n', tracked]), \
             patch.object(Path, 'is_file', return_value=True), \
             patch.object(Path, 'is_symlink', autospec=True, side_effect=lambda p: p.name == '.zig-cache'), \
             patch.object(Path, 'exists', return_value=False), \
             patch.object(Path, 'read_bytes', autospec=True, side_effect=lambda p: files[str(p.relative_to('/project'))]), \
             patch.object(Path, 'write_text') as write, patch.object(subprocess, 'run') as du, \
             patch('builtins.print'):
            codebase_report.main()
        report = write.call_args.args[0]
        self.assertIn('| Project source | Zig | 1 | 1 | 10 |', report)
        self.assertIn('| Vendored source | C/C++ | 1 | 1 | 10 |', report)
        self.assertIn('| Binary/media/other (no source-line claim) | 1 | 400 |', report)
        self.assertIn('| `.zig-cache` | symlink (not traversed) |', report)
        du.assert_not_called()


if __name__ == '__main__':
    unittest.main()
