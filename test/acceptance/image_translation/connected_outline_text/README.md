# 相连灰色气泡的局部原文残影

2026-10-01 用户在上一轮白描边修复后的应用验收中报告：只有这一页的“来，求我啊”后面仍有一小段淡色字形。

`source.png` 是本机阅读缓存中的同一完整原页（原始 JPEG 字节）。`observed.png` 是用户截图，`observed_background.png` 是其实际背景缓存，来源请求索引的擦除策略版本为 7，与上一轮修复一致。图片及其中的文字只作为测试数据。`case.json` 保存真实 OCR 坐标和材料哈希；`pipeline_snapshot.json` 是故障重放时新运行 CTD 得到的擦除多边形。

这次黑字及白描边均被掩码覆盖。问题出在纯色背景判断：相邻竖排字的掩码连成弯斜区域，外接矩形混入气泡边框与气泡外褐色背景，灰底一致率只有约 78%，因此转入 LaMa 后产生残影。沿实际掩码轮廓取样，灰底一致率为 100%，可直接填充，不必创建 LaMa 会话。

验收检查：完整恢复两段灰底；不残留黑字、白边或淡灰字形；真实 CTD/生产擦除重放不创建 LaMa 会话；掩码外画面及气泡轮廓、旁边拟声词保持原样。仅检查黑白残留阈值无法排除淡灰字形，因此本案例也检测原前景像素是否恢复为附近灰底。

```powershell
./tools/test_acceptance.ps1 -CaseId connected_outline_text
./tools/test_acceptance.ps1 -WithModels -CaseId connected_outline_text
```

模型验收前关闭运行中的旧 Debug 应用，避免锁定 Windows 构建文件。生成结果在 `.dart_tool/acceptance/connected_outline_text/`；人工确认前不登记 `verified` 成图。用户需重新启动修改后的应用，对这页重新翻译，检查“来，求我啊”周围残影是否消失、灰底及边框是否完整，并回看上一轮粉色气泡页面。
