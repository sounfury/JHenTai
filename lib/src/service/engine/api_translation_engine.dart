import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:jhentai/src/service/log.dart';
import 'package:jhentai/src/setting/image_translation_setting.dart';

import 'context_translation_contract.dart';
import 'engine_contract.dart';
import 'translation_protocol.dart';

class ApiTranslationEngine
    implements TranslationEngine, ContextTranslationEngine {
  ApiTranslationEngine({
    ImageTranslationSetting? setting,
    Dio Function(BaseOptions options)? dioFactory,
  }) : _setting = setting ?? imageTranslationSetting,
       _dioFactory = dioFactory ?? Dio.new;

  final ImageTranslationSetting _setting;
  final Dio Function(BaseOptions options) _dioFactory;

  @override
  final EngineDescriptor descriptor = const EngineDescriptor(
    id: 'api-translation',
    kind: EngineKind.translation,
    displayName: 'Configured Translation API',
    platforms: <EnginePlatform>{
      EnginePlatform.android,
      EnginePlatform.ios,
      EnginePlatform.linux,
      EnginePlatform.macos,
      EnginePlatform.windows,
      EnginePlatform.web,
    },
  );

  @override
  bool get isReady => _setting.isTranslatorConfigured;

  @override
  EngineTask<TranslationResult> translate(
    TranslationEngineRequest request,
  ) => EngineTask<TranslationResult>.start(
    operation: (EngineTaskContext context) async {
      final TranslationPrompt prompt = buildTranslationPrompt(request);
      final String content = await _requestTranslation(
        context,
        prompt,
        kind: 'single',
        items:
            '${prompt.groups.length} groups / ${request.blocks.length} lines',
        receiveTimeout: const Duration(seconds: 90),
      );
      final TranslationResult result = parseTranslationResponse(
        content,
        request,
        prompt,
      );
      context.report(EngineTaskStage.finalizing, 0.98);
      return result;
    },
  );

  @override
  EngineTask<ContextTranslationResult> translateContext(
    ContextTranslationEngineRequest request,
  ) => EngineTask<ContextTranslationResult>.start(
    operation: (EngineTaskContext context) async {
      final int lineCount = request.pages.fold<int>(
        0,
        (int total, ContextTranslationPageRequest page) =>
            total + page.lines.length,
      );
      // Allow dense multi-page JSON responses without truncation.
      final int maxTokens = (lineCount * 128 + 512).clamp(2048, 16384);
      final String content = await _requestTranslation(
        context,
        buildContextTranslationPrompt(request),
        kind: 'context',
        items:
            '${request.pages.length} pages (${request.targetPageIds.length} targets) / $lineCount lines, max_tokens $maxTokens',
        receiveTimeout: const Duration(seconds: 120),
        maxTokens: maxTokens,
      );
      try {
        final ContextTranslationResult result = parseContextTranslationResponse(
          content,
        );
        context.report(EngineTaskStage.finalizing, 0.98);
        return result;
      } on FormatException catch (error) {
        throw EngineException(
          code: 'invalid_response',
          message: error.message,
          engineId: descriptor.id,
          cause: error,
        );
      }
    },
  );

  Future<String> _requestTranslation(
    EngineTaskContext context,
    TranslationPrompt prompt, {
    required String kind,
    required String items,
    required Duration receiveTimeout,
    int? maxTokens,
  }) async {
    if (!isReady) {
      throw const EngineException(
        code: 'not_configured',
        message: 'A translation API endpoint, key and model are required.',
        engineId: 'api-translation',
      );
    }
    final ImageTranslationProvider provider = _setting.translatorProvider.value;
    final bool anthropic = provider == ImageTranslationProvider.anthropic;
    final Dio dio = _dioFactory(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: receiveTimeout,
      ),
    );
    final CancelToken cancelToken = CancelToken();
    final subscription = context.cancellation.onCancel.listen(
      (_) => cancelToken.cancel('engine task cancelled'),
    );
    final Stopwatch clock = Stopwatch()..start();
    try {
      context.report(EngineTaskStage.processing, 0.1);
      final Response<dynamic> response = await dio.post(
        _translationEndpoint(_setting.translatorEndpoint.value!, provider),
        options: Options(
          headers: _headers(provider, _setting.translatorApiKey.value!),
        ),
        cancelToken: cancelToken,
        data: <String, dynamic>{
          'model': _setting.translatorModel.value,
          if (anthropic) 'system': prompt.instruction else 'temperature': 0.2,
          if (anthropic || maxTokens != null) 'max_tokens': maxTokens ?? 2048,
          'messages': <Map<String, String>>[
            if (!anthropic)
              <String, String>{'role': 'system', 'content': prompt.instruction},
            <String, String>{'role': 'user', 'content': prompt.prompt},
          ],
          ...?_thinkingParam(),
        },
      );
      final String? content = _contentFromResponse(response.data, provider);
      _logTiming(
        kind: kind,
        items: items,
        promptChars: prompt.instruction.length + prompt.prompt.length,
        httpMs: clock.elapsedMilliseconds,
        data: response.data,
        content: content,
      );
      if (content == null || content.trim().isEmpty) {
        throw const EngineException(
          code: 'invalid_response',
          message: 'The translation API returned no text.',
          engineId: 'api-translation',
        );
      }
      return content;
    } on DioException catch (error) {
      if (CancelToken.isCancel(error) || context.cancellation.isCancelled) {
        throw EngineTaskCancelledException(context.cancellation.reason);
      }
      throw EngineException(
        code: 'request_failed',
        message: error.message ?? error.toString(),
        engineId: descriptor.id,
        cause: error,
      );
    } on TimeoutException catch (error) {
      context.cancellation.throwIfCancelled();
      throw EngineException(
        code: 'timeout',
        message: error.toString(),
        engineId: descriptor.id,
        cause: error,
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<List<String>> fetchModels({
    required ImageTranslationProvider provider,
    required String apiBaseUrl,
    required String apiKey,
  }) async {
    final String baseUrl = _trimUrl(apiBaseUrl);
    if (baseUrl.isEmpty || apiKey.trim().isEmpty) {
      throw const EngineException(
        code: 'configuration_required',
        message: 'API base URL and key are required.',
        engineId: 'api-translation',
      );
    }
    final Dio dio = _dioFactory(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );
    final Response<dynamic> response = await dio.get(
      _modelsEndpoint(baseUrl),
      options: Options(headers: _headers(provider, apiKey)),
    );
    final dynamic models = response.data is Map ? response.data['data'] : null;
    if (models is! List) {
      throw const EngineException(
        code: 'invalid_response',
        message: 'The model list response is invalid.',
        engineId: 'api-translation',
      );
    }
    final List<String> ids =
        models
            .whereType<Map>()
            .map((Map<dynamic, dynamic> model) => model['id'])
            .whereType<String>()
            .where((String id) => id.trim().isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    if (ids.isEmpty) {
      throw const EngineException(
        code: 'empty_models',
        message: 'The model list is empty.',
        engineId: 'api-translation',
      );
    }
    return ids;
  }

  String? _contentFromResponse(
    dynamic data,
    ImageTranslationProvider provider,
  ) {
    if (provider == ImageTranslationProvider.anthropic) {
      final dynamic blocks = data is Map ? data['content'] : null;
      return blocks is List
          ? blocks
              .whereType<Map>()
              .map((Map<dynamic, dynamic> block) => block['text'])
              .whereType<String>()
              .join('\n')
              .trim()
          : null;
    }
    final dynamic choices = data is Map ? data['choices'] : null;
    if (choices is! List || choices.isEmpty || choices.first is! Map) {
      return null;
    }
    final dynamic message = choices.first['message'];
    final dynamic content = message is Map ? message['content'] : null;
    return content is String ? content.trim() : null;
  }

  /// One diagnostic line per API call: request size, HTTP latency and the
  /// provider-reported token usage (including hidden reasoning tokens).
  void _logTiming({
    required String kind,
    required String items,
    required int promptChars,
    required int httpMs,
    required dynamic data,
    required String? content,
  }) {
    final dynamic usage = data is Map ? data['usage'] : null;
    final dynamic choices = data is Map ? data['choices'] : null;
    final dynamic message =
        choices is List && choices.isNotEmpty && choices.first is Map
            ? choices.first['message']
            : null;
    final dynamic reasoning =
        message is Map ? message['reasoning_content'] : null;
    log.info(
      '[翻译计时] $kind model=${_setting.translatorModel.value} $items, '
      'prompt ${promptChars}chars, HTTP ${httpMs}ms, '
      'content ${content?.length ?? 0}chars, '
      'reasoning ${reasoning is String ? reasoning.length : 0}chars, '
      'usage=${usage == null ? 'n/a' : jsonEncode(usage)}',
    );
  }

  /// Reasoning models think by default: on a comic page ~99% of the output
  /// tokens (and of the latency) were hidden reasoning, so honour the setting.
  Map<String, dynamic>? _thinkingParam() {
    final String model = _setting.translatorModel.value.toLowerCase();
    final bool enabled = _setting.enableThinking.value;
    if (model.contains('deepseek')) {
      return <String, dynamic>{
        'thinking': <String, String>{'type': enabled ? 'enabled' : 'disabled'},
      };
    }
    // Gemini 3 thinking cannot be switched off and ignores `thinking`; `low`
    // is its lowest officially supported effort (none/minimal return 400 on
    // Google's own endpoint). Measured on 3.8 Flash: ~650 -> 0 reasoning
    // tokens. Aliases with a level suffix (`-high`) still honour it.
    if (model.contains('gemini')) {
      return enabled ? null : <String, dynamic>{'reasoning_effort': 'low'};
    }
    if (!model.contains('minimax') && !model.contains('m3')) {
      return null;
    }
    return <String, dynamic>{
      'thinking': <String, String>{'type': enabled ? 'adaptive' : 'disabled'},
    };
  }

  String _modelsEndpoint(String baseUrl) => '${_trimUrl(baseUrl)}/models';

  String _translationEndpoint(
    String baseUrl,
    ImageTranslationProvider provider,
  ) =>
      '${_trimUrl(baseUrl)}/${provider == ImageTranslationProvider.anthropic ? 'messages' : 'chat/completions'}';

  String _trimUrl(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');

  Map<String, String> _headers(
    ImageTranslationProvider provider,
    String apiKey,
  ) => <String, String>{
    if (provider == ImageTranslationProvider.anthropic) ...<String, String>{
      'x-api-key': apiKey.trim(),
      'anthropic-version': '2023-06-01',
    } else
      'Authorization': 'Bearer ${apiKey.trim()}',
    'Content-Type': 'application/json',
  };
}
