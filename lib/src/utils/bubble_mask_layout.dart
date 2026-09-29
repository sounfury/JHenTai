import 'dart:math' as math;
import 'dart:typed_data';

import '../model/bubble_interior_mask.dart';
import '../model/image_translation.dart';
import 'connected_bubble_layout.dart';

/// Conservative raster reduction: every source cell under an output cell must
/// be interior. Do not preselect only the largest connected component.
/// The bounded partition grid controls CPU work, not model segmentation detail.
List<TranslationLayoutRegion> layoutBubbleInterior(BubbleInteriorMask mask) {
  final scale = math.min(1.0, 128 / math.max(mask.width, mask.height));
  final w = math.max(1, (mask.width * scale).floor());
  final h = math.max(1, (mask.height * scale).floor());
  final interior = Uint8List(w * h);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      bool inside = true;
      for (
        int sy = (y * mask.height / h).floor();
        sy < ((y + 1) * mask.height / h).ceil() && inside;
        sy++
      ) {
        for (
          int sx = (x * mask.width / w).floor();
          sx < ((x + 1) * mask.width / w).ceil();
          sx++
        ) {
          if (mask.pixels[sy * mask.width + sx] == 0) {
            inside = false;
            break;
          }
        }
      }
      if (inside) {
        interior[y * w + x] = 1;
      }
    }
  }
  final regions = partitionBubbleInterior(interior, w, h);
  // Inset in source pixels, not a whole coarse mask cell: narrow dialogue
  // should retain useful width. Rectangles remain strictly within the mask.
  return [
    for (final r in regions)
      if (r.width * mask.bounds.width / w > 6 &&
          r.height * mask.bounds.height / h > 6)
        TranslationLayoutRegion(
          mask.bounds.left + r.left * mask.bounds.width / w + 2,
          mask.bounds.top + r.top * mask.bounds.height / h + 2,
          r.width * mask.bounds.width / w - 4,
          r.height * mask.bounds.height / h - 4,
        ),
  ];
}
