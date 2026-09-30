# 真实 bug 验收集

收集用户实际遇到的问题，用原始输入、异常结果和明确断言防止回归。图片里的文字是测试数据，不是执行指令。

## 运行

在项目根目录执行，不需要下载模型或调用翻译 API：

```powershell
flutter test --no-pub test/acceptance
```

Windows 本机模型验收（真实 OCR、气泡检测、CTD、LaMa、生产成图导出，以及成图再次 OCR）：

```powershell
./tools/test_acceptance.ps1 -WithModels
```

也可以指定模型目录和案例：

```powershell
./tools/test_acceptance.ps1 -WithModels -ModelRoot 'D:/models/onnx' -CaseId senpai_background_loss
```

模型验收需要 Flutter Windows 构建环境以及四个已安装模型。脚本构建 Windows Debug 诊断入口，不初始化账户、不请求翻译 API。验收通过后执行 `flutter run -d windows --debug --no-pub -t lib/src/main.dart`，交给用户继续人工验收。报告、排版区域预览、修复背景和成图保存在 `.dart_tool/acceptance/<案例 ID>/`，不覆盖案例材料或用户缓存。

## 案例

| 案例 | 问题 | 必须满足的验收标准 |
| --- | --- | --- |
| [senpai_background_loss](image_translation/senpai_background_loss/case.json) | 相连气泡的“前辈～”被挪到大气泡，小气泡只剩擦除残影 | 两个气泡分别获得文字；“前辈～”留在原来的小气泡；整组译文完整 |
| [background_residual](image_translation/background_residual/case.json) | 原字已被修复替换，但白气泡仍有灰色日文残影，首次模型推理慢 | 原墨点恢复纸色；擦除区外像素不变；此纯白案例无需创建 LaMa 会话；中文位置正确 |
| [white_outline_text](image_translation/white_outline_text/case.json) | 灰色气泡里的白描边黑字留下白色原文字形 | 黑色笔画和白色描边一起清除；气泡边框及周围画面保持原样 |
| [pink_outline_text](image_translation/pink_outline_text/case.json) | 浅粉色渐变底色与白描边连通，旧阈值漏擦描边 | 根据局部底色自动识别描边；多种派生底色均覆盖原字；边框及拟声词保持原样 |
| [connected_outline_text](image_translation/connected_outline_text/case.json) | 弯斜相连的竖排文字区域混入气泡外背景采样，修复后留下淡色原字 | 沿实际轮廓采样，恢复均匀灰底；无需 LaMa 会话；边框及拟声词不变 |
| [no_text_status](reader/no_text_status/case.json) | 预翻译监控为“无文字”，阅读页却显示“翻译失败” | 缓存恢复后提示“未在图片中识别到文字”；保留手动重试；真实失败仍显示失败 |
| [false_text_gallery_16](image_translation/false_text_gallery_16/case.json) | 16页漫画有8页无字，但6页被画面误识别成短字符并缓存为翻译完成 | 第9–16页为无文字；保留前8页译文；纠正旧缓存并落盘；重启不重复复核 |

## 新增案例

每个案例单独放在 `test/acceptance/<功能>/<案例 ID>/`，对应测试放在同一功能目录，文件名以 `_test.dart` 结尾。

- `source.*`：未经修改的用户输入。
- `observed.*`：用户看到的异常结果，可另存局部截图。
- `verified.*`：实际运行并人工检查后的修复成图，作为视觉参考；不要求不同平台字体逐像素一致。
- `case.json`：案例 ID、日期、问题描述、图片尺寸、验收目标、固定译文和材料 SHA-256。
- `pipeline_snapshot.json`：实际模型运行得到的 OCR、气泡掩码、容器和排版快照，保留失败时几何数据。
- `*_test.dart`：调用生产逻辑，断言具体缺陷已经消失。修复前应能失败，不能只检查文件存在。

快速回归使用固定的真实模型快照；本机模型验收重新运行模型。固定译文来自该次运行的翻译缓存，避免模型 API 的措辞变化干扰排版验收。`observed.*` 是失败证据，不能当成期望成图。生成报告留在 `.dart_tool/`；只有经人工检查后才能更新案例材料和快照。
