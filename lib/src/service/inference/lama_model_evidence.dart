/// Pinned ONNX artifact used by manga-image-translator's LaMa Large backend.
/// SHA-256 and byte length verified locally before integration.
class LamaModelEvidence {
  const LamaModelEvidence._();
  static const String modelId = 'lama-large-512px';
  static const String artifactUrl =
      'https://www.modelscope.cn/models/hgmzhn/manga-translator-ui/resolve/master/lama_large_512px_inpainting.onnx';
  static const int artifactSizeBytes = 207482655;
  static const String artifactSha256 =
      '107c8306ac1d27c83638d6535846986542dfe2707f1498b1ac9be25b4a963864';
  static const String inputContract =
      'image:float32[1,3,H,W], mask:float32[1,1,H,W]; 1=repair';
  static const String outputContract = 'float32[1,3,H,W], RGB in [0,1]';
}
