#!/usr/bin/env python3
"""Make the Mach-O files of an app bundle self-contained.

Starting from the given executables and plugins, every dependency that lives
in the build prefix is copied into the bundle's Frameworks directory and all
load commands are rewritten to @rpath/<name>. Each binary then gets exactly one
LC_RPATH pointing at Frameworks, relative to its own location.

Finally every Mach-O in the bundle is checked: anything that still points
outside the bundle and the OS (/System, /usr/lib) is a hard error.
"""

import argparse
import os
import shutil
import subprocess
import sys

SYSTEM_PREFIXES = ("/usr/lib/", "/System/Library/")


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def is_macho(path):
    if os.path.islink(path) or not os.path.isfile(path):
        return False
    with open(path, "rb") as f:
        magic = f.read(4)
    return magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xca\xfe\xba\xbe")


def load_commands(path):
    """Returns (install_id, [dependencies], [rpaths])."""
    out = run("otool", "-l", path).splitlines()
    install_id, deps, rpaths = None, [], []
    cmd = None
    for line in out:
        line = line.strip()
        if line.startswith("cmd "):
            cmd = line.split()[1]
        elif line.startswith("name ") and cmd in ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB", "LC_ID_DYLIB"):
            name = line[5:].rsplit(" (offset", 1)[0]
            if cmd == "LC_ID_DYLIB":
                install_id = name
            else:
                deps.append(name)
        elif line.startswith("path ") and cmd == "LC_RPATH":
            rpaths.append(line[5:].rsplit(" (offset", 1)[0])
    return install_id, deps, rpaths


def resolve(dep, prefix, loader):
    """Maps a load command to a file in the build prefix, or None for system libs."""
    if dep.startswith(SYSTEM_PREFIXES):
        return None
    if dep.startswith("@rpath/") or dep.startswith("@loader_path/") or dep.startswith("@executable_path/"):
        name = dep.split("/", 1)[1]
        for cand in (os.path.join(prefix, "lib", name), os.path.join(os.path.dirname(loader), name)):
            if os.path.exists(cand):
                return os.path.realpath(cand)
        sys.exit(f"cannot resolve {dep} (needed by {loader})")
    if os.path.isabs(dep):
        if not os.path.realpath(dep).startswith(os.path.realpath(prefix) + "/"):
            sys.exit(f"{loader} links {dep}, which is outside the build prefix — the build picked up a foreign library")
        return os.path.realpath(dep)
    sys.exit(f"unexpected load command {dep} in {loader}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--frameworks", required=True, help="bundle directory that receives the dylibs")
    ap.add_argument("--bundle", required=True, help="bundle root, for the final check")
    ap.add_argument("roots", nargs="+", help="executables and plugins already copied into the bundle")
    a = ap.parse_args()

    os.makedirs(a.frameworks, exist_ok=True)
    queue = list(a.roots)
    seen = set()
    copied = {}  # realpath in prefix -> path in Frameworks

    while queue:
        binary = queue.pop()
        if binary in seen:
            continue
        seen.add(binary)
        install_id, deps, rpaths = load_commands(binary)

        changes = []
        for dep in deps:
            src = resolve(dep, a.prefix, binary)
            if src is None:
                continue
            name = os.path.basename(dep)
            if src not in copied:
                dst = os.path.join(a.frameworks, name)
                if not os.path.exists(dst):
                    shutil.copy2(src, dst)
                    os.chmod(dst, 0o755)
                copied[src] = dst
                queue.append(dst)
            new = "@rpath/" + name
            if dep != new:
                changes += ["-change", dep, new]

        if install_id is not None and os.path.dirname(binary) == a.frameworks:
            changes += ["-id", "@rpath/" + os.path.basename(binary)]

        rel = os.path.relpath(a.frameworks, os.path.dirname(binary))
        wanted = "@loader_path" if rel == "." else "@loader_path/" + rel
        for rp in rpaths:
            if rp != wanted:
                changes += ["-delete_rpath", rp]
        if wanted not in rpaths:
            changes += ["-add_rpath", wanted]

        if changes:
            run("install_name_tool", *changes, binary)

    # Final audit of everything in the bundle.
    bad = []
    for root, _, files in os.walk(a.bundle):
        for f in files:
            p = os.path.join(root, f)
            if not is_macho(p):
                continue
            _, deps, rpaths = load_commands(p)
            for d in deps + rpaths:
                if not (d.startswith(SYSTEM_PREFIXES) or d.startswith("@")):
                    bad.append(f"{os.path.relpath(p, a.bundle)} -> {d}")
    if bad:
        sys.exit("non-relocatable references left:\n  " + "\n  ".join(bad))
    print(f"relocated {len(seen)} Mach-O files, {len(copied)} libraries bundled")


if __name__ == "__main__":
    main()
