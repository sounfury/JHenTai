param(
  [string]$Flutter = 'flutter',
  [switch]$Offline
)
$ErrorActionPreference = 'Stop'
$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$harness = Join-Path $projectRoot 'build/translation_layout_tests'
New-Item -ItemType Directory -Force -Path $harness | Out-Null
# Test the actual source and fixtures, without resolving unrelated application
# plugins. No files from the app are copied or changed by this harness.
foreach ($name in @('lib', 'test')) {
  $link = Join-Path $harness $name
  if (!(Test-Path -LiteralPath $link)) {
    New-Item -ItemType Junction -Path $link -Target (Join-Path $projectRoot $name) | Out-Null
  }
}
@'
name: jhentai
publish_to: none
environment:
  sdk: '>=3.7.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
  image: 4.3.0
dev_dependencies:
  flutter_test:
    sdk: flutter
'@ | Set-Content -LiteralPath (Join-Path $harness 'pubspec.yaml') -Encoding utf8
Push-Location $harness
try {
  if ($Offline) { & $Flutter pub get --offline } else { & $Flutter pub get }
  if ($LASTEXITCODE -ne 0) { throw 'Translation test dependencies could not be resolved.' }
  & $Flutter test --no-pub --reporter expanded `
    test/connected_bubble_layout_test.dart `
    test/translation_font_size_test.dart `
    test/vertical_translation_layout_test.dart `
    test/image_translation_glyph_metrics_test.dart `
    test/image_translation_reader_state_test.dart `
    test/image_translation_real_page_test.dart
  if ($LASTEXITCODE -ne 0) { throw 'Translation layout tests failed.' }
} finally {
  Pop-Location
}
