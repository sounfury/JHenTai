#!/usr/bin/env python3
"""Re-dump RapidOCR blocks for the sauna-page recognition fixture."""
from __future__ import annotations

import json
from pathlib import Path

from rapidocr_onnxruntime import RapidOCR
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
PNG = ROOT / "test/fixtures/blue_archive_kotori_sauna_page.png"
OUT = ROOT / "test/fixtures/sauna_page_rapidocr_blocks.json"


def main() -> None:
    im = Image.open(PNG)
    result, elapse = RapidOCR()(str(PNG))
    blocks = []
    for i, item in enumerate(result or []):
        box, text, conf = item[0], item[1], item[2]
        xs = [float(p[0]) for p in box]
        ys = [float(p[1]) for p in box]
        left, top = min(xs), min(ys)
        blocks.append(
            {
                "text": str(text),
                "confidence": float(conf),
                "left": left,
                "top": top,
                "width": max(xs) - left,
                "height": max(ys) - top,
            }
        )
    OUT.write_text(
        json.dumps({"imageSize": list(im.size), "blocks": blocks}, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    print(f"wrote {len(blocks)} blocks elapse={elapse} -> {OUT}")


if __name__ == "__main__":
    main()
