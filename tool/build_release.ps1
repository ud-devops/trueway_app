# Release build for Trueway Farms.
#
# Exists for one reason: `--no-tree-shake-icons` must never be forgotten.
# Without it the release build ships a subset of the Material Symbols variable
# font that is missing glyphs the app draws — the home bell, the "All" chip,
# four of the five bottom-nav icons, the unsaved wishlist heart — and every one
# of them renders as blank space. Debug builds look perfect, because only
# release shakes the font. See docs/BUILD_AND_RUN.md.
#
#   .\tool\build_release.ps1            # APK  (sideload / QA)
#   .\tool\build_release.ps1 appbundle  # AAB  (Play Store upload)
#   .\tool\build_release.ps1 apk -Split # per-ABI APKs

param(
    [ValidateSet('apk', 'appbundle')]
    [string]$Target = 'apk',

    [switch]$Split
)

$ErrorActionPreference = 'Stop'

# Repo root, whichever directory this was invoked from.
Set-Location (Split-Path $PSScriptRoot -Parent)

$flags = @('--release', '--no-tree-shake-icons')
if ($Split -and $Target -eq 'apk') { $flags += '--split-per-abi' }

Write-Host "flutter build $Target $($flags -join ' ')" -ForegroundColor Cyan
& flutter build $Target @flags
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Name the artefact so a stale file cannot be mistaken for a fresh one — the
# icon report that started all this came from testing a build several hours
# older than the code.
$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*(.+)$').Matches[0].Groups[1].Value.Trim()
$stamp = Get-Date -Format 'yyyyMMdd-HHmm'

if ($Target -eq 'apk' -and -not $Split) {
    $src = 'build/app/outputs/flutter-apk/app-release.apk'
    $out = "build/app/outputs/flutter-apk/trueway-$version-$stamp.apk"
} elseif ($Target -eq 'appbundle') {
    $src = 'build/app/outputs/bundle/release/app-release.aab'
    $out = "build/app/outputs/bundle/release/trueway-$version-$stamp.aab"
} else {
    $src = $null
}

if ($src -and (Test-Path $src)) {
    Copy-Item $src $out -Force
    $mb = [math]::Round((Get-Item $out).Length / 1MB, 1)
    Write-Host "`nBuilt $out  ($mb MB)" -ForegroundColor Green
}
