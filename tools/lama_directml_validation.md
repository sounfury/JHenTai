# LaMa DirectML 验证记录

2026-09-26，本机 RTX 3060 Laptop、驱动 32.0.16.1074、ONNX Runtime DirectML 1.23.0。

原始模型是 `LamaModelEvidence` 固定的 LaMa Large 导出。默认配置会在运行时失败；降低图优化、固定输入形状或关闭 metacommands 均没有修复。降低优化后可定位到 Fourier 分支的五维 MatMul。

兼容转换将 144 处 `A @ Unsqueeze(B, -1)` 等价替换为 `Unsqueeze(B @ Transpose(A), -1)`，保留原始权重、输入输出和动态尺寸。转换仅接受固定 SHA-256 的原模型，并校验生成文件的固定 SHA-256。原模型不被覆盖。应用用 Dart 自动生成兼容文件，不依赖 Python。

实测：

| 输入（宽×高） | 热运行耗时 | 与原始 CPU 输出最大绝对误差 |
| --- | --- | --- |
| 512×512 | 0.225 秒；开启 profiling 时 0.374 秒 | 0.0000369 |
| 768×1024 | 0.537 秒 | 0.0000878 |

耗时仅包含原生推理，使用固定随机种子的 RGB 和局部二值蒙版，不包含图片处理或 session 创建。首次运行约 1.6–2.1 秒。ONNX checker 通过；profiling 确认 DirectML 节点实际执行，形状等部分节点仍在 CPU。没有实测阅读器滚动帧率。

复现（Python 仅用于开发验证，在隔离环境安装 `onnxruntime-directml==1.23.0`、`numpy`，模型结构检查另需 `onnx`）：

```powershell
dart run tools/prepare_lama_directml.dart <原模型路径>
python tools/probe_lama_directml.py <原模型路径>.dml-rank4-v1.onnx --mode default --compare <原模型路径> --profile
python tools/probe_lama_directml.py <原模型路径>.dml-rank4-v1.onnx --mode default --size 1024 --width 768 --compare <原模型路径>
```

正常启动只在后台流式校验兼容文件；仅首次生成或兼容文件损坏时读取、校验原模型并转换。GPU 创建或运行失败会关闭失败 session，重试原模型 CPU，并在当前引擎实例内避开同一失败配置。

翻页相关改动覆盖 CTD/气泡/LaMa 的后台像素处理、Windows 张量复制及 session 释放、修复缓存的后台哈希、相同显示模式的重复通知，以及旧气泡布局升级写回。成功分析但无可用区域也保存版本标记，避免再次解码。
