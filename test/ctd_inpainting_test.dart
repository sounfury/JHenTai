import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/engine/engine.dart';
import 'package:jhentai/src/service/image_inpainting_service.dart';
import 'package:jhentai/src/service/inference/ctd_model_evidence.dart';
import 'package:jhentai/src/service/inference/ctd_onnx_inference_engine.dart';
import 'package:jhentai/src/service/inference/lama_model_evidence.dart';
import 'package:jhentai/src/service/inference/onnx_model_store.dart';

class _FakeInpaintEngine implements InpaintEngine {
  _FakeInpaintEngine({this.failure});

  final String? failure;
  int calls = 0;

  @override
  final EngineDescriptor descriptor = const EngineDescriptor(
    id: 'onnx-lama-inpaint',
    kind: EngineKind.inpaint,
    displayName: 'fake inpaint',
    platforms: <EnginePlatform>{EnginePlatform.macos},
  );

  @override
  bool get isReady => true;

  @override
  EngineTask<String> inpaint(ImageProcessingRequest request) =>
      EngineTask<String>.start(
        operation: (EngineTaskContext context) async {
          calls++;
          if (failure != null) {
            throw EngineException(
              code: failure!,
              message: 'fake failure',
              engineId: descriptor.id,
            );
          }
          context.cancellation.throwIfCancelled();
          await request.outputPathFile.parent.create(recursive: true);
          await request.outputPathFile.writeAsBytes(<int>[
            1,
            2,
            3,
          ], flush: true);
          return request.outputPath;
        },
      );
}

class _FakeDetectionEngine implements DetectionEngine {
  _FakeDetectionEngine({this.masks = const <PolygonMask>[]});

  final List<PolygonMask> masks;
  int calls = 0;

  @override
  final EngineDescriptor descriptor = const EngineDescriptor(
    id: 'ctd-detection',
    kind: EngineKind.detection,
    displayName: 'fake CTD',
    platforms: <EnginePlatform>{EnginePlatform.macos},
  );

  @override
  bool get isReady => true;

  @override
  EngineTask<DetectionResult> detect(EngineImageRequest request) =>
      EngineTask<DetectionResult>.start(
        operation: (EngineTaskContext context) async {
          calls++;
          context.cancellation.throwIfCancelled();
          return DetectionResult(regions: const [], polygonMasks: masks);
        },
      );
}

extension on ImageProcessingRequest {
  File get outputPathFile => File(outputPath);
}

PolygonMask _squareMask() => const PolygonMask(
  points: <EnginePoint>[
    EnginePoint(x: 1, y: 1),
    EnginePoint(x: 5, y: 1),
    EnginePoint(x: 5, y: 5),
    EnginePoint(x: 1, y: 5),
  ],
  confidence: 0.95,
);


RecognizedTextBlock _blockOverSquareMask() => const RecognizedTextBlock(
  text: 'hello',
  confidence: 1,
  left: 1,
  top: 1,
  width: 4,
  height: 4,
);

RecognizedTextBlock _blockFarAway() => const RecognizedTextBlock(
  text: 'elsewhere',
  confidence: 1,
  left: 200,
  top: 200,
  width: 20,
  height: 10,
);

