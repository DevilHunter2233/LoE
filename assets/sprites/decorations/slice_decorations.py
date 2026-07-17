"""
slice_decorations.py

Automatically slices a hand-painted decoration/prop sheet (transparent PNG)
into individual trimmed sprite PNGs, one per connected non-transparent blob.

Use this for prop sheets like Decorations_Hazards, BackgroundDecoration,
FloatingPlatforms, MossyHills, Hanging_Plants -- NOT for true grid tilesets
like Mossy_-_TileSet.png (that one should stay sliced at a fixed 512x512
grid in Godot's TileSet editor).

Usage:
    python slice_decorations.py input.png output_folder/ [--pad 3] [--min-area 200] [--alpha-thresh 10]

Requires: pillow, numpy, scipy
"""

import sys
import os
import json
import argparse
import numpy as np
from PIL import Image
from scipy import ndimage


def slice_sheet(input_path, output_dir, pad=3, min_area=200, alpha_thresh=10):
    os.makedirs(output_dir, exist_ok=True)

    img = Image.open(input_path).convert("RGBA")
    arr = np.array(img)
    alpha = arr[:, :, 3]

    # Binary mask of "has content"
    mask = alpha > alpha_thresh

    # Dilate slightly before labeling so nearly-touching pieces that are
    # meant to be one element (e.g. a vine with separate leaf sub-shapes)
    # don't get split into a dozen tiny fragments. Adjust structure size
    # if you find pieces are wrongly merged or wrongly split.
    dilated = ndimage.binary_dilation(mask, iterations=2)

    labeled, num_features = ndimage.label(dilated)
    print(f"Found {num_features} connected regions in {os.path.basename(input_path)}")

    manifest = []
    base_name = os.path.splitext(os.path.basename(input_path))[0]

    kept = 0
    for region_id in range(1, num_features + 1):
        ys, xs = np.where(labeled == region_id)
        area = len(xs)
        if area < min_area:
            continue  # skip specks / anti-aliasing noise

        x0, x1 = xs.min(), xs.max()
        y0, y1 = ys.min(), ys.max()

        # Crop from the ORIGINAL (non-dilated) mask/image, with padding
        x0p = max(0, x0 - pad)
        y0p = max(0, y0 - pad)
        x1p = min(arr.shape[1], x1 + pad + 1)
        y1p = min(arr.shape[0], y1 + pad + 1)

        crop = img.crop((x0p, y0p, x1p, y1p))

        kept += 1
        out_name = f"{base_name}_{kept:03d}.png"
        crop.save(os.path.join(output_dir, out_name))

        manifest.append({
            "file": out_name,
            "source_sheet": os.path.basename(input_path),
            "bbox": [int(x0p), int(y0p), int(x1p - x0p), int(y1p - y0p)],
            "area_px": int(area),
        })

    manifest_path = os.path.join(output_dir, f"{base_name}_manifest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)

    print(f"Exported {kept} sprites to {output_dir}")
    print(f"Manifest written to {manifest_path}")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Slice a decoration sheet into individual trimmed sprites.")
    parser.add_argument("input", help="Path to input PNG sheet")
    parser.add_argument("output_dir", help="Folder to write sliced sprites + manifest into")
    parser.add_argument("--pad", type=int, default=3, help="Padding in px around each cropped sprite")
    parser.add_argument("--min-area", type=int, default=200, help="Minimum pixel area to keep a region (filters noise)")
    parser.add_argument("--alpha-thresh", type=int, default=10, help="Alpha value above which a pixel counts as 'content'")
    args = parser.parse_args()

    slice_sheet(args.input, args.output_dir, pad=args.pad, min_area=args.min_area, alpha_thresh=args.alpha_thresh)
