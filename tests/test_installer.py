import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('installer', Path(__file__).resolve().parents[1]/'scripts/install.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def test_app_only_skips_codex_and_check_is_read_only(self):
        with patch.object(installer.sys, 'argv', ['install.py', '--component', 'app', '--check']), \
             patch.object(installer.shutil, 'which', return_value='/usr/bin/swift'), \
             patch.object(installer.subprocess, 'run') as run, \
             patch.object(installer, 'install_app') as copy:
            installer.main()
        self.assertEqual(run.call_count, 1)
        self.assertIn('--skip-codex', run.call_args.args[0])
        self.assertIn('--check', run.call_args.args[0])
        copy.assert_not_called()

    def test_connector_only_never_builds_or_installs_the_app(self):
        with patch.object(installer.sys, 'argv', ['install.py', '--component', 'connector']), \
             patch.object(installer.subprocess, 'run') as run, \
             patch.object(installer, 'install_app') as copy:
            installer.main()
        self.assertEqual(run.call_count, 1)
        self.assertNotIn('--skip-codex', run.call_args.args[0])
        copy.assert_not_called()

    def test_upgrade_preserves_old_application(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root/'build.app'
            executable = source/'Contents/MacOS/RadAgent'
            executable.parent.mkdir(parents=True)
            executable.write_text('new bundle')
            destination = root/'Applications/Radiology Agent.app'
            destination.mkdir(parents=True)
            (destination/'previous').write_text('original bundle')
            backup = installer.install_app(source, destination)
            self.assertEqual((backup/'previous').read_text(), 'original bundle')
            self.assertEqual((destination/'Contents/MacOS/RadAgent').read_text(), 'new bundle')

    def test_symlink_destination_is_preserved(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root/'build.app'
            (source/'Contents/MacOS').mkdir(parents=True)
            (source/'Contents/MacOS/RadAgent').write_text('new bundle')
            other = root/'unrelated.app'
            other.mkdir()
            destination = root/'Radiology Agent.app'
            destination.symlink_to(other, target_is_directory=True)
            with self.assertRaisesRegex(RuntimeError, 'symlink'):
                installer.install_app(source, destination)
            self.assertTrue(destination.is_symlink())


if __name__ == '__main__':
    unittest.main()
