#!/usr/bin/env python3
"""audit-tweak-debs.py — extract each final .deb, run verify-payload.sh on the
tree, and repeat the build-path leak and dSYM scans per Mach-O (no-build-path-leak,
dsym-before-strip). A deliberate addition over the reading review, not a
replacement for it (review-gate-reading). Run as a failing Release step."""
import argparse
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(*args):
    return subprocess.check_output(args, text=True).strip()


def private_paths():
    paths = {str(Path.home()), "/Users/runner/work", "/home/runner/work"}
    for name in ("GITHUB_WORKSPACE", "RUNNER_TEMP", "TMPDIR", "TWEAK_SDK", "PREFS_SDK"):
        v = os.environ.get(name)
        if v and v.startswith("/"):
            paths.add(os.path.normpath(v))
            paths.add(os.path.realpath(v))
    try:
        sdk = run("xcrun", "--sdk", "iphoneos", "--show-sdk-path")
        paths.add(sdk)
        paths.add(os.path.realpath(sdk))
    except Exception:
        pass
    return sorted(p.encode() for p in paths if p and p != "/")


def embeds(data, path):
    return re.search(re.escape(path) + rb"(?=/|\x00|$)", data) is not None


def audit(deb):
    arch = run("dpkg-deb", "-f", str(deb), "Architecture")
    flavor = {"iphoneos-arm64e": "roothide", "iphoneos-arm64": "rootless"}.get(arch)
    if flavor is None:
        raise ValueError(f"unknown architecture {arch}")
    # The release globs pick flavors by file name; a name that disagrees with
    # the control fields would ship one layout under the other's name.
    package = run("dpkg-deb", "-f", str(deb), "Package")
    version = run("dpkg-deb", "-f", str(deb), "Version")
    expected = f"{package}_{version}_{arch}.deb"
    if deb.name != expected:
        raise ValueError(f"file name {deb.name} does not match its control fields ({expected})")
    with tempfile.TemporaryDirectory(prefix="tweak-audit-") as scratch:
        tree = Path(scratch)
        subprocess.run(["dpkg-deb", "-R", str(deb), str(tree)], check=True)
        subprocess.run(
            [str(ROOT / "scripts/verify-payload.sh"), flavor, str(tree)],
            check=True,
        )
        paths = private_paths()
        machs = 0
        for item in tree.rglob("*"):
            if item.is_symlink() or not item.is_file():
                continue
            head = item.read_bytes()[:4]
            if head not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe"):
                continue
            machs += 1
            data = item.read_bytes()
            for p in paths:
                if embeds(data, p):
                    raise ValueError(f"{item.relative_to(tree)} embeds build path {p.decode()}")
            if ".dSYM/" in str(item):
                raise ValueError(f"{item.relative_to(tree)}: a dSYM must never ship in a deb")
        if machs == 0:
            raise ValueError("no Mach-O in payload")
    print(f"PASS {deb.name} ({flavor})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("packages", nargs="+", type=Path)
    args = parser.parse_args()
    failures = 0
    for pkg in args.packages:
        try:
            audit(pkg)
        except (ValueError, OSError, subprocess.CalledProcessError) as error:
            failures += 1
            print(f"FAIL {pkg.name}: {error}", file=sys.stderr)
    raise SystemExit(1 if failures else 0)
