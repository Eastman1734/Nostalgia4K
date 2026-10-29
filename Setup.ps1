#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:SourceDirectory = $PSScriptRoot
. (Join-Path $script:SourceDirectory 'WindowsUI.ps1')
$script:SetupState = @{ Job = $null; Directory = ''; Complete = $false }
$script:SetupLog = [Text.StringBuilder]::new()
$window = New-N4KWindow -Title 'Установка Nostalgia4K' -Width 900 -Height 740
$script:SetupForm, $layout = $window.Form, $window.Root
Add-N4KRow $layout (New-N4KLabel 'Nostalgia4K' -Size 28 -Bold)
Add-N4KRow $layout (New-N4KLabel 'Установка и обновление · Windows + NVIDIA RTX' -Muted)

$intro = New-N4KTable -Card
Add-N4KRow $intro (New-N4KLabel 'Ваше видео — в новом качестве' -Size 15 -Bold)
Add-N4KRow $intro (New-N4KLabel 'Цвет или ч/б · 1080p, 1440p и 4К · короткая проба перед обработкой' -Muted)
Add-N4KRow $intro (New-N4KLabel 'Программа работает локально. Видео никуда не загружается.' -Muted)
Add-N4KRow $layout $intro

$script:InstallOptions = New-N4KTable -Card
Add-N4KRow $script:InstallOptions (New-N4KLabel 'Папка программы' -Bold)
$folderRow = New-N4KTable -Columns 2
$folderRow.BackColor = $script:C.Card
$folderRow.ColumnStyles[0].Width = 100
$folderRow.ColumnStyles[1].SizeType = 'AutoSize'
$default = Join-Path $env:LOCALAPPDATA 'Programs\Nostalgia4K'
foreach ($existing in @($script:SourceDirectory, 'C:\downloads\Nostalgia4K')) {
    if (Test-Path -LiteralPath (Join-Path $existing '.venv\Scripts\python.exe')) { $default = $existing; break }
}
$script:InstallFolder = New-N4KField $default
$folderButton = New-N4KButton 'Выбрать…'
$folderRow.Controls.Add($script:InstallFolder, 0, 0)
$folderRow.Controls.Add($folderButton, 1, 0)
Add-N4KRow $script:InstallOptions $folderRow
Add-N4KRow $script:InstallOptions (New-N4KLabel 'Если программа уже установлена, выберите ту же папку: модели и зависимости сохранятся.' -Muted -Size 9)
$script:Shortcut = [Windows.Forms.CheckBox]::new()
$script:Shortcut.Text = 'Создать ярлык на рабочем столе'
$script:Shortcut.Checked = $true
$script:Shortcut.AutoSize = $true
$script:Shortcut.Margin = [Windows.Forms.Padding]::new(0, 8, 0, 8)
Add-N4KRow $script:InstallOptions $script:Shortcut
Add-N4KRow $layout $script:InstallOptions

$progressCard = New-N4KTable -Card
$script:SetupStatus = New-N4KLabel 'Готово к установке' -Size 13 -Bold
$script:SetupProgress = [Windows.Forms.ProgressBar]::new()
$script:SetupProgress.Dock = 'Fill'
$script:SetupProgress.Height = 12
$script:SetupProgress.Margin = [Windows.Forms.Padding]::new(0, 6, 0, 10)
$script:SetupHint = New-N4KLabel 'При первой установке потребуется интернет и несколько гигабайт для библиотек NVIDIA.' -Muted
Add-N4KRow $progressCard $script:SetupStatus
Add-N4KRow $progressCard $script:SetupProgress
Add-N4KRow $progressCard $script:SetupHint
Add-N4KRow $layout $progressCard

$buttons = [Windows.Forms.FlowLayoutPanel]::new()
$buttons.AutoSize = $true
$buttons.Dock = 'Fill'
$script:InstallButton = New-N4KButton 'Установить / обновить' -Primary
$script:CancelInstall = New-N4KButton 'Отменить'
$script:OpenApp = New-N4KButton 'Открыть Nostalgia4K' -Primary
$setupLogButton = New-N4KButton 'Журнал'
$script:CancelInstall.Enabled = $false
$script:OpenApp.Visible = $false
foreach ($control in @($script:InstallButton, $script:CancelInstall, $script:OpenApp, $setupLogButton)) { $buttons.Controls.Add($control) }
Add-N4KRow $layout $buttons

