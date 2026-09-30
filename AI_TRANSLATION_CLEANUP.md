# AI 翻译代码收尾清单

日期：2026-09-30。编号对应代码审查结果；只有代码修改和相关自动检查完成后，才勾选开发事项。用户验收单独记录，不用自动测试代替。

## 开发事项

- [x] **1. 移除闲置的 llama-server 生产链路（高优先级）**
  - 本地 GGUF 已统一使用 FFI，引擎注册、自动下载 server runtime、桌面 runtime 管理界面及路径配置仍然残留。
  - 清理生产入口和关联配置、导出、模型引擎标识、界面文案；保留当前本地模型下载及 FFI 翻译能力。
  - 兼容已有回归测试；不删除用户已经下载的文件。
  - 已移除 server 引擎、生产 runtime 安装器、下载/管理界面、路径配置和旧文案；历史安装器移至 `test/support/legacy_llama_runtime_store.dart`，仅供已有回归测试。
  - LAN 设置导入/导出仍剔除旧 `localLlamaServerPath` 字段，避免传播老配置中的机器路径。
- [x] **2. 统一阅读器和导出图片的渲染流程（高优先级）**
  - 两处重复维护文字分组、颜色、边界、竖排、字号和区域布局。
  - 提取公共布局构建与绘制函数，显式传入可见图片区域、方向和样式。
  - 保留空译文的 OCR 索引占位，修复短译文能显示但导出报 `OVERLAY_NOT_READY` 的问题；旧缓存中的小尺寸文字块不能导致译文错位。
  - 已提取 `lib/src/utils/image_translation_renderer.dart`，阅读器和导出共用布局及绘制；导出支持仅有分组译文的结果。
  - 边界在源图坐标中检查，绘制区域裁剪到可见图片内，避免背景板进入阅读器留白。
- [x] **3. 删除人工等待并修复取消竞争（高优先级）**
  - 删除 `masking` / `embedding` 的两次 80ms 等待和虚假进度。
  - 检查取消后的任务完成处理，避免把已取消状态重新发布为成功。
  - 已移除虚假阶段、枚举和文案；单页翻译记录取消代次，在引擎准备和缓存写入后重新检查，避免取消标志重置后旧任务继续完成。
- [x] **4. 统一 API 与本地翻译协议**
  - 复用单页和上下文提示词、响应 schema、推理文本清理、JSON 提取与编号解析。
  - API / 本地模型的请求传输及配额差异保持独立。
  - 已将本地专用提示词模块改为 `translation_protocol.dart`；API、FFI 共用单页分组和译文展开、上下文提示词及 schema、推理文本清理和 JSON 解析，持久缓存也复用清理函数。
  - 单页分组只计算一次；保留旧编号响应兼容和本地空译文检查。
- [x] **5. 复用 API 请求基础逻辑和模型列表查询**
  - 单页与上下文复用鉴权、取消、响应提取及错误转换。
  - 模型列表只保留一份实现，维持界面已有错误码；保留各自超时和 token 配额。
  - 单页与上下文共用 `_requestTranslation`，统一鉴权、取消订阅释放、请求构建、响应提取和网络错误转换；保留 90/120 秒接收超时及各供应商 token 设置。
  - 翻译服务的模型列表入口委托 API 引擎，仅转换为原有 `API_CONFIGURATION_REQUIRED` / `MODELS_INVALID_RESPONSE` / `MODELS_EMPTY` 界面错误码。
- [ ] **6. 拆分识别流水线及过大的翻译服务**
  - `recognizeImage` 按源图/缓存、识别整理、拟声词过滤、容器布局拆分。
  - 缓存存储、图片导出和画廊文本翻译逐步从 `ImageTranslationService` 分离。
  - 主流程保留清晰的操作顺序、取消检查和错误处理。
