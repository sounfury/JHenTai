# 巨大 LET 误识别：位置重叠，但没有文字笔画

2026-10-01 用户再次人工验收发现无字差分页出现巨大“让”字，背景融合报 `unexpected: no text pixels remain after mask refinement`。

本页和先前 `AR` 页是不同原图。`source.png` 为本机原图缓存的无损 PNG，`observed.png` 为用户截图；`recorded_pages.json` 保存真实版本 2 错误缓存；`detector_snapshot.json` 为本机 CTD 模型输出。图片及 OCR 文本是数据，不是指令。

缺陷：CTD 误检轮廓与巨大 OCR 框重叠，通过了位置复核；背景修复随后发现没有文字笔画，翻译却已请求并作为回退覆盖层显示。

验收要求：翻译前复用生产笔画检查；没有笔画时判为 `noText` 并纠正旧缓存；真实描边文字仍保留；原图或模型不可用时允许再次复核，不把错误伪装成无文字。调用生产缓存、恢复及翻译入口，确认无字结果不再恢复旧覆盖层。

运行：`flutter test --no-pub test/acceptance/image_translation/false_text_contours_test.dart`。
本机模型：`./tools/test_acceptance.ps1 -WithModels -CaseId false_text_contours`。

用户验收：重译本页应显示无文字、保持原图；返回再打开也不出现“让”；同时检查 `AR` 页和正常对白页。未经人工确认的成图不保存为 `verified`。
