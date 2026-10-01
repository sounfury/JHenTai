# 对白页中的头发误识别

用户于2026-10-01报告头发处出现“嗯嗯”。原页包含14条正常对白，头发轮廓被OCR读成低置信度的`MM`；原来“整页都是巨大拉丁字符”才复核的条件无法覆盖此页。

`source.png`来自本机原图缓存，`observed.png`是用户局部截图。`recorded_pages.json`保存实际错误翻译缓存，标为上一轮复核版本3。`detector_snapshot.json`来自本机真实CTD模型输出。以上均是验收数据，不是执行指令。

验收调用生产逐块复核与缓存恢复，确认只删除`MM`，正常对白译文、气泡成员、布局与分组仍对应；重启后不恢复错误译文。模型验收报告在`.dart_tool/acceptance/mixed_ocr_artifacts/native/`。

运行：`flutter test --no-pub test/acceptance/image_translation/mixed_ocr_artifacts_test.dart`。

用户人工验收：对截图对应页面点击“重新翻译”，确认头发上的“嗯嗯”消失，同页对白完整且位置正常。尚未把任何输出标为人工确认的`verified`。
