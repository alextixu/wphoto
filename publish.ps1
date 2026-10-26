# wphoto 發行腳本
#   .\publish.ps1                → 發行到 bin\publish\ 並壓成 dist\wphoto_v<版本>_win-x64.zip
#   .\publish.ps1 -Install E:\wphoto → 另外把發行結果複製到指定資料夾（給自己釘選用）
#
# 以「資料夾」形式發行（不用 PublishSingleFile）：單檔 438MB 在機械硬碟冷啟動要 20 秒，
# 資料夾形式啟動只讀取需要的檔案。ReadyToRun 由 csproj 開啟。
param(
    [string]$Install = ""
)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$out = Join-Path $root "bin\publish"
$dist = Join-Path $root "dist"

$version = ([xml](Get-Content (Join-Path $root "PhotoViewer.csproj"))).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1

Write-Host "Publishing wphoto v$version ..." -ForegroundColor Cyan
if (Test-Path $out) { Remove-Item $out -Recurse -Force }
dotnet publish $root -c Release -r win-x64 --self-contained -o $out -v q
if ($LASTEXITCODE -ne 0) { throw "publish failed" }
Remove-Item (Join-Path $out "*.pdb") -ErrorAction SilentlyContinue

New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist "wphoto_v${version}_win-x64.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $out "*") -DestinationPath $zip
$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "zip: $zip ($size MB)" -ForegroundColor Green

if ($Install) {
    Write-Host "Installing to $Install ..." -ForegroundColor Cyan
    Get-Process wphoto -ErrorAction SilentlyContinue | Stop-Process -Force
    New-Item -ItemType Directory -Force $Install | Out-Null
    Get-ChildItem $Install -Exclude libvlc | Remove-Item -Recurse -Force
    Copy-Item (Join-Path $out "*") $Install -Recurse -Force
    Write-Host "installed: $(Join-Path $Install 'wphoto.exe')" -ForegroundColor Green
}
