# 离线 OCR 模型比较

`ocr_model_benchmark.dart` 调用应用的真实 OCR 推理引擎，以相同输入比较模型组合。
不初始化账户服务，不调用翻译接口，不执行拟声词过滤或擦除，不写用户翻译缓存。

构建和运行：

```powershell
flutter build windows --debug --no-pub -t tools/ocr_model_benchmark.dart
./build/windows/x64/runner/Debug/jhentai.exe <manifest.json> <report.json> cpu
```

清单示例（所有路径应替换为本机绝对路径）：

```json
{
  "models": {
    "baseline": {
      "det": "D:/models/PP-OCRv6_det_small.onnx",
      "rec": "D:/models/PP-OCRv6_rec_small.onnx",
      "dict": "D:/models/ppocrv6_dict.txt"
    },
    "manga": {
      "det": "D:/models/manga_det_v0.2.onnx",
      "rec": "D:/models/manga_rec_v0.2.onnx",
      "dict": "D:/models/ppocrv6_dict.txt",
      "detectorRgbMean": [0.485, 0.456, 0.406],
      "detectorRgbStd": [0.229, 0.224, 0.225]
    }
  },
  "samples": [
    {
      "id": "page-15",
      "kind": "page",
      "page": 15,
      "image": "D:/inputs/page-15.webp",
      "models": ["baseline", "manga"]
    }
  ]
}
```

清单中的检测器 RGB 均值与标准差必须同时提供。省略时维持当前应用的 `[-1, 1]` 输入。
可选 `detectorPixelThreshold`、`detectorBoxThreshold`、`detectorUnclipRatio`、`maxDimension`；
省略时分别为 `0.3`、`0.5`、`1.6`、`2200`。每个模型的实际配置保存在报告的 `models` 字段。
改变阈值、输入尺寸或归一化时，必须在比较说明里明确记录，不能把结果变化全部归因于权重。

报告逐次保存原始文字、坐标、置信度和分阶段耗时，只有 `complete: true` 且没有 `error`
才代表全部推理执行完成。字块数、与旧 OCR 文本的一致率均不代表识别准确率；
需要用户对照原图确认真值后才能计算 CER。单次 Debug 耗时只供本机观察。

2026-10-02 的 PP 漫画版评估材料在 `.dart_tool/acceptance/pp-manga-benchmark/`：
`manifest.json` 记录模型版本、文件 SHA-256 和输入清单；`report.json` 保存 83 次推理；
`report.md`、`review.html` 和 `comparison.png` 用于人工复核。
当时可用原图为 23 页，第 9 页缓存缺失。模型源为
[Kellenok/PP-OCRv6_manga](https://huggingface.co/Kellenok/PP-OCRv6_manga)，
固定版本 `ba1d479e8a61a20e8318c9758c73fbbbd290b98d`，模型输入参数参照该版本示例。

## 漫画版接入验收

`pp_manga_ocr_acceptance.dart` 通过生产 OCR 工作 isolate 验证漫画版参数传递，
依次执行 CPU 和可用的 DirectML，并记录实际使用的后端及原始识别结果。

```powershell
flutter build windows --debug --no-pub -t tools/pp_manga_ocr_acceptance.dart
./build/windows/x64/runner/Debug/jhentai.exe <模型根目录> <案例清单.json> <报告.json>
```

模型根目录下应有已安装的 `ppocrv6-manga-v0.2` 子目录。案例清单为 JSON 数组，
每项包含 `id`、`image` 绝对路径、`box: [left, top, right, bottom]` 和 `expected` 原文。
验收检查目标区域是否有文字完全一致的字块；报告 `passed: true` 表示所有案例通过。
本轮案例和报告在 `.dart_tool/acceptance/pp-manga-integration/`。

完成工具验收后，必须重新构建主入口 `lib/src/main.dart`，再由用户验收整页翻译：
检查第 15、17、18 页的旧错误、正常对白、气泡内外拟声词的保留行为。
模型变化会产生新的缓存指纹。小气泡漏检和是否翻译气泡内拟声词仍需独立处理。