function Start-N4KDesktop {
    param([string]$Directory)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $info.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ' + (Quote-N4KArgument (Join-Path $Directory 'Launcher.ps1'))
    $info.WorkingDirectory = $Directory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $null = [Diagnostics.Process]::Start($info)
}
function Add-SetupLog {
    param([string]$Line)
    $null = $script:SetupLog.AppendLine($Line)
    if ($script:SetupLog.Length -gt 500000) { $null = $script:SetupLog.Remove(0, $script:SetupLog.Length - 400000) }
    if ($Line.StartsWith('@@N4K@@')) {
        try { $event = $Line.Substring(7) | ConvertFrom-Json } catch { return }
        if ($event.type -eq 'install') {
            $messages = @{
                checking = 'Проверяем систему…'; python = 'Подготавливаем Python…'; environment = 'Подготавливаем окружение…'
                torch = 'Устанавливаем PyTorch и CUDA…'; tensorrt = 'Устанавливаем NVIDIA TensorRT…'
                tools = 'Подготавливаем обработку видео…'; doctor = 'Проверяем CUDA, TensorRT и NVENC…'; complete = 'Установка завершена'
            }
            $script:SetupProgress.Style = 'Blocks'
            $script:SetupProgress.Value = [Math]::Min(100, [Math]::Max(0, [int]$event.percent))
            if ($messages.ContainsKey($event.name)) { $script:SetupStatus.Text = $messages[$event.name] }
            $script:SetupHint.Text = 'Окно остаётся доступным. Загрузка больших библиотек может занять несколько минут.'
        }
    }
}
function Install-N4KFiles {
    $target = [IO.Path]::GetFullPath($script:InstallFolder.Text.Trim())
    if (Test-Path -LiteralPath $target -PathType Leaf) { throw 'Выберите папку, а не файл.' }
    $null = New-Item -ItemType Directory -Path $target -Force
    $files = @('app.py', 'core.py', 'gpu.py', 'sr_model.py', 'events.py', 'requirements.txt',
               'Install.ps1', 'Start.ps1', 'WindowsUI.ps1', 'Desktop.ps1', 'Setup.ps1', 'Launcher.ps1',
               'Setup.cmd', 'Start.cmd', 'README.md', 'README-RU.md', 'LICENSE', 'NOTICE', 'LICENSE-BasicSR.txt', 'LICENSE-RealESRGAN.txt', 'VALIDATION.txt')
    foreach ($name in $files) {
        $source = Join-Path $script:SourceDirectory $name
        $destination = Join-Path $target $name
        if (-not (Test-Path -LiteralPath $source)) { throw "В архиве отсутствует файл: $name. Распакуйте архив целиком." }
        if ([IO.Path]::GetFullPath($source) -ne [IO.Path]::GetFullPath($destination)) {
            Copy-Item -LiteralPath $source -Destination $destination -Force
        }
    }
    return $target
}

