import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

MODULE = Path(__file__).resolve().parents[2] / 'scripts/bundle_whisper.py'
spec = importlib.util.spec_from_file_location('bundle_whisper', MODULE)
bundler = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundler)


class BundleWhisperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='horse whisper bundle ')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.libs = self.root / 'deps'
        self.libs.mkdir()
        self.resources = self.root / 'App/Contents/Resources'
        self.frameworks = self.root / 'App/Contents/Frameworks'

    def compile(self, destination, source, libraries=(), install_name=None, rpaths=()):
        destination.parent.mkdir(parents=True, exist_ok=True)
        c_file = destination.with_suffix('.c')
        c_file.write_text(source)
        command = ['/usr/bin/xcrun', 'clang', str(c_file), '-o', str(destination), '-Wl,-headerpad_max_install_names']
        if install_name:
            command += ['-dynamiclib', '-Wl,-install_name,' + install_name]
        command += [str(path) for path in libraries]
        for path in rpaths:
            command += ['-Wl,-rpath,' + str(path)]
        subprocess.check_call(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        return destination

    def chain(self, relative=False):
        leaf = self.libs / 'libleaf.dylib'
        middle = self.libs / 'libmiddle.dylib'
        self.compile(leaf, 'int leaf(void) { return 0; }', install_name='@rpath/libleaf.dylib' if relative else str(leaf))
        self.compile(middle, 'extern int leaf(void); int middle(void) { return leaf(); }', [leaf],
                     install_name='@rpath/libmiddle.dylib' if relative else str(middle))
        executable = self.compile(self.root / 'bin/whisper-cli',
            'extern int middle(void); int main(void) { return middle(); }', [middle], rpaths=[self.libs])
        return executable, leaf, middle

    def assert_portable(self, executable):
        for binary in [executable] + list(self.frameworks.glob('*.dylib')):
            for name in bundler.dependencies(binary):
                if not bundler.system_library(name):
                    self.assertTrue(name.startswith('@loader_path/'), name)
                    self.assertTrue(Path(bundler.expand(name, binary, executable)).is_file())
                    self.assertNotIn(str(self.libs), name)

    def test_absolute_transitive_dependencies_are_copied_and_rewritten(self):
        executable, leaf, middle = self.chain()
        bundled = bundler.bundle(executable, self.resources, self.frameworks)
        self.assertEqual({path.name for path in self.frameworks.iterdir()}, {leaf.name, middle.name})
        self.assert_portable(bundled)
        # The fixture must load without access to its original library folder.
        self.libs.rename(self.root / "unavailable-deps")
        subprocess.run([str(bundled)], check=True, timeout=5)

    def test_rpath_search_is_inherited_by_transitive_libraries(self):
        executable, _, _ = self.chain(relative=True)
        bundled = bundler.bundle(executable, self.resources, self.frameworks)
        self.assert_portable(bundled)

    def test_incremental_build_replaces_read_only_bundled_executable(self):
        executable, _, _ = self.chain()
        bundled = bundler.bundle(executable, self.resources, self.frameworks)
        bundled.chmod(0o555)
        bundler.bundle(executable, self.resources, self.frameworks)
        self.assert_portable(bundled)

    def test_missing_architecture_fails_before_copying(self):
        executable, _, _ = self.chain()
        with self.assertRaisesRegex(bundler.BundleError, 'missing required architectures'):
            bundler.bundle(executable, self.resources, self.frameworks, required_archs=['arm64', 'x86_64'])
        self.assertFalse(self.resources.exists())

    def test_dependency_architecture_is_checked_even_for_universal_executable(self):
        executable, leaf, _ = self.chain()
        original_output = bundler.output
        def output(*args):
            if args[:2] == ('/usr/bin/lipo', '-archs'):
                return 'arm64' if args[2] == str(leaf.resolve()) else 'arm64 x86_64'
            return original_output(*args)
        with mock.patch.object(bundler, 'output', side_effect=output):
            with self.assertRaisesRegex(bundler.BundleError, 'libleaf.dylib is missing'):
                bundler.bundle(executable, self.resources, self.frameworks, required_archs=['arm64', 'x86_64'])
        self.assertFalse(self.resources.exists())

    def test_missing_transitive_library_fails_before_copying(self):
        executable, leaf, _ = self.chain()
        leaf.rename(leaf.with_suffix('.hidden'))
        with self.assertRaisesRegex(bundler.BundleError, 'Cannot resolve'):
            bundler.bundle(executable, self.resources, self.frameworks)
        self.assertFalse(self.resources.exists())

    def test_duplicate_library_basenames_fail_instead_of_overwriting(self):
        a = self.root / 'a/libduplicate.dylib'
        b = self.root / 'b/libduplicate.dylib'
        self.compile(a, 'int a(void) { return 0; }', install_name=str(a))
        self.compile(b, 'int b(void) { return 0; }', install_name=str(b))
        executable = self.compile(self.root / 'whisper-cli',
            'extern int a(void); extern int b(void); int main(void) { return a() + b(); }', [a, b])
        with self.assertRaisesRegex(bundler.BundleError, 'Conflicting library name'):
            bundler.bundle(executable, self.resources, self.frameworks)
        self.assertFalse(self.resources.exists())

    def test_dlopen_backend_and_its_dependencies_work_without_originals(self):
        leaf = self.libs / 'libleaf.dylib'
        self.compile(leaf, 'int leaf(void) { return 0; }', install_name=str(leaf))
        ggml = self.libs / 'libggml.dylib'
        self.compile(ggml, 'int ggml(void) { return 0; }', install_name=str(ggml))
        plugin = self.root / 'libexec/libggml-test.so'
        self.compile(plugin, 'extern int leaf(void); int backend(void) { return leaf(); }', [leaf], install_name=str(plugin))
        executable = self.compile(self.root / 'bin/whisper-cli', r"""
            #include <dlfcn.h>
            #include <mach-o/dyld.h>
            #include <string.h>
            #include <stdio.h>
            extern int ggml(void);
            int main(void) {
                if (ggml() != 0) return 2;
                char path[4096]; uint32_t size = sizeof(path);
                if (_NSGetExecutablePath(path, &size)) return 3;
                strcpy(strrchr(path, '/') + 1, "libggml-test.so");
                void * handle = dlopen(path, RTLD_NOW);
                if (!handle) { fprintf(stderr, "%s", dlerror()); return 4; }
                int (*backend)(void) = dlsym(handle, "backend");
                return backend ? backend() : 5;
            }
        """, [ggml])
        bundled = bundler.bundle(executable, self.resources, self.frameworks)
        self.libs.rename(self.root / 'unavailable-deps')
        plugin.parent.rename(self.root / 'unavailable-plugins')
        subprocess.run([str(bundled)], check=True, timeout=5)
        self.assertTrue((self.resources / plugin.name).is_file())
        self.assertTrue((self.frameworks / leaf.name).is_file())

    def test_timestamp_failure_retries_identical_signing_request(self):
        failed = subprocess.CompletedProcess([], 1, '', 'The timestamp service is not available.')
        passed = subprocess.CompletedProcess([], 0, '', '')
        with mock.patch.object(bundler.subprocess, 'run', side_effect=[failed, passed]) as run, mock.patch.object(bundler.time, 'sleep') as sleep:
            bundler.sign_binary(Path('/fixture'), 'Developer ID fixture')
        self.assertEqual(run.call_count, 2)
        self.assertEqual(run.call_args_list[0], run.call_args_list[1])
        self.assertIn('--timestamp', run.call_args.args[0])
        self.assertIn('runtime', run.call_args.args[0])
        sleep.assert_called_once_with(2)

    def test_persistent_timestamp_failure_still_fails_after_three_attempts(self):
        failed = subprocess.CompletedProcess([], 1, '', 'The timestamp service is not available.')
        with mock.patch.object(bundler.subprocess, 'run', return_value=failed) as run, mock.patch.object(bundler.time, 'sleep') as sleep:
            with self.assertRaises(subprocess.CalledProcessError):
                bundler.sign_binary(Path('/fixture'), 'Developer ID fixture')
        self.assertEqual(run.call_count, 3)
        self.assertEqual(sleep.call_args_list, [mock.call(2), mock.call(4)])

    def test_other_signing_failure_is_not_retried(self):
        failed = subprocess.CompletedProcess([], 1, '', 'The specified item could not be found in the keychain.')
        with mock.patch.object(bundler.subprocess, 'run', return_value=failed) as run, mock.patch.object(bundler.time, 'sleep') as sleep:
            with self.assertRaises(subprocess.CalledProcessError):
                bundler.sign_binary(Path('/fixture'), 'Developer ID fixture')
        run.assert_called_once()
        sleep.assert_not_called()

    def test_official_build_requires_runtime(self):
        argv = ['bundle_whisper.py', '--project-dir', str(self.root),
                '--resources', str(self.resources), '--frameworks', str(self.frameworks)]
        with mock.patch('sys.argv', argv), mock.patch.dict('os.environ', {'HORSEWHISPRER_DISTRIBUTION_FLAVOR': 'official'}), mock.patch.object(bundler.os, 'access', return_value=False):
            with self.assertRaisesRegex(bundler.BundleError, 'require a bundled'):
                bundler.main()


if __name__ == '__main__':
    unittest.main()
