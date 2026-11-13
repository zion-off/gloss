#!/usr/bin/env python3
"""Type-checks the macOS-only modules on Linux against stub Apple frameworks (D-099).

The Mac targets compile to empty modules on Linux (every file sits in `#if os(macOS)`), so the
compiler never sees their bodies. This script compiles them for real:

1. `scripts/mac-stubs/<Framework>.swift` declares the slice of AppKit, SwiftUI, WebKit and
   PDFKit the app uses, copied from Apple's documentation (each block names its source). They
   are compiled into stand-in modules.
2. Each Mac target's sources are copied with `#if os(macOS)` turned on, `@objc` dropped (Linux
   has no Objective-C runtime), `#selector(m)` turned into a call that still checks `m` exists,
   `import Foundation` joined by FoundationNetworking (where Linux keeps URLRequest),
   and SwiftUI's `@Entry` macro expanded by hand (no macro plugin on Linux). Line numbers are
   kept, so errors point at the real files.
3. The targets are compiled in dependency order against the portable modules `swift build`
   already built (`.build/debug`) and the stand-ins.

It also checks that every module a Mac target imports is one of its declared dependencies in
Package.swift (or an Apple framework): the compiler here sees every module, SwiftPM on a Mac
doesn't.

What it proves: our own code is consistent across modules (names, labels, types, isolation)
and calls the Apple APIs as declared in the stubs. What it can't: behaviour, and anything the
stubs get wrong — a stub is only as good as the documentation it was copied from.

Run `swift build` first (scripts/check.sh does). Another build directory (a `--scratch-path`
build, as scripts/verify-commits.sh makes) is named with GLOSS_BUILD_DIR=<scratch>/debug. Exit
status 1 on any error.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUILD = Path(os.environ.get("GLOSS_BUILD_DIR", ROOT / ".build" / "debug"))
CHECKOUTS = BUILD.parent / "checkouts"  # next to `debug` in .build and in any scratch path
# One scratch directory per checkout, so a worktree's run never clobbers the main one's.
OUT = Path(os.environ.get("TMPDIR", "/tmp")) / f"gloss-mac-typecheck-{hashlib.sha1(str(ROOT).encode()).hexdigest()[:8]}"
STUBS = ROOT / "scripts" / "mac-stubs"

# Stand-in frameworks, in dependency order (each may import the ones before it).
STUB_MODULES = ["AppKit", "UniformTypeIdentifiers", "SwiftUI", "WebKit", "PDFKit"]
# Mac targets in dependency order; True marks targets that own SwiftPM resources (Bundle.module).
MAC_TARGETS = [
    ("GlossReaderKit", False),
    ("GlossEditor", False),
    ("GlossReaderEPUB", True),
    ("GlossReaderPDF", False),
    ("GlossUI", False),
    ("GlossMac", False),
]
EXECUTABLES = {"GlossMac"}

# C modules the portable Swift modules were built against.
MODULE_MAPS = [
    ROOT / "Sources/CZlib/module.modulemap",
    CHECKOUTS / "GRDB.swift/Sources/GRDBSQLite/module.modulemap",
    CHECKOUTS / "swift-crypto/Sources/CXKCPShims/include/module.modulemap",
    CHECKOUTS / "swift-crypto/Sources/CXKCP/include/module.modulemap",
    CHECKOUTS / "swift-crypto/Sources/CCryptoBoringSSL/include/module.modulemap",
]

# Modules a Mac target may import without declaring them: the SDK's.
SYSTEM_MODULES = {"Foundation", "FoundationNetworking", "AppKit", "SwiftUI", "WebKit", "PDFKit",
                  "UniformTypeIdentifiers", "Observation", "Dispatch", "CoreGraphics", "QuartzCore"}
IMPORT = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:struct|class|enum|protocol|func|var|let|typealias)\s+)?(\w+)")


def undeclared_imports() -> list[str]:
    """`import X` lines in Mac targets whose X isn't a declared dependency."""
    dump = subprocess.run(["swift", "package", "dump-package"], cwd=ROOT, capture_output=True, text=True)
    if dump.returncode != 0:
        return [f"swift package dump-package failed: {dump.stderr.strip()[:200]}"]
    declared = {}
    for target in json.loads(dump.stdout)["targets"]:
        names = set()
        for dependency in target["dependencies"]:
            for kind in ("byName", "target", "product"):
                if kind in dependency:
                    names.add(dependency[kind][0])
        declared[target["name"]] = names
    problems = []
    for target, _ in MAC_TARGETS:
        for path in sorted((ROOT / "Sources" / target).rglob("*.swift")):
            for number, line in enumerate(path.read_text().split("\n"), start=1):
                match = IMPORT.match(line)
                if match and match.group(1) not in SYSTEM_MODULES | declared.get(target, set()):
                    problems.append(f"{path.relative_to(ROOT)}:{number}: imports {match.group(1)}, "
                                    f"which isn't a dependency of {target} in Package.swift")
    return problems


