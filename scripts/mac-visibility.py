#!/usr/bin/env python3
"""Catches one class of Mac compile error Linux can't: a type declared without `public` in one
macOS-only module and used from another. Mac sources are parsed but never type-checked here,
so the Swift compiler on Linux never sees the visibility error (review 5/6)."""
import re, sys
from pathlib import Path

MAC_MODULES = ["GlossReaderKit", "GlossReaderEPUB", "GlossReaderPDF", "GlossEditor", "GlossUI", "GlossMac"]
DECL = re.compile(r'^(?:@\w+(?:\([^)]*\))?\s+)*(?P<access>public\s+|open\s+|internal\s+|private\s+|fileprivate\s+)?'
                  r'(?:final\s+)?(?:class|struct|enum|protocol|actor)\s+(?P<name>[A-Z]\w*)')

def strip(text: str) -> str:
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    return re.sub(r'"(?:\\.|[^"\\])*"', '""', text)

declared = {}  # name -> (module, public?)
sources = {m: [p for p in Path(f"Sources/{m}").glob("*.swift")] for m in MAC_MODULES}
for module, files in sources.items():
    for path in files:
        for line in strip(path.read_text()).splitlines():
            if line.startswith((" ", "\t")):
                continue  # nested types follow their parent's visibility; top level only
            match = DECL.match(line)
            if match:
                access = (match.group("access") or "").strip()
                declared[match.group("name")] = (module, access in ("public", "open"))

problems = []
for module, files in sources.items():
    for path in files:
        text = strip(path.read_text())
        for name, (home, public) in declared.items():
            if home == module or public:
                continue
            if re.search(rf'\b{name}\b', text):
                problems.append(f"{path}: uses {name}, which {home} doesn't make public")
for line in sorted(set(problems)):
    print(line)
if problems:
    print("✘ cross-module use of non-public Mac types (they'd fail to compile on macOS)")
    sys.exit(1)
print(f"✔ mac visibility: {len(declared)} top-level types, no cross-module leaks")
