import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:jhentai/src/config/theme_config.dart';
import 'package:jhentai/src/model/image_translation.dart';
import 'package:jhentai/src/service/gallery_pre_translate_runner.dart';
import 'package:jhentai/src/service/image_translation_service.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

/// Floating mini-window for [ImageTranslationService] batch progress.
/// Shared by the reader and the gallery detail page pre-translate job.
class ImageTranslationBatchProgressBanner extends StatelessWidget {
  const ImageTranslationBatchProgressBanner({super.key, this.topPadding});

  /// Extra offset below the status bar / app bar. Defaults to status-bar + 8.
  final double? topPadding;

  @override
  Widget build(BuildContext context) {
    final double top = topPadding ?? MediaQuery.of(context).padding.top + 8;
    return Positioned(
      top: top,
      left: 0,
      right: 0,
      child: Center(
        child: GetBuilder<ImageTranslationService>(
          id: ImageTranslationService.batchProgressId,
          builder: (_) {
            if (!imageTranslationService.isBatchTranslating) {
              return const SizedBox.shrink();
            }
            return Material(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 12,
                      height: 12,
                      child:
                          ThemeConfig.isApple
                              ? GlassProgressIndicator.circular(
                                strokeWidth: 2,
                                color: Colors.white,
                              )
                              : const CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'translationProgress'.trParams({
                        'current': '${imageTranslationService.batchCompleted}',
                        'total': '${imageTranslationService.batchTotal}',
                        'stage': _stageLabel(
                          imageTranslationService.currentStage,
                        ),
                      }),
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () {
                        final int? gid = galleryPreTranslateRunner.activeGid;
                        if (gid != null) {
                          galleryPreTranslateRunner.cancelForGallery(gid);
                        } else {
                          imageTranslationService.cancelBatch();
                        }
                      },
                      borderRadius: BorderRadius.circular(12),
                      child: const Padding(
                        padding: EdgeInsets.all(2),
                        child: Icon(Icons.close, color: Colors.white, size: 16),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  static String _stageLabel(ImageTranslationStage stage) {
    switch (stage) {
      case ImageTranslationStage.idle:
      case ImageTranslationStage.downloading:
        return 'translationStageIdle'.tr;
      case ImageTranslationStage.recognizing:
        return 'translationStageRecognizing'.tr;
      case ImageTranslationStage.translating:
        return 'translationStageTranslating'.tr;
      case ImageTranslationStage.done:
        return 'translationStageDone'.tr;
    }
  }
}
