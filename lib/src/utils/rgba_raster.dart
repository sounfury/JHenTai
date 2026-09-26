import 'dart:typed_data';

import 'package:image/image.dart' as image;

/// Upright (EXIF-applied) 8-bit RGBA page pixels.
///
/// The image-translation pipeline decodes a page once and shares this raster
/// with bubble detection, OCR, colour sampling and layout analysis. Resampling
/// works on the raw bytes: the `image` package allocates a `Pixel` per
/// `getPixel` call, which made plain resizes cost more than ONNX inference.
class RgbaRaster {
  RgbaRaster(this.width, this.height, this.pixels)
    : assert(pixels.length == width * height * 4);

  final int width;
  final int height;

  /// Row-major RGBA bytes without row padding.
  final Uint8List pixels;

  /// Decodes [bytes] and applies the EXIF orientation; null when unsupported.
  static RgbaRaster? decode(Uint8List bytes) {
    final image.Image? decoded = image.decodeImage(bytes);
    return decoded == null
        ? null
        : RgbaRaster.fromImage(image.bakeOrientation(decoded));
  }

  factory RgbaRaster.fromImage(image.Image source) {
    final image.Image rgba =
        source.format == image.Format.uint8 &&
                source.numChannels == 4 &&
                !source.hasPalette
            ? source
            : source.convert(
              format: image.Format.uint8,
              numChannels: 4,
              alpha: 255,
            );
    return RgbaRaster(rgba.width, rgba.height, rgba.toUint8List());
  }

  /// A copy as an `image` package image, for analysis code built on its API.
  image.Image toImage() => image.Image.fromBytes(
    width: width,
    height: height,
    bytes: pixels.buffer,
    bytesOffset: pixels.offsetInBytes,
    numChannels: 4,
  );

  Uint32List get _words =>
      (pixels.offsetInBytes & 3) == 0
          ? pixels.buffer.asUint32List(pixels.offsetInBytes, width * height)
          : Uint8List.fromList(pixels).buffer.asUint32List();

  RgbaRaster crop(int left, int top, int cropWidth, int cropHeight) {
    final Uint8List result = Uint8List(cropWidth * cropHeight * 4);
    for (int y = 0; y < cropHeight; y++) {
      final int from = ((top + y) * width + left) * 4;
      result.setRange(y * cropWidth * 4, (y + 1) * cropWidth * 4, pixels, from);
    }
    return RgbaRaster(cropWidth, cropHeight, result);
  }

  /// Matches `image.copyRotate` for `angle: 90` (clockwise) and `angle: -90`.
  RgbaRaster rotate90({required bool clockwise}) {
    final Uint32List source = _words;
    final Uint32List result = Uint32List(width * height);
    final int rotatedWidth = height;
    for (int y = 0; y < width; y++) {
      for (int x = 0; x < rotatedWidth; x++) {
        result[y * rotatedWidth + x] =
            clockwise
                ? source[(height - 1 - x) * width + y]
                : source[x * width + (width - 1 - y)];
      }
    }
    return RgbaRaster(rotatedWidth, width, result.buffer.asUint8List());
  }

  /// Resamples the raster to [targetWidth]x[targetHeight] with exactly the
  /// arithmetic of `image.copyResize(interpolation: linear)` and writes each
  /// RGB value `v` as `v / 255 * scale + offset` into a planar NCHW tensor.
  ///
  /// Pixel (x, y) of channel c lands at
  /// `start + c * planeSize + y * rowStride + x`, so the resized image can sit
  /// inside a larger padded or batched tensor.
  void writeResizedNchw(
    Float32List output, {
    required int targetWidth,
    required int targetHeight,
    required int rowStride,
    required int planeSize,
    int start = 0,
    double scale = 1,
    double offset = 0,
  }) {
    final Float32List lut = Float32List(256);
    for (int v = 0; v < 256; v++) {
      lut[v] = v / 255 * scale + offset;
    }
    final double stepX = width / targetWidth;
    final double stepY = height / targetHeight;
    final int sourceStride = width * 4;
    // copyResize reads the neighbour column/row only when it exists; at the
    // right/bottom edge both far samples collapse onto the current pixel.
    final Int32List near = Int32List(targetWidth);
    final Int32List far = Int32List(targetWidth);
    final Uint8List edgeX = Uint8List(targetWidth);
    final Float64List weightX = Float64List(targetWidth);
    for (int x = 0; x < targetWidth; x++) {
      final double sx = x * stepX;
      final int ix = sx.toInt();
      final bool edge = ix + 1 >= width;
      near[x] = ix * 4;
      far[x] = (edge ? ix : ix + 1) * 4;
      edgeX[x] = edge ? 1 : 0;
      weightX[x] = sx - ix;
    }
    final Uint8List src = pixels;
    for (int y = 0; y < targetHeight; y++) {
      final double sy = y * stepY;
      final int iy = sy.toInt();
      final bool edgeY = iy + 1 >= height;
      final double fy = sy - iy;
      final int row = iy * sourceStride;
      final int nextRow = edgeY ? row : row + sourceStride;
      int index = start + y * rowStride;
      for (int x = 0; x < targetWidth; x++, index++) {
        final double fx = weightX[x];
        final int cc = row + near[x];
        final int nc = row + far[x];
        final int cn = nextRow + near[x];
        final int nn = edgeY || edgeX[x] != 0 ? cc : nextRow + far[x];
        for (int c = 0; c < 3; c++) {
          final int icc = src[cc + c];
          final int inc = src[nc + c];
          final int icn = src[cn + c];
          final int inn = src[nn + c];
          final double value =
              icc +
              fx * (inc - icc + fy * (icc + inn - icn - inc)) +
              fy * (icn - icc);
          output[index + c * planeSize] =
              lut[value <= 0
                  ? 0
                  : value >= 255
                  ? 255
                  : value.toInt()];
        }
      }
    }
  }
}

/// The page raster carried by an isolate payload: a pre-decoded `'image'`,
/// or encoded `'bytes'` decoded here as a fallback.
RgbaRaster? rasterFromPayload(Map<String, dynamic> payload) {
  final Object? raster = payload['image'];
  if (raster is RgbaRaster) {
    return raster;
  }
  final Object? bytes = payload['bytes'];
  return bytes is Uint8List ? RgbaRaster.decode(bytes) : null;
}