SELECTOR_SHIM = """
// Added by scripts/mac-typecheck.py: `#selector(m)` becomes `_glossSelector(m)`, which still
// makes the compiler find `m`.
func _glossSelector<T>(_ method: T) -> Selector { Selector("") }
"""
BUNDLE_SHIM = """
// Added by scripts/mac-typecheck.py: SwiftPM generates `Bundle.module` for targets with resources.
import Foundation
extension Foundation.Bundle { static var module: Bundle { .main } }
"""

ENTRY = re.compile(r"^(\s*)@Entry\s+((?:public\s+|internal\s+)?)var\s+(\w+)\s*:\s*([^=]+?)\s*(?:=.*)?$")


def preprocess(text: str, path: Path) -> str:
    """The macOS view of a source file, line for line."""
    lines = []
    for number, line in enumerate(text.split("\n"), start=1):
        if line.strip().startswith("#if") and "os(macOS)" in line:
            line = line.replace("os(macOS)", "true")
        match = ENTRY.match(line)
        if match:
            indent, access, name, type_ = match.groups()
            # SwiftUI's @Entry expands to a stored key plus this accessor; only the accessor's
            # type matters here.
            line = f"{indent}{access}var {name}: {type_} {{ get {{ fatalError() }} set {{ }} }}"
        elif "@Entry" in line:
            sys.exit(f"{path}:{number}: mac-typecheck can't expand this @Entry; keep it on one line as `@Entry var name: Type = value`")
        if line.strip() == "import Foundation":
            # On Darwin URLRequest and HTTPURLResponse are Foundation; on Linux, FoundationNetworking.
            line = "import Foundation; import FoundationNetworking"
        line = re.sub(r"@objc(\([^)]*\))?\s+", "", line)
        line = line.replace("#selector(", "_glossSelector(")
        lines.append(line)
    return "\n".join(lines)


def run(args: list[str], scratch_to_repo: dict[str, str]) -> bool:
    result = subprocess.run(args, capture_output=True, text=True)
    output = result.stdout + result.stderr
    for scratch, repo in scratch_to_repo.items():
        output = output.replace(scratch, repo)
    errors = [l for l in output.splitlines() if ": error:" in l or l.startswith("<unknown>")]
    warnings = [l for l in output.splitlines() if ": warning:" in l and str(ROOT / "Sources") in l]
    if result.returncode != 0 or errors:
        print(output.rstrip())
        return False
    for w in sorted(set(warnings)):
        print(w)
    return not warnings


def main() -> int:
    if not (BUILD / "GlossAppModel.swiftmodule").exists():
        print("✘ mac typecheck: run `swift build` first")
        return 1
    problems = undeclared_imports()
    if problems:
        print("\n".join(problems))
        print("✘ mac typecheck: Mac targets import modules they don't depend on")
        return 1
    shutil.rmtree(OUT, ignore_errors=True)
    (OUT / "modules").mkdir(parents=True)
    # Our modules first: `.build/debug` also holds the empty Linux builds of the Mac targets.
    common = ["swiftc", "-swift-version", "6", "-parse-as-library", "-I", str(OUT / "modules"), "-I", str(BUILD)]
    for map_ in MODULE_MAPS:
        common += ["-Xcc", f"-fmodule-map-file={map_}"]

    for stub in STUB_MODULES:
        source = STUBS / f"{stub}.swift"
        args = common + ["-emit-module", "-module-name", stub, "-emit-module-path", str(OUT / "modules" / f"{stub}.swiftmodule"), str(source)]
        if not run(args, {}):
            print(f"✘ mac typecheck: the {stub} stub doesn't compile")
            return 1

    for target, has_resources in MAC_TARGETS:
        source_dir = ROOT / "Sources" / target
        scratch_dir = OUT / "sources" / target
        scratch_dir.mkdir(parents=True)
        files, mapping = [], {}
        for path in sorted(source_dir.rglob("*.swift")):
            copy = scratch_dir / path.relative_to(source_dir)
            copy.parent.mkdir(parents=True, exist_ok=True)
            copy.write_text(preprocess(path.read_text(), path.relative_to(ROOT)))
            files.append(str(copy))
            mapping[str(copy)] = str(path)
        shims = scratch_dir / "_Shims.swift"
        shims.write_text("import AppKit\n" + SELECTOR_SHIM + (BUNDLE_SHIM if has_resources else ""))
        files.append(str(shims))
        if target in EXECUTABLES:
            args = common + ["-typecheck", "-module-name", target] + files
        else:
            args = common + ["-emit-module", "-module-name", target,
                             "-emit-module-path", str(OUT / "modules" / f"{target}.swiftmodule")] + files
        if not run(args, mapping):
            print(f"✘ mac typecheck: {target} doesn't type-check against the stubs")
            return 1
    print(f"✔ mac modules type-check against the stubs ({len(MAC_TARGETS)} targets)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
