#!/usr/bin/env python3
"""Run the real resource loaders and Mermaid renderer using only an app's packaged resources."""
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile


def check(app, probe, sample):
    with tempfile.TemporaryDirectory(prefix="strata-packaged-resources-") as scratch:
        host = pathlib.Path(scratch) / "ResourceCheck.app" / "Contents"
        (host / "MacOS").mkdir(parents=True)
        resources = host / "Resources"
        resources.mkdir()
        for bundle in (app / "Contents" / "Resources").glob("*.bundle"):
            shutil.copytree(bundle, resources / bundle.name)
        executable = host / "MacOS" / "StrataResourceCheck"
        shutil.copy2(probe, executable)
        with (host / "Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": "dev.strata.tests.resources", "CFBundlePackageType": "APPL",
                          "CFBundleExecutable": executable.name}, output)
        return subprocess.run([str(executable), str(sample.resolve())], capture_output=True, text=True,
                              timeout=45, cwd=scratch)


if __name__ == "__main__":
    result = check(*(pathlib.Path(value).resolve() for value in sys.argv[1:]))
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    sys.exit(result.returncode)
