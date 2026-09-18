彻底解决方块遮挡问题：
当处于「CTD + MI-GAN 修复背景」模式且背景修复成功时，自动将背板不透明度设为0（禁止绘制白色方块背板），只渲染排版后的译文文字，让修好的干净背景真正露出来！
彻底解决多气泡暴力合并问题：
重构 _containersFromBubbleDetection 与气泡聚类逻辑：加入空间距离阈值与连通性检验，当一个气泡检测框内检测到跨行/跨区域间隙过大时，拒绝强行打包，将其拆分为独立气泡分别排版。
消除静默失败，增加状态诊断： ✅ 已修复
在 CTD / MI-GAN 未就绪或执行失败时，明确输出 Warning 日志并在界面提示具体原因（如 ctd_not_ready 或 model_missing），而不是悄悄回退到方块让人误以为生效了。


bug
1. ✅ 已修复 — 在竖屏连续滚动的情况下，一般只有在页面尾部的时候（即下一页已经占据屏幕的80%，上一页只剩下一点点的时候），才会翻译体感上处于上一页的内容，用户体验极差
2. ✅ 已修复 — 文字有时会过大超出气泡，问题是原图文字字号不大，却被错误的识别为了大文字

feat:
1. ✅ 已完成 — 预翻译：在漫画详情页开关（默认关）；开启后立即在后台预翻译前 N 页（默认 30）；阅读页从持久缓存水合，仅补缺；沿用批量进度条/取消。
2. ✅ 已完成 — 自动翻译：阅读页翻译菜单外层可开关（设置页/配置面板仍保留）；开启后开始阅读/翻页时自动翻译当前页与下一页。

3. ✅ 已修复 — 目标语言与画廊语言相同时（如目标「简体中文」+ 熟肉 `language:chinese` / `gallery.language=Chinese`，或目标 English + english 画廊等）：详情页预翻译不启动并 toast；阅读页不因预翻译偏好强制打开 overlay；自动翻译跳过。检测按当前 `targetLanguage` 动态映射到 EH language key，非仅中文特例。


4. ✅ 已修复 — 冷启动/重开阅读页时，仅水合翻译 JSON 而未恢复 CTD+MI-GAN 修复背景，导致「缓存结果」译文叠在原文字上（尤其 `repairedBackgroundEmbeddedText` + 低/零背板透明度）。现：`hydrateTranslation` 成功后仅 `hydrateCachedRepair`（磁盘索引）；未命中则保持不透明背板，**不再**在 hydrate 内同步跑 `detectAndRepair`（避免与 OCR/bubble 抢 ONNX）。

5. ✅ 已修复 — PR#5 回归：重新翻译时只识别到稀疏 1–2 个气泡，随后 CTD+MI-GAN 把整页日文都擦掉，未翻译气泡变成空白。根因耦合：
   - (A) hydrate 同步 CTD 与 OCR/Manga109 争用共享 ONNX Runtime，识别覆盖率塌缩；旋转边栏二次识别若部分成功会整页丢弃边栏一阶段结果。
   - (B) `detectAndRepair` 用 CTD 全页文字 mask 擦除，不看翻译是否覆盖 → 稀疏 OCR 后空白气泡灾难。
   修复：hydrate 只恢复缓存修复；CTD erase 仅保留与已成功译文 OCR block 相交的 mask；强制重译前清掉陈旧 repaired 显示并取消 in-flight CTD；气泡检测框内 OCR 大间隙拆分；OCR 旋转边栏结果按 IoU 合并而非整页丢弃。
   Fixture：`test/fixtures/blue_archive_kotori_sauna_page.png`（离线 RapidOCR 基线 16 blocks）。


6. ✅ 已修复 — 同语言画廊（目标「简体中文」+ 熟肉 `language:chinese` 等）时，阅读页「文A」翻译悬浮球仍显示。现：`buildFloatingTranslationBall` 在 `galleryAlreadyInTargetLanguage` 为真时隐藏；书签悬浮球与顶部翻译菜单保留（可手动翻译）。`collectGalleryEhLanguageKeys` 兼容无 `language:` 前缀的 tags CSV 以及 `Chinese`/`ZH`/`中文` 等 language 字段。

仍未实现（非本次范围）:
- CTD + MI-GAN 成功时白板问题（部分场景）
