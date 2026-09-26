$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$parts = Join-Path $repo 'source_parts'
$workRoot = Join-Path $repo '_work'
$sourceZip = Join-Path $workRoot 'source.zip'
$extract = Join-Path $workRoot 'src'
$out = Join-Path $workRoot 'out'
$ready = Join-Path $workRoot 'ready'

Remove-Item $workRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $workRoot,$extract,$out,$ready | Out-Null

Write-Host 'Reconstructing source archive...'
$b64 = ''
Get-ChildItem $parts -Filter '*.b64' | Sort-Object Name | ForEach-Object {
    $b64 += (Get-Content $_.FullName -Raw).Trim()
}
[IO.File]::WriteAllBytes($sourceZip, [Convert]::FromBase64String($b64))
Expand-Archive -LiteralPath $sourceZip -DestinationPath $extract -Force
$src = Join-Path $extract 'ZODCHI-RevitTrace-R1'
if (-not (Test-Path $src)) { throw 'Source archive root was not found.' }

Write-Host 'Patching Revit API references for clean CI build...'
$addinProj = Join-Path $src 'src\RevitTrace.Addin\RevitTrace.Addin.csproj'
@'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0-windows</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <LangVersion>latest</LangVersion>
    <AssemblyName>ZODCHI.RevitTrace.Addin</AssemblyName>
    <RootNamespace>ZODCHI.RevitTrace.Addin</RootNamespace>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="..\RevitTrace.Shared\RevitTrace.Shared.csproj" />
  </ItemGroup>
  <ItemGroup>
    <PackageReference Include="Nice3point.Revit.Api.RevitAPI" Version="2025.*" PrivateAssets="all" ExcludeAssets="runtime" />
    <PackageReference Include="Nice3point.Revit.Api.RevitAPIUI" Version="2025.*" PrivateAssets="all" ExcludeAssets="runtime" />
  </ItemGroup>
</Project>
'@ | Set-Content -LiteralPath $addinProj -Encoding UTF8

# R1.3 source fixes required by the Revit 2025 compiler.
$snapshot = Join-Path $src 'src\RevitTrace.Addin\SnapshotBuilder.cs'
$code = Get-Content $snapshot -Raw

$paramReplacement = @'
                    object? raw;
                    switch (p.StorageType)
                    {
                        case StorageType.String:
                            raw = p.AsString();
                            break;
                        case StorageType.Double:
                            raw = p.AsDouble();
                            break;
                        case StorageType.Integer:
                            raw = p.AsInteger();
                            break;
                        case StorageType.ElementId:
                            raw = p.AsElementId()?.Value;
                            break;
                        default:
                            raw = null;
                            break;
                    }
'@
$patched = [regex]::Replace(
    $code,
    '(?ms)\s*object\? raw = p\.StorageType switch\s*\{.*?^\s*\};',
    [Environment]::NewLine + $paramReplacement.TrimEnd(),
    1)
if ($patched -eq $code) { Write-Host 'Parameter switch was already fixed or not found.' -ForegroundColor Yellow }
$code = $patched

$locationReplacement = @'
            if (element.Location is LocationPoint lp)
            {
                return new
                {
                    kind = "point",
                    point = P(lp.Point),
                    rotation = lp.Rotation
                };
            }
            if (element.Location is LocationCurve lc)
            {
                return new
                {
                    kind = "curve",
                    curve_type = lc.Curve.GetType().Name,
                    start = SafePoint(() => lc.Curve.GetEndPoint(0)),
                    end = SafePoint(() => lc.Curve.GetEndPoint(1)),
                    length = Safe(() => lc.Curve.Length)
                };
            }
            return null;
'@
$patched = [regex]::Replace(
    $code,
    '(?ms)\s*return element\.Location switch\s*\{.*?^\s*\};',
    [Environment]::NewLine + $locationReplacement.TrimEnd(),
    1)
if ($patched -eq $code) { Write-Host 'Location switch was already fixed or not found.' -ForegroundColor Yellow }
Set-Content -LiteralPath $snapshot -Value $patched -Encoding UTF8

