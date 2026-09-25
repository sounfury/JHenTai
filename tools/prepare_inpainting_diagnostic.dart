// Run with a package config providing package:image. This exercises the same
// pixel preprocessing as the application without loading the native plugin.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../lib/src/utils/inpainting_pixels.dart';

void main(List<String> args) {
  if (args.length == 5 && args[0] == '--restore') {
    final source = img.decodeImage(File(args[1]).readAsBytesSync())!;
    final knownMask = File(args[2]).readAsBytesSync();
    final prediction = img.decodeImage(File(args[3]).readAsBytesSync())!;
    final output = compositeLamaOutput(source, knownMask, prediction);
    File(args[4]).writeAsBytesSync(img.encodePng(output));
    print('Restored with application compositor: ${args[4]}');
    return;
  }
  if (args.length < 3)
    throw ArgumentError(
      'source.png coarse-known-mask.png output-dir [max-side]',
    );
  final source = img.decodeImage(File(args[0]).readAsBytesSync())!;
  final coarseImage = img.decodeImage(File(args[1]).readAsBytesSync())!;
  if (source.width != coarseImage.width || source.height != coarseImage.height)
    throw ArgumentError('mask size mismatch');
  final coarse = Uint8List(source.width * source.height);
  for (int y = 0; y < source.height; y++) {
    for (int x = 0; x < source.width; x++) {
      coarse[y * source.width + x] = coarseImage.getPixel(x, y).r.toInt();
    }
  }
  final mask = refineInpaintingMask(source, coarse);
  final input = prepareLamaInput(
    source,
    mask,
    maxSide: args.length > 3 ? int.parse(args[3]) : 2048,
  );
  Directory(args[2]).createSync(recursive: true);
  File('${args[2]}/rgb.f32').writeAsBytesSync(input.rgb.buffer.asUint8List());
  File('${args[2]}/mask.f32').writeAsBytesSync(input.mask.buffer.asUint8List());
  File('${args[2]}/known-mask.u8').writeAsBytesSync(mask);
  File('${args[2]}/input.json').writeAsStringSync(
    jsonEncode({
      'width': input.width,
      'height': input.height,
      'contentWidth': input.contentWidth,
      'contentHeight': input.contentHeight,
      'sourceWidth': source.width,
      'sourceHeight': source.height,
      'repairPixels': mask.where((v) => v == 0).length,
    }),
  );
  print(File('${args[2]}/input.json').readAsStringSync());
}
