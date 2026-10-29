#Requires -Version 5.1
[CmdletBinding()]
param(
    [string]$InputFile,
    [string]$OutputFile,
    [switch]$Preview,
    [double]$Start = 180,
    [double]$Seconds = 20,
    [double]$Strength = 0.75,
    [int]$Tile = 256,
    [int]$Halo = 32,
    [int]$Device = 0,
    [int]$CQ = 18,
    [ValidateSet('tensorrt', 'torch')][string]$Backend = 'tensorrt',
    [ValidateSet('fp16', 'fp32')][string]$Precision = 'fp16',
    [switch]$Color,
    [switch]$Doctor,
    [switch]$Prepare
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    $root = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [IO.Path]::GetDirectoryName($PSCommandPath) }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).ProviderPath }
    $python = Join-Path $root '.venv\Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $python)) { throw 'Run Install.ps1 first.' }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $arguments = @('-u', (Join-Path $root 'app.py'), '--backend', $Backend, '--precision', $Precision,
        '--strength', $Strength.ToString($culture), '--tile', [string]$Tile, '--halo', [string]$Halo,
        '--device', [string]$Device, '--cq', [string]$CQ)
    if ($InputFile) { $arguments += @('--input', $InputFile) }
    if ($OutputFile) { $arguments += @('--output', $OutputFile) }
    if ($Color) { $arguments += '--color' }
    if ($Doctor) { $arguments += '--doctor' }
    if ($Prepare) { $arguments += '--prepare' }
    if ($Preview) { $arguments += @('--start', $Start.ToString($culture), '--seconds', $Seconds.ToString($culture)) }
    & $python @arguments
    if ($LASTEXITCODE -ne 0) { throw "Nostalgia4K stopped with exit code $LASTEXITCODE." }
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
