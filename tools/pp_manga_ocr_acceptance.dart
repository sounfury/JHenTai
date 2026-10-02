// 构建：flutter build windows --debug --no-pub -t tools/pp_manga_ocr_acceptance.dart
// 运行：jhentai.exe <模型根目录> <案例清单.json> <报告.json>
// 验收真实工作 isolate 的参数传递和推理，不调用翻译接口或修改用户缓存。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_onnxruntime/flutter_onnxruntime.dart' as ort;
import 'package:jhentai/src/service/inference/inference_safety.dart';
import 'package:jhentai/src/service/inference/inference_task.dart';
import 'package:jhentai/src/service/inference/onnx_model_store.dart';
import 'package:jhentai/src/service/inference/onnx_ocr_engine.dart';
import 'package:jhentai/src/service/inference/onnx_ocr_worker.dart';
import 'package:jhentai/src/service/inference/onnx_runtime.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (args.length < 3) {
    exit(2);
  }
  final reportFile = File(args[2]);
  await reportFile.parent.create(recursive: true);
  final report = <String, dynamic>{'passed': false, 'runs': <Map>[]};
  final runtime = OnnxRuntime(log: noopOnnxRuntimeLog);
  OnnxOcrWorker? worker;
  try {
    if (!await runtime.initialize()) {
      throw StateError('ONNX 初始化失败');
    }
    final manifest = OnnxModelStore.manifests.singleWhere(
      (m) => m.id == OnnxModelStore.ocrManifestId,
    );
    final modelRoot = '${args[0]}/${manifest.id}';
    String modelFile(String id) =>
        '$modelRoot/${manifest.files.singleWhere((f) => f.id == id).fileName}';
    final model = OnnxOcrModelInfo(
      detPath: modelFile('det'),
      clsPath: '',
      recPath: modelFile('rec'),
      dictPath: modelFile('dict'),
      fingerprint: manifest.fingerprint,
      detectorNormalization: OnnxOcrDetectorNormalization.imageNet,
    );
    final cases = jsonDecode(await File(args[1]).readAsString()) as List;
    worker = await OnnxOcrWorker.spawn();
    report['model'] = manifest.fingerprint;
    final backends = [
      'cpu',
      if (runtime.availableProviders.contains(ort.OrtProvider.DIRECT_ML))
        'directml',
    ];
    for (final backend in backends) {
      for (final item in cases) {
        final sample = item as Map;
        final providers = [
          if (backend == 'directml') ort.OrtProvider.DIRECT_ML,
          ort.OrtProvider.CPU,
        ];
        final safety = InferenceProviderPolicy.sessionConfig(
          backend: backend,
          maxInputPixels: 4 * 1024 * 1024,
          memoryBudgetBytes: 128 * 1024 * 1024,
        );
        final token = InferenceCancellationToken();
        var actualBackend = backend;
        final result = await runOnnxOcrWithCpuFallback(
          primaryProviders: providers,
          primarySafetyConfig: safety,
          cancellationToken: token,
          modelHash: manifest.fingerprint,
          resetAcceleratedSessions: worker.closeSessions,
          attempt: ({required providers, required safetyConfig}) {
            actualBackend = providers.first.name;
            return worker!.recognize(
              model: model,
              providers: providers,
              imagePath: sample['image'] as String,
              cancellationToken: token,
              safetyConfig: safetyConfig,
            );
          },
        );
        final box = (sample['box'] as List).cast<num>();
        final matching =
            result.blocks.where((b) {
              final cx = b.left + b.width / 2;
              final cy = b.top + b.height / 2;
              return cx >= box[0] &&
                  cy >= box[1] &&
                  cx <= box[2] &&
                  cy <= box[3];
            }).toList();
        final passed = matching.any((b) => b.text == sample['expected']);
        (report['runs'] as List).add({
          'id': sample['id'],
          'requestedBackend': backend,
          'actualBackend': actualBackend,
          'expected': sample['expected'],
          'actual': matching.map((b) => b.toJson()).toList(),
          'passed': passed,
        });
        await reportFile.writeAsString(jsonEncode(report), flush: true);
        if (!passed) {
          throw StateError('字块识别不符合预期：${sample['id']} / $backend');
        }
      }
    }
    report['passed'] = true;
    await reportFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(report),
      flush: true,
    );
    await worker.dispose();
    await runtime.dispose();
    exit(0);
  } catch (error, stack) {
    report['error'] = error.toString();
    report['stack'] = stack.toString();
    await reportFile.writeAsString(jsonEncode(report), flush: true);
    await worker?.dispose();
    await runtime.dispose();
    exit(1);
  }
}
