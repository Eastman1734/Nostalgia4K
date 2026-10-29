#Requires -Version 5.1
param([switch]$Setup)
$ErrorActionPreference = 'Stop'
try {
    if ($env:OS -ne 'Windows_NT') { throw 'Nostalgia4K Desktop requires Windows.' }
    $target = if ($Setup) { 'Setup.ps1' } else { 'Desktop.ps1' }
    & (Join-Path $PSScriptRoot $target)
}
catch {
    $log = Join-Path $PSScriptRoot 'startup-error.log'
    $_ | Out-String | Out-File -LiteralPath $log -Encoding utf8
    Add-Type -AssemblyName System.Windows.Forms
    $null = [Windows.Forms.MessageBox]::Show(('Не удалось открыть Nostalgia4K.' + [Environment]::NewLine + $_.Exception.Message + [Environment]::NewLine + 'Журнал: ' + $log), 'Nostalgia4K', 'OK', 'Error')
}
