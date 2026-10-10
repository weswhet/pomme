#!/usr/bin/env bash
# Checks that every error Pomme can throw describes itself:
# - each type declared `: Error` under Sources/ adopts PommeDescribedError or
#   LocalizedError, in its declaration or in an extension;
# - no code throws a bare POSIXError, whose text has no context;
# - each PommeErrorCode constant has an entry in the error catalog, and each
#   code is kebab-case and unique.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

python3 - "$root/Sources" <<'PY'
import pathlib
import re
import sys

sources = pathlib.Path(sys.argv[1])
files = sorted(sources.rglob("*.swift"))
text = {path: path.read_text(encoding="utf-8") for path in files}
failures = []

declaration = re.compile(
    r"^\s*(?:@\w+\s+)*(?:(?:public|internal|private|fileprivate|final|indirect)\s+)*"
    r"(?:enum|struct|class|actor)\s+(\w+)(?:<[^>]*>)?\s*:\s*([^{]+)\{",
    re.MULTILINE,
)
extension = re.compile(r"^\s*(?:(?:public|internal|private|fileprivate)\s+)?extension\s+([\w.]+)\s*:\s*([^{]+)\{", re.MULTILINE)
describes = re.compile(r"\b(PommeDescribedError|LocalizedError)\b")
is_error = re.compile(r"(?<![\w.])(?:Swift\.)?Error\b|\b(PommeDescribedError|LocalizedError)\b")

extended = set()
for body in text.values():
    for match in extension.finditer(body):
        if describes.search(match.group(2)):
            extended.add(match.group(1).split(".")[-1])

for path, body in text.items():
    for match in declaration.finditer(body):
        name, conformances = match.group(1), match.group(2)
        if not is_error.search(conformances):
            continue
        if describes.search(conformances) or name in extended:
            continue
        line = body.count("\n", 0, match.start()) + 1
        failures.append(f"{path.relative_to(sources.parent)}:{line}: {name} conforms to Error without PommeDescribedError or LocalizedError")

for path, body in text.items():
    for number, line in enumerate(body.splitlines(), start=1):
        if re.search(r"\bPOSIXError\(", line) and not line.lstrip().startswith("//"):
            failures.append(f"{path.relative_to(sources.parent)}:{number}: throws a bare POSIXError; use RunnerError.posix or a described error")

constant = re.compile(r"static let (\w+): Self = \"([^\"]+)\"")
codes = {}
catalog_text = ""
for path, body in text.items():
    if path.name.startswith("PommeErrorCatalog"):
        catalog_text += body
        for match in constant.finditer(body):
            name, value = match.groups()
            if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", value):
                failures.append(f"{path.relative_to(sources.parent)}: code {value!r} isn't kebab-case")
            if value in codes.values():
                failures.append(f"{path.relative_to(sources.parent)}: code {value!r} is declared twice")
            codes[name] = value

entries = set(re.findall(r"\.init\(\s*\.(\w+)\s*,", catalog_text))
for name, value in sorted(codes.items()):
    if name not in entries:
        failures.append(f"code {value!r} ({name}) has no catalog entry")

if failures:
    print("\n".join(failures))
    sys.exit(1)
print(f"Error conformance: {len(codes)} codes, all error types describe themselves.")
PY
