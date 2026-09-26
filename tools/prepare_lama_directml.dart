import '../lib/src/service/inference/lama_directml_model.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1)
    throw ArgumentError('Expected the pinned lamalarge.onnx path');
  print(await prepareLamaDirectMlModel(args.single));
}
