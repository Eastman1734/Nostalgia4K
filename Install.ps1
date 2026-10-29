#Requires -Version 5.1
[CmdletBinding()]
param([switch]$MachineEvents)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ($MachineEvents) { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) }
function Write-InstallPhase {
    param([string]$Name, [int]$Percent)
    if ($MachineEvents) { Write-Output ('@@N4K@@' + (@{ type = 'install'; name = $Name; percent = $Percent } | ConvertTo-Json -Compress)) }
}

function Run-Checked {
    param([string]$Program, [string[]]$Arguments)
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Program @Arguments
        $resultCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $oldPreference }
    if ($resultCode -ne 0) { throw "$Program failed (exit code $resultCode)." }
}

try {
    Write-InstallPhase 'checking' 5
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitOperatingSystem) {
        throw 'This application requires Windows x64 and an NVIDIA RTX GPU.'
    }
    $root = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($root)) { $root = [IO.Path]::GetDirectoryName($PSCommandPath) }
    if ([string]::IsNullOrWhiteSpace($root)) { $root = (Get-Location).ProviderPath }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $python = $null
    Write-InstallPhase 'python' 12
    $launcher = Get-Command py.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($launcher) {
        foreach ($version in @('-3.12', '-3.11')) {
            $oldPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $candidate = & $launcher.Path $version -c 'import sys; print(sys.executable)' 2>$null
                $resultCode = $LASTEXITCODE
            }
            finally { $ErrorActionPreference = $oldPreference }
            if ($resultCode -eq 0 -and $candidate) { $python = [string]$candidate; break }
        }
    }
    if (-not $python) {
        foreach ($version in @('Python312', 'Python311')) {
            $candidate = Join-Path $env:LOCALAPPDATA "Programs\Python\$version\python.exe"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $python = $candidate; break }
        }
    }
    if (-not $python) {
        $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue
        if (-not $winget) { throw 'Install Python 3.12 x64 from python.org, then run Install.ps1 again.' }
        Write-Host 'Installing Python 3.12 for the current user...'
        Run-Checked -Program $winget.Path -Arguments @('install', '--id', 'Python.Python.3.12', '--exact', '--source', 'winget', '--scope', 'user', '--silent', '--accept-package-agreements', '--accept-source-agreements')
        $python = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python312\python.exe'
        if (-not (Test-Path -LiteralPath $python)) { throw 'Python installed in a different folder. Reopen PowerShell and run Install.ps1 again.' }
    }
    $environment = Join-Path $root '.venv'
    $venvPython = Join-Path $environment 'Scripts\python.exe'
    if (-not (Test-Path -LiteralPath $venvPython)) {
        Run-Checked -Program $python -Arguments @('-m', 'venv', $environment)
    }
    Write-Host 'Installing PyTorch CUDA 12.8 and TensorRT. Downloads can total several GB.'
    Write-InstallPhase 'environment' 23
    Run-Checked -Program $venvPython -Arguments @('-m', 'pip', 'install', '--upgrade', 'pip', 'wheel', 'setuptools')
    Write-InstallPhase 'torch' 35
    Run-Checked -Program $venvPython -Arguments @('-m', 'pip', 'install', 'torch==2.8.0', '--index-url', 'https://download.pytorch.org/whl/cu128')
    Write-InstallPhase 'tensorrt' 55
    Run-Checked -Program $venvPython -Arguments @('-m', 'pip', 'install', '-r', (Join-Path $root 'requirements.txt'))

    $tools = Join-Path $root 'tools'
    $null = New-Item -ItemType Directory -Path $tools -Force
    $ffmpeg = Join-Path $tools 'ffmpeg.exe'
    $ffprobe = Join-Path $tools 'ffprobe.exe'
    Write-InstallPhase 'tools' 75
    if (-not (Test-Path -LiteralPath $ffmpeg) -or -not (Test-Path -LiteralPath $ffprobe)) {
        $work = Join-Path $tools ([Guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $work
        try {
            Write-Host 'Downloading FFmpeg and FFprobe...'
            $url = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
            $archive = Join-Path $work 'ffmpeg.zip'
            Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $archive
            $checksum = (Invoke-WebRequest -UseBasicParsing -Uri ($url + '.sha256')).Content
            if ($checksum -is [byte[]]) { $checksum = [Text.Encoding]::UTF8.GetString($checksum) }
            $match = [regex]::Match([string]$checksum, '(?i)\b[0-9a-f]{64}\b')
            if (-not $match.Success -or (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $match.Value) {
                throw 'FFmpeg SHA256 verification failed.'
            }
            Expand-Archive -LiteralPath $archive -DestinationPath $work
            foreach ($name in @('ffmpeg.exe', 'ffprobe.exe')) {
                $found = @(Get-ChildItem -LiteralPath $work -Filter $name -Recurse -File)
                if ($found.Count -ne 1) { throw "Cannot find $name in the archive." }
                Copy-Item -LiteralPath $found[0].FullName -Destination (Join-Path $tools $name) -Force
            }
        }
        finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Write-InstallPhase 'doctor' 90
    Run-Checked -Program $venvPython -Arguments @((Join-Path $root 'app.py'), '--doctor')
    Write-InstallPhase 'complete' 100
    Write-Host 'Installed. Run Start.ps1 -Preview for a 20-second test.' -ForegroundColor Green
}
catch {
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
}
