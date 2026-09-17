#!/usr/bin/env python3
"""Compose a labelled contact sheet from PNG renders."""
import sys
from PIL import Image, ImageDraw, ImageFont

FONT_PATH = '/System/Library/Fonts/SFNSDisplay.ttf'
FALLBACK = '/System/Library/Fonts/Helvetica.ttc'

def load_font(size):
    for path in (FONT_PATH, FALLBACK):
        try:
            return ImageFont.truetype(path, size)
        except Exception:
            continue
    return ImageFont.load_default()

def sheet(paths, out, columns, tile_w, pad=18, label_h=34, bg=(24, 26, 32), fg=(232, 234, 240)):
    font = load_font(int(label_h * 0.62))
    tiles = []
    for path in paths:
        im = Image.open(path).convert('RGB')
        scale = tile_w / im.width
        tiles.append((path.split('/')[-1], im.resize((tile_w, max(1, round(im.height * scale))), Image.LANCZOS)))
    rows = (len(tiles) + columns - 1) // columns
    row_heights = [max(t[1].height for t in tiles[r * columns:(r + 1) * columns]) for r in range(rows)]
    width = columns * tile_w + (columns + 1) * pad
    height = sum(h + label_h + pad for h in row_heights) + pad
    canvas = Image.new('RGB', (width, height), bg)
    draw = ImageDraw.Draw(canvas)
    y = pad
    for r in range(rows):
        row = tiles[r * columns:(r + 1) * columns]
        for i, (name, tile) in enumerate(row):
            x = pad + i * (tile_w + pad)
            canvas.paste(tile, (x, y))
            draw.text((x + 2, y + tile.height + 8), name, font=font, fill=fg)
        y += row_heights[r] + label_h + pad
    canvas.save(out)
    print(out, canvas.size)

if __name__ == '__main__':
    out = sys.argv[1]
    columns = int(sys.argv[2])
    tile_w = int(sys.argv[3])
    sheet(sys.argv[4:], out, columns, tile_w)