- [x] **7. 复用阅读器和预翻译的背景修复入口**
  - 提取模式判断、擦除/保护块构建、缓存恢复及修复调用；调用方处理提示和刷新。
  - `translatedBlocksEligibleForErase` 内重复计算的文字分组只计算一次。
  - 已统一到 `ImageInpaintingService.repairTranslation`，阅读器和预翻译共用模式/结果检查、缓存恢复、擦除/保护块构建和修复调用；阅读器负责提示与刷新，预翻译负责任务进度。
  - 擦除资格只分组一次，保留空译文和原文保留判断；显示路径也复用原有 `_usableDisplayPath`。视口恢复仍只读缓存，不启动 CTD/LaMa。
- [x] **8. 简化并统一缓存配置来源**
  - 去掉单页缓存键的 JSON 编码后再解码操作。
  - 共享配置快照，让上下文缓存包含 endpoint 和翻译引擎身份；分别维护不同协议的版本。
  - 已新增 `translation_configuration.dart` 配置快照，单页缓存直接使用 Map，移除 JSON 编码/解码往返；上下文复用相同配置并包含 OCR 模型指纹、后端、气泡检测及过滤策略。
  - 单页/上下文提示词版本分别为 7/5。API 与本地模型的单页缓存格式保留；上下文配置扩充后旧键不再命中，Apple 单页模型身份改为稳定的 `apple-on-device`。旧文件保留，不执行缓存删除。
- [x] **9a. 删除气泡引擎未使用的 import**
- [x] **9b. 删除无调用的旧缓存键入口和独占 legacy 分支**
- [x] **9c. 删除无调用的 `parseLocalNumberedTranslations` 包装函数**
- [x] **9d. 删除翻译服务中重复且无引用的 Live Text 通道常量**
- [x] **9e. 简化模型 endpoint 的相同分支及无用参数**

## 保留边界

- 保留真实读取路径使用的 gzip/明文缓存兼容、旧布局升级、OCR 回退及取消代次检查。
- `retryPage` / `retryBatch` / `hydratePage` 当前主要由已有测试调用，另行决定产品接口去留。
- 兼容已有测试，不新增单元测试；需要补充验证时使用验收场景。
- 本次修改叠加在已有未提交修改上，不回退其他修改。

## 自动验证记录

已完成两组互不重复的定向测试，共 **97 项通过**，其中 95 项为已有回归测试，2 项为新增图片导出验收。没有新增单元测试。

第一组（48 项通过，模型下载测试使用 `--timeout 2m`）：

```powershell
flutter test --no-pub --reporter expanded --timeout 2m `
  test/image_translation_config_sheet_test.dart `
  test/gguf_model_store_test.dart `
  test/acceptance/image_translation/translation_overlay_export_test.dart `
  test/connected_bubble_layout_test.dart `
  test/translation_font_size_test.dart `
  test/vertical_translation_layout_test.dart `
  test/image_translation_glyph_metrics_test.dart `
  test/image_translation_reader_state_test.dart `
  test/image_translation_real_page_test.dart
```

第二组（49 项通过）：

```powershell
flutter test --no-pub --reporter expanded `
  test/engine_contract_test.dart `
  test/llama_cpp_runtime_test.dart `
  test/llama_runtime_store_test.dart `
  test/image_translation_setting_test.dart `
  test/image_translation_overlay_geometry_test.dart `
  test/image_translation_colors_test.dart `
  test/image_translation_batch_cancel_test.dart `
  test/image_translation_persistence_test.dart `
  test/context_translation_service_test.dart `
  test/context_batch_reader_flow_test.dart `
  test/bubble_layout_cache_upgrade_test.dart
```

本机通过 Flutter SDK 的 `dart.exe flutter_tools.snapshot test` 执行上述参数，避开入口脚本的初始化等待；测试内容与 `flutter test` 相同。

- 定向 `dart analyze`：退出码 0，无 error / warning，保留 20 个已有格式类 info。文案目录另有已有重复键及命名提示，本轮没有扩展清理这些事项。
- `git diff --check`：通过。
- 首轮发现的设置面板测试固定滚动位置失效、动画无法 settle 已修正；改为按控件标识滚动，更新本地 FFI 界面的断言。
- 上下文测试补齐共用临时日志环境，避免未初始化 `PathService.tempDir` 干扰隔离测试；原有断言保留。
- 两个 40MB 下载测试超过默认 30 秒，使用 2 分钟测试时限后通过，生产下载实现未更改。
- 导出验收产物位于 `.dart_tool/acceptance/translation-overlay/short.png` 和 `grouped.png`。图像已检查；测试字体显示为方块，只验证实际导出、气泡位置和背景像素，真实中文字体和模型推理仍需下面的用户验收。

