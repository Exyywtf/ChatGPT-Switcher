#Requires -Version 5.1
param([string]$OutputDirectory=(Join-Path $PSScriptRoot 'dist'))
$ErrorActionPreference='Stop'
$OutputDirectory=[IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($OutputDirectory)
$compiler=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not (Test-Path -LiteralPath $compiler)) { throw 'The Windows .NET Framework C# compiler was not found.' }
$source=Join-Path $PSScriptRoot 'ChatGPT-Switcher.ps1'
$icon=Join-Path $PSScriptRoot 'assets\switcher.ico'
$license=Join-Path $PSScriptRoot 'LICENSE'
$launcher=Join-Path $PSScriptRoot 'packaging\Launcher.cs'
$tokens=$null;$errors=$null
$null=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if($errors.Count) { throw ($errors | Out-String) }
$output=Join-Path $OutputDirectory 'ChatGPT-Switcher.exe'
$arguments=@(
  '/nologo','/target:winexe','/platform:x64','/optimize+','/debug-','/r:System.Windows.Forms.dll',
  ('/out:'+$output),('/win32icon:'+$icon),
  ('/resource:'+$source+',ChatGPT-Switcher.ps1'),
  ('/resource:'+$icon+',ChatGPT-Switcher.ico'),
  ('/resource:'+$license+',LICENSE'),$launcher
)
& $compiler @arguments
if($LASTEXITCODE -ne 0) { throw 'Executable compilation failed.' }
Write-Host ('Built '+$output)
Get-FileHash -LiteralPath $output -Algorithm SHA256
