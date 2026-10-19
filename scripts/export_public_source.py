#!/usr/bin/env python3
"""Export only reviewed files, without Git history or machine-local state."""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tempfile
import zlib


FORBIDDEN_PARTS = {".git", ".codex", ".agents", ".aws", "tmp", "dist", "Vendor",
                   "DerivedData", ".build", ".xflow", "xcuserdata", "__pycache__"}
PRIVATE_TEXT = re.compile(
    r"/Users[/][^/\s]+/|/home[/]forge\b|forge[@]|private[-]archive|"
    r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"
)


def reviewed_paths(root, manifest):
    paths = json.loads(manifest.read_text())
    if not isinstance(paths, list) or not paths or len(paths) != len(set(paths)):
        raise ValueError("Manifest must be a nonempty list of unique relative paths")
    result = []
    for name in paths:
        path = PurePosixPath(name)
        if (path.is_absolute() or ".." in path.parts or str(path) != name
                or set(path.parts) & FORBIDDEN_PARTS
                or path.name == "LocalOverrides.xcconfig"
                or path.name.startswith(".env")
                or path.suffix.lower() in {".p8", ".p12", ".pem", ".key", ".mobileprovision"}):
            raise ValueError(f"Forbidden export path: {name}")
        source = root / name
        if any(p.is_symlink() for p in [source, *source.parents]) or not source.is_file():
            raise ValueError(f"Missing file or symlink in export path: {name}")
        try:
            content = source.read_text()
        except UnicodeDecodeError:
            content = ""
        if PRIVATE_TEXT.search(content):
            raise ValueError(f"Private material needs review in: {name}")
        result.append((name, source))
    return result


def scan(staging):
    scanner = shutil.which("gitleaks")
    if scanner is None:
        raise RuntimeError("Install gitleaks before exporting; scanning cannot be skipped")
    # Do not inherit exclusions/baselines or a local scanner configuration.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GITLEAKS_")}
    with tempfile.TemporaryDirectory(prefix="public-source-scan-") as temp:
        config = Path(temp) / "rules.toml"
        config.write_text("[extend]\nuseDefault = true\n")
        ignore = Path(temp) / "empty.ignore"
        ignore.write_text("")
        result = subprocess.run(
            [scanner, "dir", str(staging), "--config", str(config), "--redact=100",
             "--gitleaks-ignore-path", str(ignore), "--no-banner",
             "--ignore-gitleaks-allow", "--exit-code", "1"],
            env=env, capture_output=True)
        if result.returncode:
            raise RuntimeError("Secret scan failed; no export created. Review with redaction enabled.")


def public_bytes(source):
    data = source.read_bytes()
    if source.suffix.lower() != ".png":
        return data
    # Remove embedded text/EXIF (including compressed metadata) without changing
    # any image, color, or transparency chunks. File copying also omits xattrs.
    signature = b"\x89PNG\r\n\x1a\n"
    if not data.startswith(signature):
        raise ValueError(f"Invalid PNG: {source.name}")
    output = bytearray(signature)
    offset = len(signature)
    while offset + 12 <= len(data):
        size = int.from_bytes(data[offset:offset + 4], "big")
        end = offset + size + 12
        if end > len(data):
            break
        kind = data[offset + 4:offset + 8]
        payload = data[offset + 8:end - 4]
        checksum = int.from_bytes(data[end - 4:end], "big")
        if zlib.crc32(kind + payload) != checksum:
            raise ValueError(f"Invalid PNG checksum: {source.name}")
        if kind not in {b"tEXt", b"zTXt", b"iTXt", b"eXIf"}:
            output.extend(data[offset:end])
        offset = end
        if kind == b"IEND":
            if offset != len(data):
                raise ValueError(f"Unexpected data after PNG: {source.name}")
            return bytes(output)
    raise ValueError(f"Truncated PNG: {source.name}")


def export(root, manifest, destination):
    root = root.resolve()
    destination = destination.absolute()
    if destination.exists() or destination.is_symlink():
        raise ValueError("Destination already exists; choose a new directory")
    paths = reviewed_paths(root, manifest)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".public-source-", dir=destination.parent) as temp:
        staging = Path(temp) / "source"
        staging.mkdir()
        hashes = []
        for name, source in paths:
            target = staging / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(public_bytes(source))
            target.chmod(0o755 if source.stat().st_mode & 0o111 else 0o644)
            hashes.append({"path": name, "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
        (staging / "SOURCE_MANIFEST.json").write_text(json.dumps(hashes, indent=2) + "\n")
        scan(staging)
        staging.rename(destination)
    return len(paths)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="New local directory; nothing is published")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    try:
        count = export(root, root / "Config/PublicSourceFiles.json", args.destination)
    except (ValueError, RuntimeError, OSError) as error:
        parser.exit(1, f"{error}\n")
    print(f"Exported {count} reviewed files. No Git history, remotes, or credentials copied.")


if __name__ == "__main__":
    main()
