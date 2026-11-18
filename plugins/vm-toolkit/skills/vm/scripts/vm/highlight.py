#!/usr/bin/env python3
"""Highlight regions of the screen: outlined boxes, an optional label each, the rest dimmed. For a screenshot, and
(through record.py) for a recording.

  highlight.py IN.png OUT.png [--no-dim] REGION...   OUT is IN with the regions highlighted; IN is kept as it is

A REGION is x,y,width,height[,label] in screenshot pixels (the label may hold commas). The outline sits a few pixels
outside the region so it never covers what it points at (a clipped edge, a cut-off word); --no-dim keeps the rest of
the screen as it is when it matters too. The drawing is overlay.js's (AppKit), shared with the recordings.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import record  # noqa: E402
import vm  # noqa: E402


def parse(args):
    """(regions, dim) from the command line's flags and regions; ValueError on a bad region."""
    dim, regions = True, []
    for a in args:
        if a == "--no-dim":
            dim = False
            continue
        parts = a.split(",", 4)
        if len(parts) < 4:
            raise ValueError(f"a region is x,y,width,height[,label]: {a!r}")
        x, y, w, h = (int(p) for p in parts[:4])
        if w < 1 or h < 1:
            raise ValueError(f"a region needs a width and a height: {a!r}")
        regions.append({"x": x, "y": y, "width": w, "height": h, "label": parts[4] if len(parts) > 4 else ""})
    return regions, dim


def draw(out, w, h, regions, dim):
    """A w x h transparent PNG with the regions highlighted, to lay over the screen; False when it could not be drawn."""
    return record.overlay("highlight", out, str(w), str(h), "1" if dim else "0", json.dumps(regions))


def mark(src, out, regions, dim):
    w, h = vm.png_size(src)
    layer = out + ".layer.png"
    try:
        if not draw(layer, w, h, regions, dim):
            return 1
        # In RGB: ffmpeg overlays in YUV 4:2:0 by default, which would blur the outline and change every pixel of the shot.
        rc = record.ffmpeg("-i", src, "-i", layer, "-filter_complex", "overlay=format=rgb", "-pix_fmt", "rgb24", "-frames:v", "1",
                           out).returncode
    finally:
        if os.path.exists(layer):
            os.remove(layer)
    return rc


def main():
    if len(sys.argv) < 4:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        regions, dim = parse(sys.argv[3:])
    except ValueError as e:
        print(f"highlight: {e}", file=sys.stderr)
        return 2
    if not regions:
        print("highlight: no region", file=sys.stderr)
        return 2
    rc = mark(sys.argv[1], sys.argv[2], regions, dim)
    if rc == 0:
        print(os.path.abspath(sys.argv[2]))
    return rc


if __name__ == "__main__":
    sys.exit(main())