void main() {
  test(
    'CTD adapter preserves polygon masks and projects compatibility boxes',
    () async {
      final CtdDetectionEngineAdapter adapter = CtdDetectionEngineAdapter(
        runner: (
          String path,
          EngineCancellationToken token,
          void Function(double) onProgress,
        ) async {
          token.throwIfCancelled();
          onProgress(1);
          return CtdDetectionOutput(polygonMasks: <PolygonMask>[_squareMask()]);
        },
      );

      final DetectionResult result =
          await adapter
              .detect(const EngineImageRequest(imagePath: 'page.png'))
              .future;

      expect(adapter.isReady, isTrue);
      expect(result.polygonMasks.single.points, hasLength(4));
      expect(result.regions.single.left, 1);
      expect(result.regions.single.top, 1);
      expect(result.regions.single.width, 4);
      expect(result.regions.single.height, 4);
    },
  );

  test(
    'an adapter without a CTD runtime remains explicitly unavailable',
    () async {
      final CtdDetectionEngineAdapter adapter = CtdDetectionEngineAdapter();
      expect(adapter.isReady, isFalse);
      await expectLater(
        adapter.detect(const EngineImageRequest(imagePath: 'page.png')).future,
        throwsA(
          isA<EngineException>().having(
            (EngineException error) => error.code,
            'code',
            'model_unavailable',
          ),
        ),
      );
      expect(CtdModelEvidence.modelArtifactPinned, isTrue);
      expect(CtdModelEvidence.nativeRuntimeVerified, isTrue);
    },
  );

  test('CTD segmentation becomes source-coordinate polygons, not boxes', () {
    final Float32List probabilities = Float32List(8 * 8);
    for (int y = 2; y <= 4; y++) {
      for (int x = 1; x <= 3; x++) {
        probabilities[y * 8 + x] = 0.9;
      }
    }
    // This active pixel is in the padded area and must be ignored.
    probabilities[7 * 8 + 7] = 1;

    final List<PolygonMask> masks = ctdPolygonsFromSegmentation(
      probabilities: probabilities,
      mapWidth: 8,
      mapHeight: 8,
      activeWidth: 6,
      activeHeight: 6,
      sourceWidth: 60,
      sourceHeight: 120,
      dilationRadius: 0,
      minimumPixels: 4,
    );

    expect(masks, hasLength(1));
    expect(masks.single.isValid, isTrue);
    expect(masks.single.points.length, greaterThanOrEqualTo(4));
    expect(masks.single.left, closeTo(10, 0.01));
    expect(masks.single.top, closeTo(40, 0.01));
    expect(masks.single.right, closeTo(40, 0.01));
    expect(masks.single.bottom, closeTo(100, 0.01));
  });

  test(
    'inpainting cache is independent and keeps the source hash unchanged',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'jhentai-ctd-inpainting-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final File source = File('${root.path}/source.bin');
      await source.writeAsBytes(<int>[7, 8, 9, 10], flush: true);
      final Directory cache = Directory('${root.path}/cache');
      final _FakeInpaintEngine fake = _FakeInpaintEngine();
      final EngineRegistry registry = EngineRegistry(inpaintEngine: fake);
      final ImageInpaintingService service = ImageInpaintingService(
        registry: registry,
      )..setCacheDirectoryForTesting(cache);

      final String originalHash = await source.sha256ForTest();
      final InpaintingResult first = await service.repair(
        requestKey: 'page-1',
        sourcePath: source.path,
        polygonMasks: <PolygonMask>[_squareMask()],
      );
      expect(first.status, InpaintingStatus.success);
      expect(first.outputPath, isNot(source.path));
      expect(await source.sha256ForTest(), originalHash);
      expect(await File(first.outputPath!).exists(), isTrue);

      final ImageInpaintingService restarted = ImageInpaintingService(
        registry: registry,
      )..setCacheDirectoryForTesting(cache);
      final InpaintingResult cached = await restarted.repair(
        requestKey: 'page-1',
        sourcePath: source.path,
        polygonMasks: <PolygonMask>[_squareMask()],
      );
      expect(cached.status, InpaintingStatus.success);
      expect(cached.fromCache, isTrue);
      expect(fake.calls, 1);

      restarted.setDisplayMode(
        ImageProcessingDisplayMode.repairedBackgroundEmbeddedText,
      );
      expect(restarted.displayPathFor('page-1'), cached.outputPath);
      restarted.setDisplayMode(ImageProcessingDisplayMode.translatedImage);
      expect(restarted.shouldDrawTranslationOverlay('page-1'), isTrue);
      final File translated = File('${root.path}/translated.png')
        ..writeAsBytesSync(<int>[4, 5, 6]);
      restarted.publishTranslatedImage('page-1', translated.path);
      expect(restarted.displayPathFor('page-1'), translated.path);
      expect(restarted.shouldDrawTranslationOverlay('page-1'), isFalse);

      await restarted.clearCache(requestKey: 'page-1');
      expect(await File(cached.outputPath!).exists(), isFalse);
      expect(await source.exists(), isTrue);
      expect(await source.sha256ForTest(), originalHash);
    },
  );

  test('production pipeline passes CTD polygons to LaMa Large', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'jhentai-ctd-migan-pipeline-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File source = File('${root.path}/source.bin')
      ..writeAsBytesSync(<int>[9, 8, 7]);
    final _FakeDetectionEngine detector = _FakeDetectionEngine(
      masks: <PolygonMask>[_squareMask()],
    );
    final _FakeInpaintEngine inpainter = _FakeInpaintEngine();
    final ImageInpaintingService service = ImageInpaintingService(
      registry: EngineRegistry(
        detectionEngine: detector,
        inpaintEngine: inpainter,
      ),
    )..setCacheDirectoryForTesting(Directory('${root.path}/cache'));

    final InpaintingResult result = await service.detectAndRepair(
      requestKey: 'page-1',
      sourcePath: source.path,
      eraseOnlyBlocks: <RecognizedTextBlock>[_blockOverSquareMask()],
    );

    expect(result.status, InpaintingStatus.success);
    expect(detector.calls, 1);
    expect(inpainter.calls, 1);
    expect(result.outputPath, isNot(source.path));
    expect(await source.readAsBytes(), <int>[9, 8, 7]);
  });

  test('CTD with no text falls back without invoking LaMa Large', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'jhentai-ctd-no-text-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File source = File('${root.path}/source.bin')
      ..writeAsBytesSync(<int>[1]);
    final _FakeInpaintEngine inpainter = _FakeInpaintEngine();
    final ImageInpaintingService service = ImageInpaintingService(
      registry: EngineRegistry(
        detectionEngine: _FakeDetectionEngine(),
        inpaintEngine: inpainter,
      ),
    );

    final InpaintingResult result = await service.detectAndRepair(
      requestKey: 'page-1',
      sourcePath: source.path,
      eraseOnlyBlocks: <RecognizedTextBlock>[_blockOverSquareMask()],
    );

    expect(result.status, InpaintingStatus.failed);
    expect(result.errorCode, 'ctd_no_text');
    expect(result.fallbackToOverlay, isTrue);
    expect(inpainter.calls, 0);
  });

  test('inpainting failure explicitly falls back to overlay', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'jhentai-ctd-inpainting-failure-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File source = File('${root.path}/source.bin')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final ImageInpaintingService service = ImageInpaintingService(
      registry: EngineRegistry(
        inpaintEngine: _FakeInpaintEngine(failure: 'native_failed'),
      ),
    )..setCacheDirectoryForTesting(Directory('${root.path}/cache'));

    final InpaintingResult result = await service.repair(
      requestKey: 'page-1',
      sourcePath: source.path,
      polygonMasks: <PolygonMask>[_squareMask()],
    );
    expect(result.status, InpaintingStatus.failed);
    expect(result.errorCode, 'native_failed');
    expect(result.fallbackToOverlay, isTrue);
    expect(
      service.effectiveOverlayBackgroundOpacity(
        'page-1',
        0.15,
        displayModeOverride:
            ImageProcessingDisplayMode.repairedBackgroundEmbeddedText,
      ),
      1.0,
    );
    expect(await source.readAsBytes(), <int>[1, 2, 3]);
  });

  test(
    'cold start hydrates repaired background from request-keyed disk index',
    () async {
      final Directory root = await Directory.systemTemp.createTemp(
        'jhentai-ctd-hydrate-repair-',
      );
      addTearDown(() => root.delete(recursive: true));
      final File source = File('${root.path}/source.bin')
        ..writeAsBytesSync(<int>[11, 12, 13, 14]);
      final Directory cache = Directory('${root.path}/cache');
      final _FakeInpaintEngine fake = _FakeInpaintEngine();
      final EngineRegistry registry = EngineRegistry(inpaintEngine: fake);
      final ImageInpaintingService service = ImageInpaintingService(
        registry: registry,
      )..setCacheDirectoryForTesting(cache);

      final InpaintingResult first = await service.repair(
        requestKey: 'downloaded:/comics/page-1.jpg',
        sourcePath: source.path,
        polygonMasks: <PolygonMask>[_squareMask()],
      );
      expect(first.status, InpaintingStatus.success);
      expect(first.fromCache, isFalse);
      expect(fake.calls, 1);

      final ImageInpaintingService restarted = ImageInpaintingService(
        registry: registry,
      )..setCacheDirectoryForTesting(cache);
      restarted.setDisplayMode(
        ImageProcessingDisplayMode.repairedBackgroundEmbeddedText,
      );

      // Before hydrate, cold start would otherwise paint translation on the
      // original page: force opaque plates.
      expect(
        restarted.effectiveOverlayBackgroundOpacity(
          'downloaded:/comics/page-1.jpg',
          0.0,
        ),
        1.0,
      );

      final InpaintingResult? hydrated = await restarted.hydrateCachedRepair(
        requestKey: 'downloaded:/comics/page-1.jpg',
        sourcePath: source.path,
      );
      expect(hydrated, isNotNull);
      expect(hydrated!.status, InpaintingStatus.success);
      expect(hydrated.fromCache, isTrue);
      expect(hydrated.outputPath, first.outputPath);
      expect(fake.calls, 1); // no second LaMa Large run
      expect(
        restarted.displayPathFor('downloaded:/comics/page-1.jpg'),
        first.outputPath,
      );
      // Once the cleaned background is restored, honor the user's opacity
      // (including 0 for embedded text on repaired art).
      expect(
        restarted.effectiveOverlayBackgroundOpacity(
          'downloaded:/comics/page-1.jpg',
          0.0,
        ),
        0.0,
      );
    },
  );


  test('detectAndRepair refuses full-page erase without translation geometry',
      () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'jhentai-ctd-no-geometry-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File source = File('${root.path}/source.bin')
      ..writeAsBytesSync(<int>[1, 2]);
    final _FakeInpaintEngine inpainter = _FakeInpaintEngine();
    final ImageInpaintingService service = ImageInpaintingService(
      registry: EngineRegistry(
        detectionEngine: _FakeDetectionEngine(masks: <PolygonMask>[_squareMask()]),
        inpaintEngine: inpainter,
      ),
    )..setCacheDirectoryForTesting(Directory('${root.path}/cache'));

    final InpaintingResult result = await service.detectAndRepair(
      requestKey: 'page-1',
      sourcePath: source.path,
    );
    expect(result.status, InpaintingStatus.failed);
    expect(result.errorCode, 'translation_geometry_required');
    expect(result.fallbackToOverlay, isTrue);
    expect(inpainter.calls, 0);
  });

  test('detectAndRepair only inpaints masks overlapping translated blocks',
      () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'jhentai-ctd-filter-masks-',
    );
    addTearDown(() => root.delete(recursive: true));
    final File source = File('${root.path}/source.bin')
      ..writeAsBytesSync(<int>[3, 4, 5]);
    final PolygonMask farMask = const PolygonMask(
      points: <EnginePoint>[
        EnginePoint(x: 200, y: 200),
        EnginePoint(x: 220, y: 200),
        EnginePoint(x: 220, y: 220),
        EnginePoint(x: 200, y: 220),
      ],
      confidence: 0.9,
    );
    final _FakeDetectionEngine detector = _FakeDetectionEngine(
      masks: <PolygonMask>[_squareMask(), farMask],
    );
    final _FakeInpaintEngine inpainter = _FakeInpaintEngine();
    final ImageInpaintingService service = ImageInpaintingService(
      registry: EngineRegistry(
        detectionEngine: detector,
        inpaintEngine: inpainter,
      ),
    )..setCacheDirectoryForTesting(Directory('${root.path}/cache'));

    // Only the near square overlaps the translated block; farMask must be dropped.
    final InpaintingResult result = await service.detectAndRepair(
      requestKey: 'page-1',
      sourcePath: source.path,
      eraseOnlyBlocks: <RecognizedTextBlock>[_blockOverSquareMask()],
    );
    expect(result.status, InpaintingStatus.success);
    expect(detector.calls, 1);
    expect(inpainter.calls, 1);

    // Far-only translation must not erase anything.
    final ImageInpaintingService service2 = ImageInpaintingService(
      registry: EngineRegistry(
        detectionEngine: _FakeDetectionEngine(
          masks: <PolygonMask>[_squareMask(), farMask],
        ),
        inpaintEngine: _FakeInpaintEngine(),
      ),
    )..setCacheDirectoryForTesting(Directory('${root.path}/cache2'));
    final InpaintingResult skipped = await service2.detectAndRepair(
      requestKey: 'page-2',
      sourcePath: source.path,
      eraseOnlyBlocks: <RecognizedTextBlock>[_blockFarAway()],
    );
    // farMask overlaps far block — that one should succeed. Use only near mask
    // with far block to assert no_translated_masks:
    final ImageInpaintingService service3 = ImageInpaintingService(
      registry: EngineRegistry(
        detectionEngine: _FakeDetectionEngine(masks: <PolygonMask>[_squareMask()]),
        inpaintEngine: _FakeInpaintEngine(),
      ),
    )..setCacheDirectoryForTesting(Directory('${root.path}/cache3'));
    final InpaintingResult noOverlap = await service3.detectAndRepair(
      requestKey: 'page-3',
      sourcePath: source.path,
      eraseOnlyBlocks: <RecognizedTextBlock>[_blockFarAway()],
    );
    expect(noOverlap.status, InpaintingStatus.failed);
    expect(noOverlap.errorCode, 'no_translated_masks');
    expect(noOverlap.fallbackToOverlay, isTrue);
    expect(skipped.status, InpaintingStatus.success);
  });

  test('translatedBlocksEligibleForErase ignores empty translation lines', () {
    final ImageTranslationResult result = ImageTranslationResult(
      status: ImageTranslationStatus.success,
      translatedText: '你好\n\n世界',
      blocks: <RecognizedTextBlock>[
        const RecognizedTextBlock(
          text: 'a',
          confidence: 1,
          left: 0,
          top: 0,
          width: 10,
          height: 10,
        ),
        const RecognizedTextBlock(
          text: 'b',
          confidence: 1,
          left: 20,
          top: 0,
          width: 10,
          height: 10,
        ),
        const RecognizedTextBlock(
          text: 'c',
          confidence: 1,
          left: 40,
          top: 0,
          width: 10,
          height: 10,
        ),
      ],
    );
    final List<RecognizedTextBlock> eligible =
        translatedBlocksEligibleForErase(result);
    expect(eligible.length, 2);
    expect(eligible.map((RecognizedTextBlock b) => b.text).toList(),
        <String>['a', 'c']);
  });

  test('filterPolygonMasksToTranslatedBlocks drops untranslated regions', () {
    final List<PolygonMask> kept = filterPolygonMasksToTranslatedBlocks(
      masks: <PolygonMask>[
        _squareMask(),
        const PolygonMask(
          points: <EnginePoint>[
            EnginePoint(x: 100, y: 100),
            EnginePoint(x: 140, y: 100),
            EnginePoint(x: 140, y: 140),
            EnginePoint(x: 100, y: 140),
          ],
          confidence: 0.8,
        ),
      ],
      translatedBlocks: <RecognizedTextBlock>[_blockOverSquareMask()],
    );
    expect(kept.length, 1);
    expect(kept.single.left, 1);
  });

  test(
    'overlay mode never forces opaque plates while awaiting repair',
    () {
      final ImageInpaintingService service = ImageInpaintingService();
      service.setDisplayMode(ImageProcessingDisplayMode.overlay);
      expect(
        service.effectiveOverlayBackgroundOpacity('page-1', 0.15),
        0.15,
      );
    },
  );

  test('ModelScope LaMa Large manifest is pinned to the inspected artifact', () {
    final ModelDescriptor descriptor =
        OnnxModelCatalog().find(OnnxModelStore.lamaInpaintManifestId)!;
    final ModelArtifactDescriptor artifact = descriptor.artifacts.single;
    expect(artifact.sizeBytes, LamaModelEvidence.artifactSizeBytes);
    expect(artifact.sha256, LamaModelEvidence.artifactSha256);
    expect(artifact.sources.single.url, LamaModelEvidence.artifactUrl);
    expect(descriptor.engineIds, contains('onnx-lama-inpaint'));
    expect(descriptor.licenseName, isNotEmpty);
    expect(descriptor.supportsImages, isFalse);
  });

  test('official CTD ONNX release is pinned as a runtime download', () {
    final ModelDescriptor descriptor =
        OnnxModelCatalog().find(OnnxModelStore.ctdDetectionManifestId)!;
    final ModelArtifactDescriptor artifact = descriptor.artifacts.single;
    expect(artifact.sizeBytes, CtdModelEvidence.artifactSizeBytes);
    expect(artifact.sha256, CtdModelEvidence.artifactSha256);
    expect(artifact.sources.single.url, CtdModelEvidence.artifactUrl);
    expect(descriptor.engineIds, contains('ctd-detection'));
    expect(descriptor.licenseName, contains('GPL-3.0-only'));
  });
}

extension on File {
  Future<String> sha256ForTest() async =>
      (await sha256.bind(openRead()).first).toString();
}