第 4、5 项另跑 10 个已有测试文件，**81 项全部通过**（与前两组有重叠，不累加）；没有新增测试场景。定向静态检查无 error / warning，仅 18 个已有格式类 info；`git diff --check` 通过。

```powershell
flutter test --no-pub --reporter expanded `
  test/context_translation_engine_test.dart `
  test/image_text_grouping_test.dart `
  test/llama_cpp_runtime_test.dart `
  test/engine_contract_test.dart `
  test/context_translation_service_test.dart `
  test/context_batch_reader_flow_test.dart `
  test/image_translation_persistence_test.dart `
  test/image_translation_batch_cancel_test.dart `
  test/image_translation_config_sheet_test.dart `
  test/image_translation_setting_test.dart
```

这轮相对于第 4、5 项开始前：生产源码净减 **251 行**（包含模块更名和新增公共逻辑），测试净增 **3 行**（已有测试接入共用日志环境），代码合计净减 **248 行**。统计包含空行和注释，不包含文档。

第 7、8 项另跑以下 13 个已有测试文件，**83 项全部通过**（与前面有重叠，不累加）；没有新增或修改测试代码。

```powershell
flutter test --no-pub --reporter expanded `
  test/ctd_inpainting_test.dart `
  test/inpainting_pixels_test.dart `
  test/bubble_mask_pipeline_test.dart `
  test/image_translation_persistence_test.dart `
  test/context_translation_service_test.dart `
  test/context_batch_reader_flow_test.dart `
  test/image_translation_setting_test.dart `
  test/gallery_image_translation_language_test.dart `
  test/image_translation_reader_state_test.dart `
  test/image_translation_batch_cancel_test.dart `
  test/bubble_layout_cache_upgrade_test.dart `
  test/acceptance/image_translation/background_residual_test.dart `
  test/acceptance/image_translation/senpai_background_loss_test.dart
```

定向静态检查无 error / 新增 warning；`base_layout_logic.dart` 保留两个原有未使用私有函数 warning，另有 27 个已有格式类 info。`git diff --check` 通过。本轮生产源码净减 **46 行**（含新公共模块），测试变化 **0 行**；统计包含空行和注释，不包含文档。

## 用户验收（待你实际操作后打勾）

- [ ] **本地模型**：打开桌面端模型设置，确认不再出现 llama-server 下载/管理；下载或使用已有 GGUF 完成一次本地翻译。
- [ ] **短译文导出**：选择有多行原文、译文仅一个字或省略号的气泡，确认阅读器可显示、导出成功且其他气泡译文没有错位。
- [ ] **渲染一致性**：对比竖排、连通气泡及带上下留白的页面在阅读器和导出图中的位置、颜色与背景遮盖。
- [ ] **取消**：在单页/批量翻译接近完成时取消，确认取消状态不会跳回成功；随后重新翻译能够完成。
- [ ] **共用协议**：使用当前可用的 API 和本地 GGUF，分别完成单页与两页上下文翻译，确认每个气泡/页面的译文对应正确，且没有推理文字或 JSON 外壳。
- [ ] **API 基础逻辑**：在设置页和阅读器快捷面板刷新模型列表，确认列表一致；实际取消一次 API 翻译后重试成功。实际供应商调用仍需你验收，已有测试使用模拟 API 响应。
- [ ] **背景修复复用**：启用背景融合，先预翻译再进入阅读器，确认已有修复图直接恢复；强制重译确认仍会修复，未译/保留原文的气泡不被擦除，缺少模型时仍有回退提示。
- [ ] **缓存配置隔离**：完成两页上下文翻译后，在保持模型名称不变时切换 API endpoint，重启应用再运行同一组页面，确认不会读取原 endpoint 的上下文译文；再切换翻译引擎或 OCR/气泡检测配置检查缓存隔离。配置不变时重启应继续命中缓存。
