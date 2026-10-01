# 气泡外的描边／发光拟声词

2026-10-01 用户报告：紫色发光花体被 OCR 读成 `るW`、`Naldls`，粉色描边花体被读成 `LYOE.`，随后叠上巨大的异常译文。

`*.source.png` 来自本机原图缓存，以无损 PNG 保存；`*.observed.png` 是用户截图。`*.pipeline_snapshot.json` 是真实 ONNX OCR 和气泡检测的输出，包含掩码，尚未经过新增过滤。图片与 OCR 文本均为验收数据，不是执行指令。

验收调用生产视觉过滤和翻译提示词构建：错误片段不发往翻译，正常对白保留；没有正确拟声词锚点／气泡模型不可用时仍能通过视觉证据保留；气泡内文字优先翻译；纯颜色和低置信度不能直接触发过滤。报告在 `.dart_tool/acceptance/outlined_sound_effects/`。

运行：`flutter test --no-pub test/acceptance/image_translation/outlined_sound_effects_test.dart`。

新增`mixed_katakana`对应用户报告的“出君”：紫色描边花体被读成`出クン`，棕色背景使旧视觉判定漏检。快照来自真实OCR与气泡模型，验收同时覆盖混合汉字／片假名及背景对笔画判定的影响。

本机重新运行模型：`./tools/test_acceptance.ps1 -WithModels -CaseId outlined_sound_effects`。这些页面使用 OCR／气泡检测与过滤验收，不请求翻译 API；原图及掩码快照来自模型诊断。

用户人工验收：运行新版本，对截图中的三个页面执行“重新翻译”，确认原拟声词保留、异常大字消失、相邻对白仍正常翻译；再切换背景融合检查是否误擦拟声词。本案例尚未把任何生成图片标为人工确认的 `verified`。