$events = Join-Path $src 'src\RevitTrace.Addin\RevitEventRecorder.cs'
$code = Get-Content $events -Raw
$dialogReplacement = @'
        object typed;
        if (e is TaskDialogShowingEventArgs td)
        {
            typed = new { kind = "task_dialog", dialog_id = td.DialogId };
        }
        else if (e is MessageBoxShowingEventArgs mb)
        {
            typed = new { kind = "message_box", dialog_id = mb.DialogId, message = Safe(() => mb.Message) };
        }
        else
        {
            typed = new { kind = "dialog", dialog_id = Safe(() => e.DialogId) };
        }
'@
$patched = [regex]::Replace(
    $code,
    '(?ms)\s*object typed = e switch\s*\{.*?^\s*\};',
    [Environment]::NewLine + $dialogReplacement.TrimEnd(),
    1)
if ($patched -eq $code) { Write-Host 'Dialog switch was already fixed or not found.' -ForegroundColor Yellow }
Set-Content -LiteralPath $events -Value $patched -Encoding UTF8

# R1.3 aggregator typo.
$aggProgram = Join-Path $src 'src\RevitTrace.Aggregator\AggregatorProgram.cs'
$code = Get-Content $aggProgram -Raw
$code = $code.Replace('var options = Arguments.Parse(args);', 'var options = AggregatorOptions.Parse(args);')
Set-Content -LiteralPath $aggProgram -Value $code -Encoding UTF8

# R1.3 UI watcher missing namespace.
$uiWatcherSource = Join-Path $src 'src\RevitTrace.UIWatcher\RevitUiWatcher.cs'
$code = Get-Content $uiWatcherSource -Raw
if ($code -notmatch '(?m)^using System\.IO;\s*$') {
    $code = 'using System.IO;' + [Environment]::NewLine + $code
}
Set-Content -LiteralPath $uiWatcherSource -Value $code -Encoding UTF8

Write-Host 'Building Revit add-in...'
dotnet restore $addinProj --nologo
if ($LASTEXITCODE -ne 0) { throw 'Revit add-in restore failed.' }
dotnet build $addinProj -c Release --no-restore --nologo
if ($LASTEXITCODE -ne 0) { throw 'Revit add-in build failed.' }

$addinBin = Join-Path $src 'src\RevitTrace.Addin\bin\Release\net8.0-windows'
$payload = Join-Path $ready 'Payload\ZODCHI.RevitTrace'
$companion = Join-Path $payload 'Companion'
New-Item -ItemType Directory -Force -Path $payload,$companion | Out-Null
Copy-Item (Join-Path $addinBin 'ZODCHI.RevitTrace.Addin.dll') $payload -Force
Copy-Item (Join-Path $addinBin 'ZODCHI.RevitTrace.Shared.dll') $payload -Force

Write-Host 'Publishing aggregator...'
$aggOut = Join-Path $out 'agg'
dotnet publish (Join-Path $src 'src\RevitTrace.Aggregator\RevitTrace.Aggregator.csproj') -c Release --self-contained false --nologo -o $aggOut
if ($LASTEXITCODE -ne 0) { throw 'Aggregator publish failed.' }
Copy-Item (Join-Path $aggOut '*') $companion -Recurse -Force

Write-Host 'Publishing UI watcher...'
$uiOut = Join-Path $out 'ui'
dotnet publish (Join-Path $src 'src\RevitTrace.UIWatcher\RevitTrace.UIWatcher.csproj') -c Release --self-contained false --nologo -o $uiOut
if ($LASTEXITCODE -ne 0) { throw 'UI watcher publish failed.' }
Copy-Item (Join-Path $uiOut '*') $companion -Recurse -Force

# Never redistribute Autodesk assemblies.
$forbidden = Get-ChildItem $ready -Recurse -File | Where-Object {
    $_.Name -in @('RevitAPI.dll','RevitAPIUI.dll','AdWindows.dll','UIFramework.dll')
}
if ($forbidden) {
    throw ('Forbidden Autodesk runtime assemblies found in package: ' + ($forbidden.FullName -join '; '))
}

@'
param()
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$payload = Join-Path $here 'Payload\ZODCHI.RevitTrace'
$addinBase = Join-Path $env:APPDATA 'Autodesk\Revit\Addins\2025'
$installDir = Join-Path $addinBase 'ZODCHI.RevitTrace'
$manifestPath = Join-Path $addinBase 'ZODCHI.RevitTrace.addin'