$folderButton.Add_Click({
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = 'Папка установки Nostalgia4K'
    if (-not [string]::IsNullOrWhiteSpace($script:InstallFolder.Text) -and (Test-Path -LiteralPath $script:InstallFolder.Text -PathType Container)) { $dialog.SelectedPath = $script:InstallFolder.Text }
    if ($dialog.ShowDialog() -eq 'OK') { $script:InstallFolder.Text = $dialog.SelectedPath }
    $dialog.Dispose()
})
$script:InstallButton.Add_Click({
    try {
        $null = $script:SetupLog.Clear()
        $script:SetupState.Directory = Install-N4KFiles
        $script:InstallOptions.Enabled = $false
        $script:InstallButton.Enabled = $false
        $script:CancelInstall.Enabled = $true
        $script:SetupStatus.Text = 'Начинаем установку…'
        $script:SetupProgress.Style = 'Marquee'
        $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $script:SetupState.Job = Start-N4KProcess $powershell @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:SetupState.Directory 'Install.ps1'), '-MachineEvents') $script:SetupState.Directory
    } catch {
        $script:InstallOptions.Enabled = $true
        $script:InstallButton.Enabled = $true
        $script:CancelInstall.Enabled = $false
        Show-N4KError $_.Exception.Message
    }
})
$script:CancelInstall.Add_Click({ Stop-N4KProcess $script:SetupState.Job; $script:CancelInstall.Enabled = $false; $script:SetupStatus.Text = 'Останавливаем установку…' })
$setupLogButton.Add_Click({ Show-N4KLog $script:SetupLog.ToString() })
$script:OpenApp.Add_Click({ Start-N4KDesktop $script:SetupState.Directory; $script:SetupForm.Close() })
$script:SetupForm.Add_FormClosing({
    if ($null -ne $script:SetupState.Job) {
        $answer = [Windows.Forms.MessageBox]::Show('Остановить установку и закрыть окно?', 'Nostalgia4K', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { $_.Cancel = $true; return }
        Stop-N4KProcess $script:SetupState.Job
    }
})
$script:SetupTimer = [Windows.Forms.Timer]::new()
$script:SetupTimer.Interval = 150
$script:SetupTimer.Add_Tick({
    if ($null -eq $script:SetupState.Job) { return }
    try {
        if (Read-N4KProcess $script:SetupState.Job { param($line) Add-SetupLog $line }) {
            $job = $script:SetupState.Job
            $code = $job.Process.ExitCode
            $script:SetupState.Job = $null
            $script:SetupProgress.Style = 'Blocks'
            $script:CancelInstall.Enabled = $false
            $script:SetupLog.ToString() | Out-File -LiteralPath (Join-Path $script:SetupState.Directory 'install.log') -Encoding utf8
            if ($job.Cancelled) {
                $script:SetupStatus.Text = 'Установка остановлена'
                $script:SetupHint.Text = 'Нажмите «Установить / обновить», чтобы повторить.'
                $script:InstallOptions.Enabled = $true
                $script:InstallButton.Enabled = $true
            } elseif ($code -ne 0) {
                $script:SetupStatus.Text = 'Установка не завершена'
                $script:SetupHint.Text = 'Откройте журнал: там указан этап и причина ошибки.'
                $script:InstallOptions.Enabled = $true
                $script:InstallButton.Enabled = $true
            } else {
                if ($script:Shortcut.Checked) {
                    $shell = New-Object -ComObject WScript.Shell
                    $shortcutPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Nostalgia4K.lnk'
                    $link = $shell.CreateShortcut($shortcutPath)
                    $link.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    $link.Arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File ' + (Quote-N4KArgument (Join-Path $script:SetupState.Directory 'Launcher.ps1'))
                    $link.WorkingDirectory = $script:SetupState.Directory
                    $link.Description = 'Нейросетевое восстановление и увеличение видео'
                    $link.Save()
                }
                $script:SetupState.Complete = $true
                $script:SetupStatus.Text = 'Всё готово!'
                $script:SetupHint.Text = 'Откройте приложение, выберите видео и начните с короткой пробы.'
                $script:SetupProgress.Value = 100
                $script:InstallButton.Visible = $false
                $script:CancelInstall.Visible = $false
                $script:OpenApp.Visible = $true
            }
            $job.Process.Dispose()
        }
    } catch {
        Stop-N4KProcess $script:SetupState.Job
        $script:SetupState.Job = $null
        $script:InstallOptions.Enabled = $true
        $script:InstallButton.Enabled = $true
        $script:SetupStatus.Text = 'Ошибка: ' + $_.Exception.Message
    }
})
$script:SetupTimer.Start()
try { [Windows.Forms.Application]::Run($script:SetupForm) }
finally { $script:SetupTimer.Stop(); $script:SetupTimer.Dispose(); $script:SetupForm.Dispose() }
