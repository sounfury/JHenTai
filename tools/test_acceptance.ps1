param(
    [switch]$WithModels,
    [string]$ModelRoot,
    [string]$CaseId
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $projectRoot
try {
    if ($CaseId) {
        $quickTests = @(Get-ChildItem -LiteralPath 'test/acceptance' -Filter '*_test.dart' -File -Recurse |
            Where-Object { $_.BaseName -eq "${CaseId}_test" })
        if ($quickTests.Count -eq 0) { throw "No matching acceptance test: $CaseId" }
        $quickTestPaths = @($quickTests | ForEach-Object { $_.FullName })
        flutter test --no-pub @quickTestPaths
    } else {
        flutter test --no-pub test/acceptance
    }
    if ($LASTEXITCODE -ne 0) { throw 'Acceptance regression tests failed.' }
    if (-not $WithModels) { return }

    if (-not $ModelRoot) {
        $ModelRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'JHTData/OCRmodel/onnx'
    }
    $ModelRoot = (Resolve-Path -LiteralPath $ModelRoot).Path
    flutter build windows --debug --no-pub -t tools/ocr_pipeline_diagnostic.dart
    if ($LASTEXITCODE -ne 0) { throw 'Native acceptance runner build failed.' }

    $cases = @(Get-ChildItem -LiteralPath 'test/acceptance/image_translation' -Filter case.json -File -Recurse)
    if ($CaseId) { $cases = @($cases | Where-Object { $_.Directory.Name -eq $CaseId }) }
    if ($cases.Count -eq 0) { throw 'No matching image translation acceptance case.' }
    foreach ($case in $cases) {
        $annotation = Get-Content -LiteralPath $case.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($annotation.id -ne $case.Directory.Name) { throw "Case ID does not match directory: $($case.FullName)" }
        $outputDir = Join-Path $projectRoot ".dart_tool/acceptance/$($case.Directory.Name)"
        New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        if ($annotation.soundEffectAudit) {
            foreach ($sample in $annotation.cases) {
                $reportPath = Join-Path $outputDir "$($sample.id).pipeline.json"
                if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath }
                $nativeArguments = @(
                    (Join-Path $case.Directory.FullName $sample.source),
                    $ModelRoot, $reportPath, 'directml', '1'
                ) | ForEach-Object { '"' + $_ + '"' }
                $runner = Start-Process -FilePath (Join-Path $projectRoot 'build/windows/x64/runner/Debug/jhentai.exe') `
                    -ArgumentList $nativeArguments -WindowStyle Hidden -PassThru
                if (-not $runner.WaitForExit(180000)) {
                    Stop-Process -Id $runner.Id
                    throw "Native sound-effect acceptance timed out: $($sample.id)"
                }
                if ($runner.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $reportPath)) {
                    throw "Native sound-effect acceptance failed: $($sample.id)"
                }
                $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($report.error) { throw "Native sound-effect acceptance failed: $($report.error)" }
                $retainedText = @($report.runs[-1].result.blocks | ForEach-Object { $_.text })
                $allText = @($report.runs[-1].result.allOcrBlocks | ForEach-Object { $_.text })
                foreach ($text in $sample.preserve) {
                    if ($text -notin $allText -or $text -in $retainedText) {
                        throw "Sound effect was not preserved: $($sample.id) / $text; inspect $reportPath"
                    }
                }
                foreach ($text in $sample.translate) {
                    if ($text -notin $retainedText) { throw "Dialogue was removed: $($sample.id) / $text" }
                }
                Write-Output "PASS $($annotation.id)/$($sample.id): $reportPath"
            }
            continue
        }
        $reportPath = Join-Path $outputDir 'pipeline.json'
        # Prevent an aborted native run from being mistaken for a previous pass.
        if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath }
        $nativeArguments = @(
            (Join-Path $case.Directory.FullName 'source.png'),
            $ModelRoot, $reportPath, 'directml', '1', $case.Directory.FullName
        ) | ForEach-Object { '"' + $_ + '"' }
        $runner = Start-Process -FilePath (Join-Path $projectRoot 'build/windows/x64/runner/Debug/jhentai.exe') `
            -ArgumentList $nativeArguments -WindowStyle Hidden -PassThru
        if (-not $runner.WaitForExit(180000)) {
            Stop-Process -Id $runner.Id
            throw "Native acceptance timed out: $($annotation.id)"
        }
        if ($runner.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $reportPath)) {
            throw "Native acceptance failed: $($annotation.id); inspect $reportPath"
        }
        $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($report.error -or $report.runs[-1].acceptance.passed -ne $true) {
            throw "Native acceptance failed: $($annotation.id); inspect $reportPath"
        }
        $resultFile = if ($annotation.ocrArtifactAudit) { 'acceptance.json' } elseif ($annotation.backgroundOnly) { 'repaired.png' } else { 'translated.png' }
        Write-Output "PASS $($annotation.id): $outputDir/$resultFile"
    }
} finally {
    Pop-Location
}
