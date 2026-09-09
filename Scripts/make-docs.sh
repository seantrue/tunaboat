#!/bin/bash
# Renders README.md into a single self-contained HTML file for distribution.
#
#   Scripts/make-docs.sh
#
# Output: docs/Tunaboat.html — one file, no external assets. The stylesheet is inlined and the
# header artwork is embedded as a data URI, so the page can be attached to a release, mailed,
# or opened from a disk image and still look like itself with no network.
#
# The output is committed, so a normal build does not need pandoc.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v pandoc >/dev/null; then
    echo "error: needs pandoc (brew install pandoc)" >&2
    exit 1
fi

OUT="docs/Tunaboat.html"
mkdir -p docs

VERSION="$(git describe --tags --match 'v[0-9]*' --abbrev=0 2>/dev/null || echo v0.1.0)"
VERSION="${VERSION#v}"

# --embed-resources inlines the CSS and the artwork; without it the page is a shell that only
# works from inside the repository, which defeats the point of shipping it.
pandoc README.md \
    --standalone \
    --embed-resources \
    --from gfm \
    --to html5 \
    --metadata title="Tunaboat" \
    --metadata lang=en \
    --css Scripts/doc-style.css \
    --output "$OUT"

# pandoc emits a bare <table>; wrapping it lets a wide table scroll inside itself rather than
# forcing the whole page sideways on a narrow window.
python3 - "$OUT" "$VERSION" <<'PY'
import re, sys, datetime
path, version = sys.argv[1], sys.argv[2]
html = open(path, encoding="utf-8").read()
html = html.replace("<table>", '<div class="table-wrap"><table>').replace("</table>", "</table></div>")

footer = (
    f'<footer class="doc-footer">Tunaboat {version} — '
    f'generated from README.md on {datetime.date.today().isoformat()}.</footer>\n'
)
html = html.replace("</body>", footer + "</body>")
open(path, "w", encoding="utf-8").write(html)
PY

echo "==> wrote $OUT ($(du -h "$OUT" | cut -f1), self-contained)"
