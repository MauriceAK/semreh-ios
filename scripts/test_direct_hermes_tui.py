"""Pure guards for the bounded stock/development TUI launcher modes."""

from pathlib import Path
import sys
import unittest
from unittest.mock import patch


SCRIPT_DIR = Path(__file__).resolve().parent
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import direct_hermes_tui as tui  # noqa: E402


class DirectHermesTuiTests(unittest.TestCase):
    def test_stock_target_is_the_exact_baseline_pair_and_pin(self):
        target = tui._target(None, stock_backend=True)

        self.assertTrue(target.stock)
        self.assertEqual(target.backend_sha, tui.development.baseline.PIN)
        self.assertEqual(target.source, tui.development.baseline.SOURCE)
        self.assertEqual(target.runtime, tui.development.baseline.RUNTIME)
        self.assertEqual(
            target.bundle,
            tui.development.baseline.SOURCE / 'ui-tui' / 'dist' / 'entry.js',
        )
        self.assertEqual(
            target.active_session_file,
            tui.development.baseline.RUNTIME / 'home' / 'tui-active-session.json',
        )

    def test_stock_and_development_modes_cannot_be_mixed(self):
        with self.assertRaisesRegex(RuntimeError, 'cannot be combined'):
            tui._target(tui.development.baseline.PIN, stock_backend=True)
        with self.assertRaisesRegex(RuntimeError, 'requires --backend-sha'):
            tui._target(None, stock_backend=False)

    def test_stock_environment_isolated_to_stock_source_and_runtime(self):
        target = tui._target(None, stock_backend=True)
        environment = tui._environment_for_target(target, 'durable.session-1')

        self.assertEqual(environment['HERMES_HOME'], str(target.runtime / 'home'))
        self.assertEqual(environment['HERMES_PYTHON_SRC_ROOT'], str(target.source))
        self.assertEqual(environment['PYTHONPATH'], str(target.source))
        self.assertEqual(environment['HERMES_CWD'], str(target.runtime / 'tools'))
        self.assertEqual(environment['HERMES_TUI_RESUME'], 'durable.session-1')
        self.assertEqual(environment['HOME'], str(target.runtime / 'home' / 'home'))
        self.assertEqual(
            environment['HERMES_TUI_ACTIVE_SESSION_FILE'],
            str(target.active_session_file),
        )
        self.assertNotIn('HERMES_TUI_GATEWAY_URL', environment)
        self.assertNotIn('HERMES_TUI_SIDECAR_URL', environment)
        development_target = tui._target(tui.development.baseline.PIN, stock_backend=False)
        self.assertEqual(
            tui._environment_for_target(development_target, None)['HOME'],
            str(development_target.runtime / 'home' / 'home'),
        )

    def test_stock_launch_validates_then_execs_stock_bundle_without_running_process(self):
        target = tui._target(None, stock_backend=True)
        with patch.object(tui.development.baseline, 'validate') as validate, patch.object(
            tui, '_validate_bundle_and_runtime'
        ) as bundle_check, patch.object(tui.os, 'chdir') as chdir, patch.object(
            tui.os, 'execve'
        ) as execve:
            tui.launch(None, 'durable.session-1', stock_backend=True)

        validate.assert_called_once_with()
        bundle_check.assert_called_once_with(target)
        chdir.assert_called_once_with(target.runtime / 'tools')
        execve.assert_called_once()
        executable, argv, environment = execve.call_args.args
        self.assertEqual(executable, str(tui.NODE))
        self.assertEqual(argv[-1], str(target.bundle))
        self.assertEqual(environment['HERMES_PYTHON_SRC_ROOT'], str(target.source))
        self.assertEqual(environment['HERMES_HOME'], str(target.runtime / 'home'))
        self.assertEqual(environment['HOME'], str(target.runtime / 'home' / 'home'))


if __name__ == '__main__':
    unittest.main()
