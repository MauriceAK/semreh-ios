import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import direct_hermes_audit_artifacts as audit


class ArtifactAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.evidence = self.base / 'evidence'
        self.evidence.mkdir()
        self.root = self.base / 'repo'
        self.runtime = self.base / 'runtime'
        for target in (self.root / 'docs/migration', self.runtime / 'home/logs', self.runtime / 'logs'):
            target.mkdir(parents=True)
            (target / 'mandatory.txt').write_text('safe')
        self.first = self.evidence / 'first'
        self.first.mkdir()
        (self.first / 'one.txt').write_text('safe')
        self.other = self.evidence / 'old.txt'
        self.other.write_text('safe')
        for name, value in [('EVIDENCE', self.evidence), ('ROOT', self.root), ('RUNTIME', self.runtime)]:
            patcher = patch.object(audit, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_default_keeps_full_evidence_and_mandatory_scopes(self):
        files = audit.artifact_files([self.runtime], audit.selected_evidence_paths([]))
        self.assertIn(self.other, files)
        self.assertIn(self.first / 'one.txt', files)
        self.assertEqual(sum(path.name == 'mandatory.txt' for path in files), 3)

    def test_targeted_repeatable_file_and_directory_scopes_deduplicate(self):
        selected = audit.selected_evidence_paths([str(self.first), str(self.first / 'one.txt'), str(self.first)])
        files = audit.artifact_files([self.runtime], selected)
        self.assertNotIn(self.other, files)
        self.assertEqual(files.count(self.first / 'one.txt'), 1)
        self.assertEqual(sum(path.name == 'mandatory.txt' for path in files), 3)

    def test_rejects_escape_root_relative_and_missing_targets(self):
        for value in [str(self.base), str(self.evidence), 'first',
                      str(self.evidence / '..' / 'outside'), str(self.evidence / 'missing')]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                audit.selected_evidence_paths([value])

    def test_rejects_symlink_targets_ancestors_and_dangling_links(self):
        link = self.evidence / 'link'
        link.symlink_to(self.first, target_is_directory=True)
        dangling = self.evidence / 'dangling'
        dangling.symlink_to(self.base / 'missing')
        for value in [link, link / 'one.txt', dangling]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                audit.selected_evidence_paths([str(value)])

    def test_nested_symlink_is_flagged_not_followed(self):
        (self.first / 'nested').symlink_to(self.other)
        result, status = self.run_main(['--evidence-path', str(self.first)])
        self.assertEqual(status, 1)
        self.assertIn(str(self.first / 'nested'), result['flagged_paths'])
        self.assertEqual(result['files_scanned'], 4)

    def run_main(self, arguments):
        (self.runtime / 'credentials.json').write_text(json.dumps({'password': 'unique-secret-a'}))
        (self.runtime / 'home/config.yaml').write_text(json.dumps({
            'dashboard': {'basic_auth': {'secret': 'unique-secret-b', 'password_hash': 'unique-secret-c'}}}))
        output = io.StringIO()
        status = 0
        with patch('sys.argv', ['audit', *arguments]), patch.object(audit, 'validate'), contextlib.redirect_stdout(output):
            try:
                audit.main()
            except SystemExit as exc:
                status = exc.code
        return json.loads(output.getvalue()), status

    def test_output_honestly_distinguishes_targeted_and_full_coverage(self):
        for args, expected, count in [([], 'full-evidence', 5),
                                      (['--evidence-path', str(self.first)], 'targeted-evidence', 4)]:
            result, status = self.run_main(args)
            self.assertEqual(status, 0)
            self.assertEqual(result['audit_mode'], expected)
            self.assertEqual(result['files_scanned'], count)
            self.assertEqual(result['selected_evidence_paths'], [str(self.first)] if args else [])
            self.assertTrue(result['exclusions'])
            self.assertTrue(result['mandatory_scopes'])


if __name__ == '__main__':
    unittest.main()
