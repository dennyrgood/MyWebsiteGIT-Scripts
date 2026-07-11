#!/bin/zsh

# Convert Mermaid files to PNG, SVG, and PDF using Mermaid CLI (mmdc)
# Usage: mermaid_convert <file.md|file.mermaid|file.mmd|file.merdian> [png_scale]

if [ $# -eq 0 ]; then
    echo "Usage: $0 <mermaid_file> [png_scale]"
    echo "Example: $0 diagram.md 3"
    exit 1
fi

INPUT="$1"

# Default PNG scale
SCALE="${2:-3}"

if [ ! -f "$INPUT" ]; then
    echo "Error: File not found: $INPUT"
    exit 1
fi

# Remove extension for output names
BASE="${INPUT%.*}"

echo "Converting: $INPUT"
echo "PNG scale: $SCALE"

# SVG (vector, best quality)
mmdc -i "$INPUT" -o "${BASE}.svg"

# PNG (raster, scaled)
mmdc -i "$INPUT" -o "${BASE}.png" -s "$SCALE"

# PDF
mmdc -i "$INPUT" -o "${BASE}.pdf"

echo ""
echo "Created:"
echo "  ${BASE}.svg"
echo "  ${BASE}.png"
echo "  ${BASE}.pdf"
