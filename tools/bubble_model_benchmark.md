# 气泡模型离线对照

`bubble_model_benchmark.dart` 使用应用内的 ONNX Runtime 比较当前 Manga109
分割模型与 RT-DETR 原版、INT8 版。只输出检测结果，不初始化账户、调用翻译或修改用户缓存。

运行参数：`jhentai.exe <manifest.json> <report.json> [cpu|directml]`。
清单包含以下结构，路径替换为本机绝对路径：

```json
{
  "models": {
    "baseline": {"type": "baseline", "path": "D:/models/best.onnx", "sha256": "已校验的文件哈希"},
    "rtdetr_fp32": {"type": "rtdetr", "path": "D:/models/detector.onnx", "sha256": "已校验的文件哈希"},
    "rtdetr_int8": {"type": "rtdetr", "path": "D:/models/detector_int8.onnx", "sha256": "已校验的文件哈希"}
  },
  "samples": [
    {"id": "page-1", "image": "D:/inputs/page-1.png", "repeats": 3}
  ]
}
```

## 保持主应用运行的独立构建

先将已构建的 `build/windows/x64/runner/Debug/` 整个目录复制到独立诊断目录
`<runner>`，保留所有原生运行库，再只构建该目录内的 Dart 资源包：

```powershell
flutter build bundle --debug --no-pub --target-platform windows-x64 `
  --asset-dir <runner>/data/flutter_assets --depfile <runner>/bundle.d `
  -t tools/bubble_model_benchmark.dart
<runner>/jhentai.exe <manifest.json> <report.json> cpu
```

## 比较口径

- 当前分割模型调用生产引擎，置信度门槛为 0.5，输出框与内部掩码。
- RT-DETR 输入为 RGB /255，线性拉伸到 640×640，`orig_target_sizes` 为
  `[width, height]`，参照上游 ONNX 调用。它只输出检测框，不能直接替代内部掩码。
- RT-DETR 标签为 `0: bubble`、`1: text_bubble`、`2: text_free`。
  保留分数至少 0.05 的原始候选供复核，比较时使用 0.3 门槛。
- 两个 RT-DETR 版本的预处理及门槛相同，不能直接比较不同模型的置信度数值。
- 每张图先预热一次；耗时不含图片解码与会话创建，包含预处理、推理和结果解析。
  每次只保留一个模型会话，CPU 线程数为 2。
- `complete: true` 且无 `error` 只代表程序完成。更多框不代表更准确，需对照原图
  人工检查漏检、误检、重复框和定位误差。探针点覆盖不等于掩码质量或完整召回率。

2026-10-02 的输入、权重版本和文件 SHA-256、原始输出、可视化放在
`.dart_tool/acceptance/bubble-model-benchmark/`。
RT-DETR 固定版本为 `16e8a622f91fabc6b5b65c96d32d1183f8843546`，来源为
[ogkalu/comic-text-and-bubble-detector](https://huggingface.co/ogkalu/comic-text-and-bubble-detector)。
