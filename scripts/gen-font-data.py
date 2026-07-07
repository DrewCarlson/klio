#!/usr/bin/env python3
# Regenerates src/compose_ui/font_data.cpp from the bundled fallback font.
#
# The bundled font is a Latin subset of Noto Sans Mono (Google, SIL OFL 1.1 —
# see src/compose_ui/fonts/LICENSE.txt), produced from the upstream regular face
# with fonttools:
#
#   pyftsubset NotoSansMono-Regular.ttf \
#     --unicodes="U+0020-007E,U+00A0-00FF,U+2018-201F,U+2022,U+2026,U+2192,U+2190" \
#     --layout-features='' --no-hinting --desubroutinize \
#     --output-file=src/compose_ui/fonts/NotoSansMono-klio.ttf
#
# The subset .ttf (~15 KB) is committed; this script bakes it into a C++ byte
# array the Skia shim links (klio_embedded_font / klio_embedded_font_size), so the
# renderer has a self-contained default and text works on fontless hosts.
#
# Usage: python3 scripts/gen-font-data.py

import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TTF = os.path.join(ROOT, "src/compose_ui/fonts/NotoSansMono-klio.ttf")
OUT = os.path.join(ROOT, "src/compose_ui/font_data.cpp")


def main() -> None:
    data = open(TTF, "rb").read()
    lines = [
        "// Generated from src/compose_ui/fonts/NotoSansMono-klio.ttf — do not edit.",
        "// Regenerate: scripts/gen-font-data.py (see that script's header).",
        "// The bundled fallback font (Noto Sans Mono, Latin subset; OFL 1.1).",
        'extern "C" const unsigned char klio_embedded_font[] = {',
    ]
    row = []
    for b in data:
        row.append("0x%02x," % b)
        if len(row) == 20:
            lines.append("".join(row))
            row = []
    if row:
        lines.append("".join(row))
    lines.append("};")
    lines.append('extern "C" const unsigned int klio_embedded_font_size = %d;' % len(data))
    open(OUT, "w").write("\n".join(lines) + "\n")
    print("wrote %s (%d font bytes)" % (OUT, len(data)))


if __name__ == "__main__":
    main()
