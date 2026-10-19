#!/usr/bin/env python3
"""Bundle the selected whisper-cli and its transitive non-system Mach-O libraries."""
import argparse
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import sys
import time


class BundleError(RuntimeError):
    pass


def output(*args):
    return subprocess.check_output(args, text=True)


def sign_binary(destination, signing_identity):
    command = ['/usr/bin/codesign', '--force', '--sign', signing_identity,
               '--options', 'runtime', '--timestamp', str(destination)]
    for attempt in range(3):
        result = subprocess.run(command, capture_output=True, text=True)
        sys.stdout.write(result.stdout)
        sys.stderr.write(result.stderr)
        if result.returncode == 0:
            return
        if 'The timestamp service is not available.' not in result.stderr or attempt == 2:
            result.check_returncode()
        print('Timestamp service unavailable; retrying the same signing request.', file=sys.stderr)
        time.sleep(2 ** (attempt + 1))


def system_library(path):
    return path.startswith('/usr/lib/') or path.startswith('/System/Library/')


def dependencies(binary):
    lines = output('/usr/bin/otool', '-L', str(binary)).splitlines()[1:]
    result = [line.strip().split(' (compatibility version')[0] for line in lines if line.startswith('\t')]
    # A dylib's first entry is its own install name, not a dependency.
    ids = output('/usr/bin/otool', '-D', str(binary)).splitlines()[1:]
    return [name for name in result if name not in ids]


def rpaths(binary):
    lines = output('/usr/bin/otool', '-l', str(binary)).splitlines()
    return [lines[i + 2].strip()[5:].rsplit(' (offset ', 1)[0]
            for i, line in enumerate(lines[:-2]) if line.strip() == 'cmd LC_RPATH']


def expand(path, loader, executable):
    return path.replace('@loader_path', str(loader.parent)).replace('@executable_path', str(executable.parent))


def resolve(name, loader, executable, search_paths):
    candidates = ([Path(root) / name[len('@rpath/'):] for root in search_paths]
                  if name.startswith('@rpath/') else [Path(expand(name, loader, executable))])
    for candidate in candidates:
        if candidate.is_absolute() and candidate.is_file():
            return candidate.resolve()
    raise BundleError(f'Cannot resolve {name} required by {loader}')


def dependency_graph(executable):
    executable = executable.resolve()
    graph = {}
    names = {}

    def visit(binary, inherited):
        if binary in graph:
            return
        search = [expand(path, binary, executable) for path in rpaths(binary)] + inherited
        graph[binary] = []
        for name in dependencies(binary):
            if system_library(name):
                continue
            dependency = resolve(name, binary, executable, search)
            previous = names.setdefault(dependency.name, dependency)
            if previous != dependency:
                raise BundleError(f'Conflicting library name {dependency.name}: {previous} and {dependency}')
            graph[binary].append((name, dependency))
            visit(dependency, search)

    visit(executable, [])
    # GGML's dlopen backends do not appear in Mach-O load commands. Discover
    # them beside this executable and beside the resolved GGML installation,
    # never from an unrelated global Homebrew installation.
    plugin_directories = {executable.parent}
    for binary in list(graph):
        if binary.name.startswith('libggml.'):
            plugin_directories.update([binary.parent, binary.parent.parent / 'libexec'])
    plugins = {path.resolve() for directory in plugin_directories
               for path in directory.glob('libggml-*.so') if path.is_file()}
    for plugin in sorted(plugins):
        previous = names.setdefault(plugin.name, plugin)
        if previous != plugin:
            raise BundleError(f'Conflicting library name {plugin.name}: {previous} and {plugin}')
        visit(plugin, [expand(path, executable, executable) for path in rpaths(executable)])
    return graph, plugins


def copy_writable(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Replace rather than overwrite: Homebrew sources are often mode 0555,
    # and a prior signed build may also have left a read-only destination.
    fd, temporary = tempfile.mkstemp(dir=destination.parent, prefix='.whisper-')
    os.close(fd)
    try:
        shutil.copy2(source, temporary)
        os.chmod(temporary, os.stat(temporary).st_mode | stat.S_IWUSR)
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def bundle(executable, resources, frameworks, signing_identity=None, required_archs=()):
    executable = executable.resolve()
    graph, plugins = dependency_graph(executable)  # Validate before copying.
    for binary in graph:
        if required_archs:
            available = set(output('/usr/bin/lipo', '-archs', str(binary)).split())
            missing = set(required_archs) - available
            if missing:
                raise BundleError(f'{binary} is missing required architectures: {", ".join(sorted(missing))}. '
                                  'Build the universal runtime with scripts/build_release_whisper.sh.')
    # GGML searches beside the executable for plugins on a clean machine.
    # See ggml/src/ggml-backend-reg.cpp, ggml_backend_load_best.
    destinations = {source: (resources / 'whisper-cli' if source == executable
                             else (resources if source in plugins else frameworks) / source.name)
                    for source in graph}
    for source, destination in destinations.items():
        copy_writable(source, destination)
    for source, edges in graph.items():
        destination = destinations[source]
        if source != executable:
            subprocess.check_call(['/usr/bin/install_name_tool', '-id', '@rpath/' + source.name, str(destination)])
        for old_name, dependency in edges:
            prefix = '@loader_path/../Frameworks/' if source == executable or source in plugins else '@loader_path/'
            subprocess.check_call(['/usr/bin/install_name_tool', '-change', old_name, prefix + dependency.name, str(destination)])
    # Check copied load commands, including transitive edges, before signing.
    for destination in destinations.values():
        for name in dependencies(destination):
            if system_library(name):
                continue
            resolved = Path(expand(name, destination, destinations[executable]))
            if not name.startswith('@loader_path/') or not resolved.is_file():
                raise BundleError(f'External or missing bundled dependency {name} in {destination}')
    if signing_identity:
        for destination in destinations.values():
            sign_binary(destination, signing_identity)
    return destinations[executable]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project-dir', type=Path, required=True)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--frameworks', type=Path, required=True)
    args = parser.parse_args()
    candidates = [args.project_dir / 'Vendor/whisper-release-1.9.2/bin/whisper-cli',
                  args.project_dir / 'Vendor/whisper.cpp/build/bin/whisper-cli',
                  Path('/opt/homebrew/bin/whisper-cli'), Path('/usr/local/bin/whisper-cli')]
    executable = next((path for path in candidates if os.access(path, os.X_OK) and path.is_file()), None)
    official = os.environ.get('HORSEWHISPRER_DISTRIBUTION_FLAVOR') == 'official'
    if executable is None:
        if official:
            raise BundleError('Official builds require a bundled whisper-cli runtime')
        print('warning: whisper-cli unavailable; configure a custom runtime path to transcribe.')
        return
    identity = os.environ.get('EXPANDED_CODE_SIGN_IDENTITY')
    if os.environ.get('CODE_SIGNING_ALLOWED') != 'YES' or identity == '-':
        identity = None
    if official and not identity:
        raise BundleError('Official builds require a configured signing identity for the CLI and libraries')
    required_archs = os.environ.get('ARCHS', '').split() if official else ()
    if official and not required_archs:
        raise BundleError('Official builds require ARCHS to validate the bundled runtime')
    bundle(executable, args.resources, args.frameworks, identity, required_archs)
    print(f'Bundled whisper-cli and its transitive dependencies from {executable}')


if __name__ == '__main__':
    try:
        main()
    except (BundleError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'error: {error}')
