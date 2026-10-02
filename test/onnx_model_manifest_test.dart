import 'package:flutter_test/flutter_test.dart';
import 'package:jhentai/src/service/inference/onnx_model_store.dart';

void main() {
  test('PP-OCRv6 manifest is complete and only advertises real mirrors', () {
    final OnnxModelManifest manifest = OnnxModelStore.manifests.singleWhere(
      (OnnxModelManifest item) => item.id == OnnxModelStore.ocrManifestId,
    );

    expect(manifest.displayName, contains('PP-OCRv6'));
    expect(
      manifest.files.map((OnnxModelFile file) => file.id),
      containsAll(<String>['det', 'rec', 'dict']),
    );
    expect(manifest.availableSources, <OnnxModelSource>[
      OnnxModelSource.huggingFace,
    ]);
    expect(manifest.totalBytes, 23059441);
    expect(manifest.files, hasLength(3));
    expect(manifest.displayName, contains('manga'));
    expect(manifest.fingerprint, contains(manifest.version));

    for (final OnnxModelFile file in manifest.files) {
      expect(file.sha256, hasLength(64));
      expect(file.sizeBytes, greaterThan(0));
      expect(file.urls.keys, containsAll(manifest.availableSources));
      expect(file.urls.values, everyElement(startsWith('https://')));
    }
  });

  test('PP-OCRv6 tiny manifest uses its reduced dictionary and verified files',
      () {
    final OnnxModelManifest manifest = OnnxModelStore.manifests.singleWhere(
      (OnnxModelManifest item) => item.id == OnnxModelStore.ocrTinyManifestId,
    );

    expect(manifest.displayName, contains('tiny'));
    expect(
      manifest.files.map((OnnxModelFile file) => file.id),
      containsAll(<String>['det', 'rec', 'cls', 'dict']),
    );
    expect(manifest.availableSources, <OnnxModelSource>[
      OnnxModelSource.modelScope,
    ]);
    // The tiny tier reuses the shared PP-OCRv4 cls model but ships its own
    // reduced dictionary (27 KB vs the small tier's 75 KB).
    expect(
      manifest.files.singleWhere((OnnxModelFile f) => f.id == 'dict').fileName,
      'ppocrv6_tiny_dict.txt',
    );
    // Verified by downloading each file and hashing it (see the manifest).
    expect(manifest.totalBytes, 1829618 + 4489813 + 585532 + 27156);
    expect(
      manifest.files.singleWhere((OnnxModelFile f) => f.id == 'det').sha256,
      'f42c0fbd294d95eac1a550e131b277dac97462c8025fa4b6c3cec1b7894bd3d5',
    );
    expect(
      manifest.files.singleWhere((OnnxModelFile f) => f.id == 'rec').sha256,
      'e16e242de5937ad92609223f19bc2aff3727ee40b095f996907c24749bad251b',
    );
    expect(
      manifest.files.singleWhere((OnnxModelFile f) => f.id == 'dict').sha256,
      'c5cbe34ef40c29c4df07ed012bf96569cb69a2d2a01a07027e9f13cb832bd9cd',
    );
    for (final OnnxModelFile file in manifest.files) {
      expect(file.sha256, hasLength(64));
      expect(file.sizeBytes, greaterThan(0));
      expect(file.urls.keys, containsAll(manifest.availableSources));
      expect(file.urls.values, everyElement(startsWith('https://')));
    }
  });

  test('Manga109 bubble model is pinned to the NeuronCState artifact', () {
    final OnnxModelManifest manifest = OnnxModelStore.manifests.singleWhere(
      (OnnxModelManifest item) =>
          item.id == OnnxModelStore.bubbleSegmentationManifestId,
    );
    expect(manifest.kind, 'detection');
    expect(manifest.sourceProjectUrl,
        'https://huggingface.co/NeuronCState/manga109-segmentation-bubble-onnx');
    expect(manifest.files, hasLength(1));
    expect(manifest.files.single.fileName, 'best.onnx');
    expect(manifest.files.single.sizeBytes, 12509314);
    expect(
      manifest.files.single.sha256,
      '760146a01c3e9f547bc271751bedacd30ae973bfa043dd7761069be7ae0b1336',
    );
    expect(
      manifest.files.single.urls[OnnxModelSource.huggingFace],
      startsWith(
        'https://huggingface.co/NeuronCState/manga109-segmentation-bubble-onnx/',
      ),
    );
  });
}
