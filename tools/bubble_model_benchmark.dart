// 离线对照现有气泡分割、RT-DETR 原版和量化版，不改用户设置或翻译缓存。
// 运行：jhentai.exe <manifest.json> <report.json> [cpu|directml]
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart' as ort;
import 'package:jhentai/src/service/inference/bubble_segmentation_inference_engine.dart';
import 'package:jhentai/src/service/inference/inference_task.dart';
import 'package:jhentai/src/service/inference/onnx_runtime.dart';
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
    'backend': backend,
    'models': manifest['models'],
    'runs': runs,
    'complete': false,
    'protocol': {
      'baselineThreshold': .5,
      'rtdetrThreshold': .3,
      'rtdetrResize': 'RGB /255, 拉伸到640×640，线性插值',
      'origTargetSizes': '[width, height]，参照上游ONNX调用',
      'threads': 2,
      'sessionCreationIncludedInTiming': false,
      'translation': false,
    },
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
    if (backend == 'directml' &&
        !runtime.availableProviders.contains(ort.OrtProvider.DIRECT_ML)) {
      throw StateError('DirectML 不可用');
    }
    final providers = [
      if (backend == 'directml') ort.OrtProvider.DIRECT_ML,
      ort.OrtProvider.CPU,
    ];
    final models = manifest['models'] as Map;
    // 每次只保留一个模型会话，避免不同模型抢占内存影响测量。
    for (final modelEntry in models.entries) {
      final id = modelEntry.key as String;
      final config = modelEntry.value as Map;
      final ort.OrtSession? session;
      final BubbleSegmentationInferenceEngine? baseline;
      if (config['type'] == 'baseline') {
        baseline = BubbleSegmentationInferenceEngine(
          runtime: runtime,
          providerResolver: () => providers,
          modelResolver:
              () => BubbleSegmentationModelInfo(
                modelPath: config['path'] as String,
                fingerprint: config['sha256'] as String,
              ),
        );
        session = null;
      } else {
        baseline = null;
        session = await runtime.session(
          config['path'] as String,
          modelFingerprint: config['sha256'] as String,
          providers: providers,
          intraOpNumThreads: 2,
          interOpNumThreads: 1,
        );
        if (session == null) {
          throw StateError(
            runtime.sessionErrorFor([config['path'] as String]) ?? '会话创建失败',
          );
        }
        report['${id}Inputs'] = session.inputNames;
        report['${id}Outputs'] = session.outputNames;
      }
      for (final item in manifest['samples'] as List) {
        final sample = item as Map;
        final path = sample['image'] as String;
        final page = RgbaRaster.decode(await File(path).readAsBytes());
        if (page == null) {
          throw StateError('图片无法解码：$path');
        }
        final repeats = sample['repeats'] as int? ?? 1;
        // 每张图先预热一次，不把首次会话初始化计入稳态耗时。
        for (int iteration = -1; iteration < repeats; iteration++) {
          final watch = Stopwatch()..start();
          final List<Map<String, dynamic>> detections;
          if (baseline != null) {
            final result = await baseline.detect(
              path,
              image: page,
              cancellationToken: InferenceCancellationToken(),
            );
            detections =
                result.regions
                    .map(
                      (r) => <String, dynamic>{
                        'label': 0,
                        'score': r.confidence,
                        'box': [
                          r.left,
                          r.top,
                          r.left + r.width,
                          r.top + r.height,
                        ],
                        'hasMask': r.bubbleInterior != null,
                      },
                    )
                    .toList();
          } else {
            detections = await _detect(runtime, session!, page);
          }
          watch.stop();
          if (iteration < 0) {
            continue;
          }
          runs.add({
            'sampleId': sample['id'],
            'image': path,
            'model': id,
            'iteration': iteration,
            'elapsedMs': watch.elapsedMicroseconds / 1000,
            'imageWidth': page.width,
            'imageHeight': page.height,
            'detections': detections,
          });
          report['lastCompleted'] = '${sample['id']}/$id/$iteration';
          await save();
        }
      }
      await runtime.closeSessions();
    }
    report['complete'] = true;
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

Future<List<Map<String, dynamic>>> _detect(
  OnnxRuntime runtime,
  ort.OrtSession session,
  RgbaRaster page,
) async {
  const size = 640;
  final data = Float32List(3 * size * size);
  page.writeResizedNchw(
    data,
    targetWidth: size,
    targetHeight: size,
    rowStride: size,
    planeSize: size * size,
  );
  final image = await ort.OrtValue.fromList(data, [1, 3, size, size]);
  final sizes = await ort.OrtValue.fromList(
    Int64List.fromList([page.width, page.height]),
    [1, 2],
  );
  Map<String, ort.OrtValue>? outputs;
  try {
    outputs = await runtime.run(session, {
      'images': image,
      'orig_target_sizes': sizes,
    });
    final labels = await outputs['labels']!.asFlattenedList();
    final boxes = await outputs['boxes']!.asFlattenedList();
    final scores = await outputs['scores']!.asFlattenedList();
    if (labels.length != scores.length || boxes.length != labels.length * 4) {
      throw StateError('RT-DETR 输出维度不匹配');
    }
    // 保存低分候选用于复核阈值；报告分析时才应用0.3门槛。
    return [
      for (int i = 0; i < labels.length; i++)
        if ((scores[i] as num).isFinite && (scores[i] as num) >= .05)
          {
            'label': (labels[i] as num).toInt(),
            'score': (scores[i] as num).toDouble(),
            'box': boxes.sublist(i * 4, i * 4 + 4).cast<num>(),
            'hasMask': false,
          },
    ];
  } finally {
    for (final output in outputs?.values ?? <ort.OrtValue>[]) {
      await output.dispose();
    }
    await image.dispose();
    await sizes.dispose();
  }
}
