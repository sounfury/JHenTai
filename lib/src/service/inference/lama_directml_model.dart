import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'lama_model_evidence.dart';

/// Derive a DirectML-compatible graph without Python or changing model weights.
/// Only the pinned LaMa export is accepted. Its Fourier transform contains
/// A[H,H] @ Unsqueeze(B[N,C,W,H], -1), which DirectML cannot execute at rank 5.
/// Unsqueeze(B @ Transpose(A), -1) is algebraically identical and uses rank 4.
/// Call from a background isolate: reading/hashing this graph is expensive.
Future<String> prepareLamaDirectMlModel(String modelPath) async {
  final File target = File('$modelPath.dml-rank4-v1.onnx');
  // The derivative has a pinned digest of its own. On normal launches only
  // stream this file; there is no need to load/hash the original again.
  if (await target.exists() &&
      await target.length() == LamaModelEvidence.directMlSizeBytes &&
      (await sha256.bind(target.openRead()).first).toString() ==
          LamaModelEvidence.directMlSha256) {
    return target.path;
  }
  final File source = File(modelPath);
  if (await source.length() != LamaModelEvidence.artifactSizeBytes) {
    throw StateError('DirectML rewrite requires the pinned LaMa model');
  }
  final Uint8List bytes = await source.readAsBytes();
  if (sha256.convert(bytes).toString() != LamaModelEvidence.artifactSha256) {
    throw StateError('DirectML rewrite requires the pinned LaMa model');
  }
  final Uint8List patched = rewriteLamaDirectMlGraph(bytes);
  if (patched.length != LamaModelEvidence.directMlSizeBytes ||
      sha256.convert(patched).toString() != LamaModelEvidence.directMlSha256) {
    throw StateError('LaMa DirectML graph integrity check failed');
  }
  final File temporary = File('${target.path}.tmp');
  try {
    temporary.writeAsBytesSync(patched, flush: true);
    if (target.existsSync()) {
      target.deleteSync();
    }
    temporary.renameSync(target.path);
  } finally {
    if (temporary.existsSync()) {
      temporary.deleteSync();
    }
  }
  return target.path;
}

/// Minimal protobuf wire editor: unknown fields and weight payloads are copied
/// verbatim. We intentionally do not parse/re-serialize tensor weights.
Uint8List rewriteLamaDirectMlGraph(Uint8List bytes) {
  final List<_Field> model = _fields(bytes);
  final _Field graphField = model.singleWhere((f) => f.number == 7);
  final List<_Field> graph = _fields(graphField.payload);
  final Map<String, List<_Field>> producers = {};
  for (final field in graph.where((f) => f.number == 1)) {
    final node = _fields(field.payload);
    for (final output in _strings(node, 2)) {
      producers[output] = node;
    }
  }
  int rewritten = 0;
  final BytesBuilder graphBytes = BytesBuilder(copy: false);
  for (final field in graph) {
    if (field.number != 1) {
      graphBytes.add(field.raw);
      continue;
    }
    final node = _fields(field.payload);
    final inputs = _strings(node, 1);
    final op = _strings(node, 4).single;
    final producer =
        op == 'MatMul' && inputs.length == 2 ? producers[inputs[1]] : null;
    if (producer == null || _strings(producer, 4).single != 'Unsqueeze') {
      graphBytes.add(field.raw);
      continue;
    }
    final unsqueezed = _strings(producer, 1);
    if (unsqueezed.length != 2) {
      throw StateError('Unexpected LaMa Unsqueeze');
    }
    final String prefix = '${_strings(node, 3).single}/dml';
    final Uint8List perm = _join([
      _string(1, 'perm'), _integer(8, 1), _integer(8, 0),
      _integer(20, 7), // AttributeProto.INTS
    ]);
    graphBytes.add(
      _message(
        1,
        _node(
          'Transpose',
          '$prefix/transpose',
          [inputs[0]],
          ['$prefix/t'],
          attributes: [perm],
        ),
      ),
    );
    graphBytes.add(
      _message(
        1,
        _node(
          'MatMul',
          '$prefix/matmul',
          [unsqueezed[0], '$prefix/t'],
          ['$prefix/m'],
        ),
      ),
    );
    graphBytes.add(
      _message(
        1,
        _node('Unsqueeze', '$prefix/restore', [
          '$prefix/m',
          unsqueezed[1],
        ], _strings(node, 2)),
      ),
    );
    rewritten++;
  }
  if (rewritten != 144) {
    throw StateError('Unexpected LaMa Fourier graph: $rewritten MatMuls');
  }
  return _join([
    for (final field in model)
      if (identical(field, graphField))
        _message(7, graphBytes.takeBytes())
      else
        field.raw,
  ]);
}

Uint8List _node(
  String op,
  String name,
  List<String> inputs,
  List<String> outputs, {
  List<Uint8List> attributes = const [],
}) => _join([
  for (final input in inputs) _string(1, input),
  for (final output in outputs) _string(2, output),
  _string(3, name),
  _string(4, op),
  for (final attribute in attributes) _message(5, attribute),
]);

List<String> _strings(List<_Field> fields, int number) => [
  for (final field in fields)
    if (field.number == number) utf8.decode(field.payload),
];

Uint8List _join(List<Uint8List> chunks) {
  final builder = BytesBuilder(copy: false);
  for (final chunk in chunks) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Uint8List _varint(int value) {
  final result = <int>[];
  while (value >= 128) {
    result.add((value & 127) | 128);
    value >>= 7;
  }
  result.add(value);
  return Uint8List.fromList(result);
}

Uint8List _integer(int number, int value) =>
    _join([_varint(number << 3), _varint(value)]);
Uint8List _string(int number, String value) =>
    _message(number, Uint8List.fromList(utf8.encode(value)));
Uint8List _message(int number, Uint8List value) =>
    _join([_varint((number << 3) | 2), _varint(value.length), value]);

class _Field {
  const _Field(this.number, this.raw, this.payload);
  final int number;
  final Uint8List raw, payload;
}

List<_Field> _fields(Uint8List bytes) {
  int offset = 0;
  int readVarint() {
    int value = 0;
    for (int shift = 0; shift < 64; shift += 7) {
      if (offset >= bytes.length) {
        throw const FormatException('Truncated protobuf');
      }
      final int byte = bytes[offset++];
      value |= (byte & 127) << shift;
      if (byte < 128) {
        return value;
      }
    }
    throw const FormatException('Invalid protobuf varint');
  }

  final result = <_Field>[];
  while (offset < bytes.length) {
    final int start = offset;
    final int tag = readVarint();
    int payloadStart = offset;
    switch (tag & 7) {
      case 0:
        readVarint();
      case 1:
        offset += 8;
      case 2:
        final int size = readVarint();
        payloadStart = offset;
        offset += size;
      case 5:
        offset += 4;
      default:
        throw const FormatException('Unsupported protobuf wire type');
    }
    if (tag >> 3 == 0 || offset > bytes.length || offset < payloadStart) {
      throw const FormatException('Invalid protobuf field');
    }
    result.add(
      _Field(
        tag >> 3,
        Uint8List.sublistView(bytes, start, offset),
        Uint8List.sublistView(bytes, payloadStart, offset),
      ),
    );
  }
  return result;
}
