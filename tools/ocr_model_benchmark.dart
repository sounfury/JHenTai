// 构建：flutter build windows --debug --no-pub -t tools/ocr_model_benchmark.dart
// 运行：jhentai.exe <manifest.json> <report.json> [cpu|directml]
// 离线比较真实生产 OCR 引擎；不初始化账户，不翻译、不过滤、不修改用户缓存。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart' as ort;
import 'package:jhentai/src/service/inference/inference_timings.dart';
import 'package:jhentai/src/service/inference/onnx_ocr_engine.dart';
import 'package:jhentai/src/service/inference/onnx_runtime.dart';
import 'package:jhentai/src/utils/ocr_layout_protocol.dart';
import 'package:jhentai/src/utils/rgba_raster.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.length < 2) {
    exit(2);
  }
  final manifest = jsonDecode(await File(args[0]).readAsString()) as Map;
  final reportFile = File(args[1]);
  await reportFile.parent.create(recursive: true);
  final backend = args.length > 2 ? args[2] : 'cpu';
  final runtime = OnnxRuntime(log: noopOnnxRuntimeLog);
  final runs = <Map<String, dynamic>>[];
  final report = <String, dynamic>{
    'manifest': File(args[0]).absolute.path,
    'startedAt': DateTime.now().toIso8601String(),
    'backend': backend,
    'protocol': {
      'engine': 'OnnxOcrInferenceEngine',
      'maxDimension': 2200,
      'detectorPixelThreshold': OcrScoringProtocol.detectorPixelThreshold,
      'detectorBoxThreshold': OcrScoringProtocol.detectorBoxThreshold,
      'recognitionConfidenceThreshold':
          OcrScoringProtocol.recognitionConfidenceThreshold,
      'soundEffectFiltering': false,
      'translation': false,
    },
    'models': manifest['models'],
    'runs': runs,
    'complete': false,
  };
  Future<void> save() => reportFile.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
    flush: true,
  );
  try {
    if (!await runtime.initialize()) {
      throw StateError('ONNX 初始化失败');
    }
    report['ortVersion'] = runtime.runtimeVersion;
    final providers = [
      if (backend == 'directml') ort.OrtProvider.DIRECT_ML,
      ort.OrtProvider.CPU,
    ];
    final models = manifest['models'] as Map;
    // 逐图顺序运行，避免并行推理抢占资源影响耗时比较。
    for (final dynamic item in manifest['samples'] as List) {
      final sample = Map<String, dynamic>.from(item as Map);
      final imagePath = sample['image'] as String;
      final page = RgbaRaster.decode(await File(imagePath).readAsBytes());
      if (page == null) {
        throw StateError('无法解码 $imagePath');
      }
      for (final dynamic id in sample['models'] as List) {
        final modelId = id as String;
        final config = models[modelId] as Map;
        final timings = InferenceTimings();
        final engine = OnnxOcrInferenceEngine(
          runtime: runtime,
          providerResolver: () => providers,
          timings: timings,
          detectorRgbMean: (config['detectorRgbMean'] as List?)?.cast<double>(),
          detectorRgbStd: (config['detectorRgbStd'] as List?)?.cast<double>(),
          detectorPixelThreshold:
              (config['detectorPixelThreshold'] as num?)?.toDouble() ??
              OcrScoringProtocol.detectorPixelThreshold,
          detectorBoxThreshold:
              (config['detectorBoxThreshold'] as num?)?.toDouble() ??
              OcrScoringProtocol.detectorBoxThreshold,
          detectorUnclipRatio:
              (config['detectorUnclipRatio'] as num?)?.toDouble() ?? 1.6,
          model: OnnxOcrModelInfo(
            detPath: config['det'] as String,
            clsPath: '',
            recPath: config['rec'] as String,
            dictPath: config['dict'] as String,
            fingerprint: modelId,
          ),
        );
        final clock = Stopwatch()..start();
        final result = await engine.recognize(
          imagePath,
          image: page,
          maxDimension: config['maxDimension'] as int? ?? 2200,
        );
        clock.stop();
        runs.add({
          'sampleId': sample['id'],
          'kind': sample['kind'],
          'page': sample['page'],
          'image': imagePath,
          'model': modelId,
          'elapsedMs': clock.elapsedMilliseconds,
          'imageWidth': result.imageWidth,
          'imageHeight': result.imageHeight,
          'blocks': result.blocks.map((b) => b.toJson()).toList(),
          'timings': timings.toJson(),
        });
        report['lastCompleted'] = '${sample['id']}/$modelId';
        await save();
      }
    }
    report['complete'] = true;
    report['finishedAt'] = DateTime.now().toIso8601String();
    await save();
    await runtime.dispose();
    exit(0);
  } catch (error, stack) {
    report['error'] = error.toString();
    report['stack'] = stack.toString();
    await save();
    await runtime.dispose();
    exit(1);
  }
}