if (Get-Process Revit -ErrorAction SilentlyContinue) {
    throw 'Close Revit before installing ZODCHI RevitTrace.'
}
if (-not (Test-Path (Join-Path $payload 'ZODCHI.RevitTrace.Addin.dll'))) {
    throw 'Payload is incomplete.'
}

New-Item -ItemType Directory -Force -Path $addinBase | Out-Null
Remove-Item $installDir -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item $payload $installDir -Recurse -Force

$assembly = Join-Path $installDir 'ZODCHI.RevitTrace.Addin.dll'
$xml = @"
<?xml version="1.0" encoding="utf-8" standalone="no"?>
<RevitAddIns>
  <AddIn Type="Application">
    <Name>ZODCHI RevitTrace</Name>
    <Assembly>$assembly</Assembly>
    <AddInId>29F3222B-0C42-469E-9A2C-BC97D723EA7B</AddInId>
    <FullClassName>ZODCHI.RevitTrace.Addin.RevitTraceApplication</FullClassName>
    <VendorId>ZODCHI</VendorId>
    <VendorDescription>ZODCHI Research - observable Revit workflow recorder</VendorDescription>
  </AddIn>
</RevitAddIns>
"@
Set-Content -LiteralPath $manifestPath -Value $xml -Encoding UTF8

$settingsDir = Join-Path $env:APPDATA 'ZODCHI\RevitTrace'
New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null

Write-Host ''
Write-Host 'ZODCHI RevitTrace installed.' -ForegroundColor Green
Write-Host "Manifest: $manifestPath"
Write-Host "Add-in:   $installDir"
Write-Host "Start Revit 2025 and open the ZODCHI Research ribbon tab."
'@ | Set-Content -LiteralPath (Join-Path $ready 'install-ready.ps1') -Encoding UTF8

@'
@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-ready.ps1"
if errorlevel 1 (
  echo.
  echo INSTALL FAILED.
  pause
  exit /b 1
)
echo.
echo INSTALL COMPLETE.
pause
'@ | Set-Content -LiteralPath (Join-Path $ready 'INSTALL.cmd') -Encoding ASCII

@'
@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$b=Join-Path $env:APPDATA 'Autodesk\Revit\Addins\2025'; Remove-Item (Join-Path $b 'ZODCHI.RevitTrace.addin') -Force -ErrorAction SilentlyContinue; Remove-Item (Join-Path $b 'ZODCHI.RevitTrace') -Recurse -Force -ErrorAction SilentlyContinue; Write-Host 'ZODCHI RevitTrace removed.'"
pause
'@ | Set-Content -LiteralPath (Join-Path $ready 'UNINSTALL.cmd') -Encoding ASCII

@'
ZODCHI RevitTrace R1.4 - READY BUILD FOR REVIT 2025

INSTALL:
1. Close Revit 2025.
2. Double-click INSTALL.cmd.
3. Start Revit 2025.
4. Open ribbon tab "ZODCHI Research".
5. Press "Start Capture".

No build, Revit path selection, Python, Visual Studio or Revit SDK is required.

INSTALL TARGET:
%APPDATA%\Autodesk\Revit\Addins\2025\ZODCHI.RevitTrace.addin
%APPDATA%\Autodesk\Revit\Addins\2025\ZODCHI.RevitTrace\

This package does NOT contain Autodesk RevitAPI.dll/RevitAPIUI.dll.
The recorder uses the Revit API assemblies loaded by Revit.
'@ | Set-Content -LiteralPath (Join-Path $ready 'README_INSTALL.txt') -Encoding UTF8

$releaseDir = Join-Path $repo 'release'
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$zip = Join-Path $releaseDir 'ZODCHI-RevitTrace-R1.4-ready.zip'
Remove-Item $zip -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $ready '*') -DestinationPath $zip -CompressionLevel Optimal

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
"$hash  ZODCHI-RevitTrace-R1.4-ready.zip" | Set-Content (Join-Path $releaseDir 'ZODCHI-RevitTrace-R1.4-ready.zip.sha256') -Encoding ASCII
Write-Host "READY: $zip"
Write-Host "SHA256: $hash"
