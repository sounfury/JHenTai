# Recognition fixtures

## `blue_archive_kotori_sauna_page.png`

Ground-truth Blue Archive page (Kotori / sauna stove) used to lock the
sparse-OCR + full-page CTD erase regression.

Expected content includes many vertical Japanese bubbles/captions:
top `ぱんっ` / `そう！` / `必要なんです！！` / `必要ですか？` / `必要ですよね？` /
`エンジニア部所属・コトリ` / `説明が…` / `ピッ`; mid sauna captions; bottom
heater captions; multiple `カン` SFX.

## `sauna_page_rapidocr_blocks.json`

Offline RapidOCR (`rapidocr-onnxruntime`) dump on the PNG above.
Baseline count: **16 OCR blocks** on a 1280×1807 page. A healthy app
recognition path must cover most dialogue/caption boxes (clearly more than
1–2). Re-generate with:

```bash
.venv/bin/python tools/dump_sauna_page_ocr.py
```
