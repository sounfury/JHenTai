# 横排多行彩字与白描边漏擦

2026-10-07 用户在 Debug 版本中重新翻译漫画第二页后复现。`source.png` 是该页阅读缓存的原始 JPEG 字节，`observed.png` 是本次异常背景缓存，`pipeline_snapshot.json` 来自同一原页重新运行真实 CTD 得到的全部检测多边形。图片中的文字仅作为验收数据。

CTD 把上方八行对白合为一个区域，旧代码取单行最大覆盖率 10.39%，低于 15% 门槛，因此漏擦整段；右下五行也因单行最大覆盖率 14.96% 被排除。各行交集的并集覆盖率分别为 62.88% 和 67.84%。白描边还会因横向相连、缺少黑字锚点或连到亮色背景而漏擦。

验收检查：真实整段进入擦除；对白彩字及白描边漏擦低于 1%；未翻译的相机菜单及对白旁的装饰弧线保持原样；重复识别框不能叠加授权，未翻译行仍受保护。颜色阈值只用于这张图的残留评估，不参与生产文字识别。`evaluationRects` 使用真实 OCR 框，仅评估对白，排除相机界面与旁边的装饰拟声词。

快速验收：`./tools/test_acceptance.ps1 -CaseId colored_horizontal_text`。

真实模型重放：`./tools/test_acceptance.ps1 -WithModels -CaseId colored_horizontal_text`。输出保存到 `.dart_tool/acceptance/colored_horizontal_text/`，不调用翻译 API，不替换用户阅读缓存。最终需要用户在修改后的 Debug 应用中重新翻译第二页，检查原文、白边残留及周围画面；人工确认前不登记 `verified` 成图。
