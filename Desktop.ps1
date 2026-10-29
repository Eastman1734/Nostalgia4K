#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:AppDirectory = $PSScriptRoot
. (Join-Path $script:AppDirectory 'WindowsUI.ps1')
$script:Python = Join-Path $script:AppDirectory '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $script:Python)) {
    & (Join-Path $script:AppDirectory 'Setup.ps1')
    exit
}
$script:State = @{ Job = $null; Mode = ''; Source = ''; Meta = $null; Result = ''; LastError = ''; OutputManual = $false; AudioMode = 'copy' }
$script:Log = [Text.StringBuilder]::new()
$script:RememberedSource = ''
$window = New-N4KWindow -Title 'Nostalgia4K — восстановление видео' -Width 1100 -Height 900
$script:Form, $root = $window.Form, $window.Root

$header = New-N4KTable -Columns 2
$header.ColumnStyles[0].Width = 65
$header.ColumnStyles[1].Width = 35
$header.RowCount = 2
$header.Controls.Add((New-N4KLabel 'Nostalgia4K' -Size 26 -Bold), 0, 0)
$header.Controls.Add((New-N4KLabel 'Новая чёткость. Знакомое настроение.' -Muted), 0, 1)
$script:GpuLabel = New-N4KLabel 'NVIDIA RTX  ·  локальная обработка' -Muted
$script:GpuLabel.TextAlign = 'MiddleRight'
$header.Controls.Add($script:GpuLabel, 1, 0)
$header.SetRowSpan($script:GpuLabel, 2)
Add-N4KRow $root $header

$script:SourceCard = New-N4KTable -Card
Add-N4KRow $script:SourceCard (New-N4KLabel '01  Исходное видео' -Bold)
$sourceRow = New-N4KTable -Columns 2
$sourceRow.BackColor = $script:C.Card
$sourceRow.ColumnStyles[0].SizeType = 'Percent'
$sourceRow.ColumnStyles[0].Width = 100
$sourceRow.ColumnStyles[1].SizeType = 'AutoSize'
$script:SourceField = New-N4KField -ReadOnly -Text 'Выберите видео или перетащите файл в окно'
$script:Browse = New-N4KButton 'Выбрать файл…'
$sourceRow.Controls.Add($script:SourceField, 0, 0)
$sourceRow.Controls.Add($script:Browse, 1, 0)
Add-N4KRow $script:SourceCard $sourceRow
$script:SourceInfo = New-N4KLabel 'Поддерживаются MP4, MKV, MOV и другие форматы SDR-видео.' -Muted
Add-N4KRow $script:SourceCard $script:SourceInfo
Add-N4KRow $root $script:SourceCard

$script:Settings = New-N4KTable -Card
Add-N4KRow $script:Settings (New-N4KLabel '02  Каким будет результат' -Bold)
$choices = New-N4KTable -Columns 3
$choices.BackColor = $script:C.Card
$choices.RowCount = 3
foreach ($entry in @(@(0, 'Изображение'), @(1, 'Разрешение'), @(2, 'Качество сжатия'))) {
    $choices.Controls.Add((New-N4KLabel $entry[1] -Muted), [int]$entry[0], 0)
}
$script:Color = New-N4KCombo -Items @('Цветное', 'Чёрно-белое')
$script:Resolution = New-N4KCombo -Items @('4К · до 3840 × 2160', '1440p · до 2560 × 1440', '1080p · до 1920 × 1080', 'Размер исходника', 'Увеличить ровно в 2 раза')
$script:Quality = New-N4KCombo -Items @('Высокое · рекомендуется', 'Компактный файл', 'Очень высокое · больше файл')
$choices.Controls.Add($script:Color, 0, 1)
$choices.Controls.Add($script:Resolution, 1, 1)
$choices.Controls.Add($script:Quality, 2, 1)
$choices.Controls.Add((New-N4KLabel 'Ч/б — оттенки серого, как на старом ТВ.' -Muted -Size 9), 0, 2)
$choices.Controls.Add((New-N4KLabel 'Пропорции кадра сохраняются.' -Muted -Size 9), 1, 2)
$choices.Controls.Add((New-N4KLabel 'Меняет сжатие и размер файла.' -Muted -Size 9), 2, 2)
Add-N4KRow $script:Settings $choices
$script:OutputInfo = New-N4KLabel 'ИИ-восстановление ×2. Частота кадров и звук сохраняются.' -Muted
Add-N4KRow $script:Settings $script:OutputInfo
Add-N4KRow $root $script:Settings

$script:Details = New-N4KTable -Columns 2 -Card
$script:Details.RowCount = 4
$script:StrengthLabel = New-N4KLabel 'Сила ИИ · 75%' -Bold
$script:Details.Controls.Add($script:StrengthLabel, 0, 0)
$script:Details.Controls.Add((New-N4KLabel 'Короткая проба' -Bold), 1, 0)
$script:Strength = [Windows.Forms.TrackBar]::new()
$script:Strength.Minimum = 25
$script:Strength.Maximum = 100
$script:Strength.Value = 75
$script:Strength.TickStyle = 'None'
$script:Strength.Dock = 'Fill'
$script:Strength.BackColor = $script:C.Card
$script:Strength.Margin = [Windows.Forms.Padding]::new(0, 0, 20, 0)
$script:Details.Controls.Add($script:Strength, 0, 1)
$previewOptions = [Windows.Forms.FlowLayoutPanel]::new()
$previewOptions.AutoSize = $true
$previewOptions.Dock = 'Fill'
$previewOptions.WrapContents = $false
$previewOptions.Controls.Add((New-N4KLabel 'С отметки' -Muted))
$script:StartField = New-N4KField '00:03:00'
$script:StartField.Dock = 'None'
$script:StartField.Width = 96
$script:StartField.Margin = [Windows.Forms.Padding]::new(6, 0, 10, 0)
$previewOptions.Controls.Add($script:StartField)
$script:Seconds = [Windows.Forms.NumericUpDown]::new()
$script:Seconds.Minimum = 5
$script:Seconds.Maximum = 120
$script:Seconds.Value = 20
$script:Seconds.Width = 65
$script:Seconds.BackColor = $script:C.Field
$script:Seconds.ForeColor = $script:C.Text
$previewOptions.Controls.Add($script:Seconds)
$previewOptions.Controls.Add((New-N4KLabel 'сек.' -Muted))
$script:Details.Controls.Add($previewOptions, 1, 1)
$script:Details.Controls.Add((New-N4KLabel 'Мягче  ←                             →  Больше деталей' -Muted -Size 9), 0, 2)
$script:Details.Controls.Add((New-N4KLabel 'Проверьте лица и движение перед обработкой всего видео.' -Muted -Size 9), 1, 2)
$script:LowMemory = [Windows.Forms.CheckBox]::new()
$script:LowMemory.Text = 'Экономить видеопамять'
$script:LowMemory.AutoSize = $true
$script:LowMemory.ForeColor = $script:C.Muted
$script:LowMemory.Margin = [Windows.Forms.Padding]::new(0, 8, 0, 0)
$script:Details.Controls.Add($script:LowMemory, 0, 3)
Add-N4KRow $root $script:Details

$script:OutputCard = New-N4KTable -Card
Add-N4KRow $script:OutputCard (New-N4KLabel '03  Куда сохранить' -Bold)
$folderRow = New-N4KTable -Columns 2
$folderRow.BackColor = $script:C.Card
$folderRow.ColumnStyles[0].Width = 100
$folderRow.ColumnStyles[1].SizeType = 'AutoSize'
$script:Folder = New-N4KField
$script:FolderButton = New-N4KButton 'Папка…'
$folderRow.Controls.Add($script:Folder, 0, 0)
$folderRow.Controls.Add($script:FolderButton, 1, 0)
Add-N4KRow $script:OutputCard $folderRow
Add-N4KRow $script:OutputCard (New-N4KLabel 'Создаётся отдельный MP4. Исходник и предыдущие результаты остаются целыми.' -Muted -Size 9)
Add-N4KRow $root $script:OutputCard

$progressCard = New-N4KTable -Card
$script:Status = New-N4KLabel 'Выберите видео — и начните с короткой пробы.' -Bold
$script:Progress = [Windows.Forms.ProgressBar]::new()
$script:Progress.Dock = 'Fill'
$script:Progress.Height = 10
$script:Progress.Margin = [Windows.Forms.Padding]::new(0, 4, 0, 8)
$script:Progress.Minimum = 0
$script:Progress.Maximum = 100
$script:Stats = New-N4KLabel 'Видео обрабатывается на вашем компьютере.' -Muted -Size 9
Add-N4KRow $progressCard $script:Status
Add-N4KRow $progressCard $script:Progress
Add-N4KRow $progressCard $script:Stats
$bottom = New-N4KTable
$bottom.Dock = 'Bottom'
$bottom.Padding = [Windows.Forms.Padding]::new(24, 8, 24, 16)
$bottom.Margin = [Windows.Forms.Padding]::new(0)
Add-N4KRow $bottom $progressCard

$footer = [Windows.Forms.FlowLayoutPanel]::new()
$footer.AutoSize = $true
$footer.Dock = 'Fill'
$footer.WrapContents = $true
$script:Run = New-N4KButton 'Обработать видео' -Primary
$script:Preview = New-N4KButton 'Проба · 20 секунд'
$script:Stop = New-N4KButton 'Остановить'
$script:OpenResult = New-N4KButton 'Открыть результат'
$logButton = New-N4KButton 'Журнал'
foreach ($control in @($script:Run, $script:Preview, $script:Stop, $script:OpenResult, $logButton)) { $footer.Controls.Add($control) }
Add-N4KRow $bottom $footer
$script:Form.Controls.Add($bottom)
$window.Scroll.BringToFront()
$script:OpenResult.Enabled = $false
$script:Stop.Enabled = $false
$script:Run.Enabled = $false
$script:Preview.Enabled = $false

function Get-ResolutionKey { return @('2160p', '1440p', '1080p', 'source', '2x')[$script:Resolution.SelectedIndex] }
function Get-QualityValues {
    switch ($script:Quality.SelectedIndex) {
        1 { return @{ CQ = 22; Preset = 'p5' } }
        2 { return @{ CQ = 15; Preset = 'p7' } }
        default { return @{ CQ = 18; Preset = 'p7' } }
    }
}
function Get-PreviewStart {
    $value = $script:StartField.Text.Trim()
    if ($value -notmatch '^(\d{1,2}):([0-5]\d):([0-5]\d)$') { throw 'Укажите начало пробы в формате ЧЧ:ММ:СС, например 00:03:00.' }
    return [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]
}
function Update-N4KSummary {
    if ($null -ne $script:State.Meta) {
        $size = $script:State.Meta.outputs.PSObject.Properties[(Get-ResolutionKey)].Value
        $audio = if (-not $script:State.Meta.audio) { 'без звука' } elseif ($script:State.AudioMode -eq 'aac') { 'звук AAC' } else { 'исходный звук' }
        $script:OutputInfo.Text = ('Результат: {0} × {1} · {2:0.###} кадр/с · {3}' -f $size[0], $size[1], $script:State.Meta.fps, $audio)
    }
    $script:StrengthLabel.Text = 'Сила ИИ · ' + $script:Strength.Value + '%'
    $script:Preview.Text = 'Проба · ' + $script:Seconds.Value + ' секунд'
}
function Update-N4KButtons {
    $busy = $null -ne $script:State.Job
    foreach ($control in @($script:Browse, $script:Settings, $script:Details, $script:OutputCard)) { $control.Enabled = -not $busy }
    $ready = -not $busy -and $null -ne $script:State.Meta
    $script:Run.Enabled = $ready
    $script:Preview.Enabled = $ready
    $script:Stop.Enabled = $busy
    $script:OpenResult.Enabled = -not $busy -and -not [string]::IsNullOrWhiteSpace($script:State.Result) -and (Test-Path -LiteralPath $script:State.Result)
}
function Add-DesktopLog {
    param([string]$Line)
    $null = $script:Log.AppendLine($Line)
    if ($script:Log.Length -gt 500000) { $null = $script:Log.Remove(0, $script:Log.Length - 400000) }
    if ($Line.StartsWith('@@N4K@@')) {
        try { $event = $Line.Substring(7) | ConvertFrom-Json } catch { return }
        switch ($event.type) {
            'metadata' {
                $script:State.Meta = $event
                $unsupportedAudio = @($event.audio_codecs | Where-Object { $_ -notin @('aac', 'mp3', 'alac') })
                $script:State.AudioMode = if ($unsupportedAudio.Count -gt 0) { 'aac' } else { 'copy' }
                $time = ([TimeSpan]::FromSeconds($event.duration)).ToString('hh\:mm\:ss')
                $script:SourceInfo.Text = ('{0} × {1} · {2:0.###} кадр/с · {3}' -f $event.width, $event.height, $event.fps, $time)
                try { if ((Get-PreviewStart) -ge $event.duration) { $script:StartField.Text = '00:00:00' } }
                catch { $script:StartField.Text = '00:00:00' }
                Update-N4KSummary
            }
            'gpu' { $script:GpuLabel.Text = $event.name + ' · ' + $event.vram + ' ГБ' }
            'stage' {
                $messages = @{
                    checking = 'Проверяем видеокарту…'; model_download = 'Загружаем модель ИИ…'; engine = 'Подготавливаем нейросеть…'
                    export = 'Подготавливаем модель…'; engine_load = 'Загружаем готовую модель…'
                    engine_build = 'Оптимизируем модель для вашей RTX…'; processing = 'Восстанавливаем видео…'; finalizing = 'Завершаем сохранение MP4…'
                }
                $script:Status.Text = if ($messages.ContainsKey($event.name)) { $messages[$event.name] } else { 'Подготовка…' }
                $script:Progress.Style = 'Marquee'
                if ($event.name -eq 'engine_build') { $script:Stats.Text = 'Первый запуск может занять несколько минут. Следующие используют готовый кэш.' }
            }
            'warmup' { $script:Status.Text = 'Обрабатываем первый кадр…'; $script:Stats.Text = 'Часть ' + $event.current + ' из ' + $event.total + ' · прошло ' + $event.elapsed }
            'progress' {
                $script:Progress.Style = 'Blocks'
                $script:Progress.Value = [Math]::Min(100, [Math]::Max(0, [int]$event.percent))
                $script:Status.Text = ('Обработано {0:0.0}%' -f $event.percent)
                $script:Stats.Text = ('{0:0.00} кадр/с · осталось ~{1} · прошло {2}' -f $event.fps, $event.eta, $event.elapsed)
            }
            'done' {
                $script:State.Result = [string]$event.path
                $script:Progress.Style = 'Blocks'
                $script:Progress.Value = 100
                $script:Status.Text = 'Готово — видео сохранено.'
                $script:Stats.Text = 'Время обработки: ' + $event.elapsed
            }
            'error' { $script:State.LastError = [string]$event.message }
        }
    }
}
function Start-DesktopWorker {
    param([string[]]$Arguments, [string]$Mode)
    if ($null -ne $script:State.Job) { return }
    $script:State.Mode = $Mode
    $script:State.LastError = ''
    $null = $script:Log.Clear()
    $script:State.Job = Start-N4KProcess $script:Python (@('-u', (Join-Path $script:AppDirectory 'app.py'), '--events') + $Arguments) $script:AppDirectory
    $script:Progress.Style = 'Marquee'
    Update-N4KButtons
}
function Set-DesktopSource {
    param([string]$Path)
    if ($null -ne $script:State.Job) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Видео не найдено.' }
    $script:State.Source = [IO.Path]::GetFullPath($Path)
    $script:State.Meta = $null
    $script:SourceField.Text = $script:State.Source
    if (-not $script:State.OutputManual) { $script:Folder.Text = [IO.Path]::GetDirectoryName($script:State.Source) }
    $script:SourceInfo.Text = 'Читаем сведения о видео…'
    $script:Status.Text = 'Открываем исходное видео…'
    Start-DesktopWorker -Arguments @('--inspect', '--input', $script:State.Source) -Mode 'inspect'
}
function Start-DesktopConversion {
    param([bool]$IsPreview)
    if ($null -eq $script:State.Meta) { throw 'Сначала выберите видео.' }
    $folder = $script:Folder.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($folder)) { throw 'Выберите папку для сохранения.' }
    $null = New-Item -ItemType Directory -Path $folder -Force
    $quality = Get-QualityValues
    $resolution = Get-ResolutionKey
    $color = if ($script:Color.SelectedIndex -eq 0) { 'color' } else { 'bw' }
    $stem = [IO.Path]::GetFileNameWithoutExtension($script:State.Source)
    if ($stem.Length -gt 140) { $stem = $stem.Substring(0, 140).TrimEnd() }
    $suffix = '_ai4k_' + $resolution + '_' + $color + '_q' + $quality.CQ
    if ($IsPreview) { $suffix += '_preview' }
    $output = Join-Path $folder ($stem + $suffix + '.mp4')
    $number = 2
    while (Test-Path -LiteralPath $output) { $output = Join-Path $folder ($stem + $suffix + '_' + $number + '.mp4'); $number++ }
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $arguments = @('--input', $script:State.Source, '--output', $output, '--resolution', $resolution,
                   '--cq', [string]$quality.CQ, '--preset', $quality.Preset,
                   '--audio-codec', $script:State.AudioMode,
                   '--strength', (($script:Strength.Value / 100.0).ToString($culture)))
    if ($script:Color.SelectedIndex -eq 0) { $arguments += '--color' }
    if ($script:LowMemory.Checked) { $arguments += @('--tile', '128') }
    if ($IsPreview) {
        $start = Get-PreviewStart
        if ($start -ge $script:State.Meta.duration) { throw 'Начало пробы находится за концом видео.' }
        $arguments += @('--start', [string]$start, '--seconds', [string]$script:Seconds.Value)
    }
    $script:Status.Text = 'Запускаем обработку…'
    $script:Stats.Text = 'Результат: ' + [IO.Path]::GetFileName($output)
    $script:State.Result = ''
    Start-DesktopWorker $arguments 'convert'
    Save-DesktopPreferences
}

function Save-DesktopPreferences {
    try {
        @{ input = $script:State.Source; folder = $script:Folder.Text; color = $script:Color.SelectedIndex;
           resolution = $script:Resolution.SelectedIndex; quality = $script:Quality.SelectedIndex;
           strength = $script:Strength.Value; seconds = [int]$script:Seconds.Value; start = $script:StartField.Text;
           lowMemory = $script:LowMemory.Checked; outputManual = $script:State.OutputManual } |
            ConvertTo-Json | Out-File -LiteralPath (Join-Path $script:AppDirectory 'desktop-settings.json') -Encoding utf8
    } catch { $null = $script:Log.AppendLine('Settings: ' + $_.Exception.Message) }
}

$script:Browse.Add_Click({
    try {
        $dialog = [Windows.Forms.OpenFileDialog]::new()
        $dialog.Title = 'Выберите исходное видео'
        $dialog.Filter = 'Видео|*.mp4;*.mkv;*.mov;*.avi;*.webm;*.ts;*.m4v;*.flv|Все файлы|*.*'
        if ($dialog.ShowDialog() -eq 'OK') { Set-DesktopSource $dialog.FileName }
        $dialog.Dispose()
    } catch { Show-N4KError $_.Exception.Message }
})
$script:FolderButton.Add_Click({
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = 'Папка для готового видео'
    if (-not [string]::IsNullOrWhiteSpace($script:Folder.Text) -and (Test-Path -LiteralPath $script:Folder.Text -PathType Container)) { $dialog.SelectedPath = $script:Folder.Text }
    if ($dialog.ShowDialog() -eq 'OK') { $script:Folder.Text = $dialog.SelectedPath; $script:State.OutputManual = $true }
    $dialog.Dispose()
})
$script:Resolution.Add_SelectedIndexChanged({ Update-N4KSummary })
$script:Folder.Add_TextChanged({ if ($script:Folder.Focused) { $script:State.OutputManual = $true } })
$script:Strength.Add_ValueChanged({ Update-N4KSummary })
$script:Seconds.Add_ValueChanged({ Update-N4KSummary })
$script:Run.Add_Click({ try { Start-DesktopConversion $false } catch { Show-N4KError $_.Exception.Message } })
$script:Preview.Add_Click({ try { Start-DesktopConversion $true } catch { Show-N4KError $_.Exception.Message } })
$script:Stop.Add_Click({ Stop-N4KProcess $script:State.Job; $script:Stop.Enabled = $false; $script:Status.Text = 'Останавливаем обработку…' })
$script:OpenResult.Add_Click({ if ($script:State.Result -and (Test-Path -LiteralPath $script:State.Result)) { Invoke-Item -LiteralPath $script:State.Result } })
$logButton.Add_Click({ Show-N4KLog $script:Log.ToString() })
$script:Form.AllowDrop = $true
$script:Form.Add_DragEnter({ if ($null -eq $script:State.Job -and $_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop)) { $_.Effect = 'Copy' } })
$script:Form.Add_DragDrop({ try { $files = @($_.Data.GetData([Windows.Forms.DataFormats]::FileDrop)); if ($files.Count -gt 0) { Set-DesktopSource $files[0] } } catch { Show-N4KError $_.Exception.Message } })
$script:Form.Add_FormClosing({
    if ($null -ne $script:State.Job) {
        $answer = [Windows.Forms.MessageBox]::Show('Остановить текущую обработку и закрыть приложение?', 'Nostalgia4K', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { $_.Cancel = $true; return }
        Stop-N4KProcess $script:State.Job
    }
    Save-DesktopPreferences
})
$script:Timer = [Windows.Forms.Timer]::new()
$script:Timer.Interval = 150
$script:Timer.Add_Tick({
    if ($null -eq $script:State.Job) { return }
    try {
        if (Read-N4KProcess $script:State.Job { param($line) Add-DesktopLog $line }) {
            $job = $script:State.Job
            $mode = $script:State.Mode
            $code = $job.Process.ExitCode
            $script:State.Job = $null
            $script:Progress.Style = 'Blocks'
            if ($job.Cancelled) {
                $script:Status.Text = 'Обработка остановлена.'
                $script:Stats.Text = 'Можно выбрать другие настройки и запустить заново.'
            } elseif ($code -ne 0) {
                $script:Status.Text = 'Обработка не завершена. Откройте журнал.'
                $script:Stats.Text = if ($script:State.LastError) { $script:State.LastError } else { 'Код завершения: ' + $code }
                if ($mode -eq 'inspect') { $script:State.Meta = $null; $script:SourceInfo.Text = 'Не удалось прочитать видео. Подробности — в журнале.' }
            } elseif ($mode -eq 'inspect') {
                $script:Status.Text = 'Видео готово. Рекомендуем начать с пробы.'
                $script:Stats.Text = 'Первый запуск подготовит нейросеть для вашей RTX.'
            } elseif (-not $script:State.Result) {
                $script:Status.Text = 'Не получено подтверждение сохранения. Проверьте журнал.'
            }
            $script:Log.ToString() | Out-File -LiteralPath (Join-Path $script:AppDirectory 'desktop-latest.log') -Encoding utf8
            $job.Process.Dispose()
            Update-N4KButtons
        }
    } catch {
        Stop-N4KProcess $script:State.Job
        $script:State.Job = $null
        $script:Status.Text = 'Ошибка интерфейса: ' + $_.Exception.Message
        Update-N4KButtons
    }
})
$script:Timer.Start()
try {
    $config = Join-Path $script:AppDirectory 'desktop-settings.json'
    if (Test-Path -LiteralPath $config) {
        $preferences = Get-Content -LiteralPath $config -Raw -Encoding utf8 | ConvertFrom-Json
        $script:Color.SelectedIndex = [Math]::Min(1, [Math]::Max(0, [int]$preferences.color))
        $script:Resolution.SelectedIndex = [Math]::Min(4, [Math]::Max(0, [int]$preferences.resolution))
        $script:Quality.SelectedIndex = [Math]::Min(2, [Math]::Max(0, [int]$preferences.quality))
        $script:Strength.Value = [Math]::Min(100, [Math]::Max(25, [int]$preferences.strength))
        $script:Seconds.Value = [Math]::Min(120, [Math]::Max(5, [int]$preferences.seconds))
        $script:StartField.Text = [string]$preferences.start
        $script:LowMemory.Checked = [bool]$preferences.lowMemory
        $script:Folder.Text = [string]$preferences.folder
        $script:State.OutputManual = [bool]$preferences.outputManual
        $script:RememberedSource = [string]$preferences.input
    }
} catch { $null = $script:Log.AppendLine('Settings ignored: ' + $_.Exception.Message) }
$script:Form.Add_Shown({
    if (-not [string]::IsNullOrWhiteSpace($script:RememberedSource) -and (Test-Path -LiteralPath $script:RememberedSource -PathType Leaf)) {
        try { Set-DesktopSource $script:RememberedSource } catch { Show-N4KError $_.Exception.Message }
        return
    }
    foreach ($folder in @((Join-Path (Split-Path $script:AppDirectory -Parent) 'videos'), 'C:\downloads\videos')) {
        if (Test-Path -LiteralPath $folder -PathType Container) {
            $files = @(Get-ChildItem -LiteralPath $folder -File | Where-Object {
                $_.Extension -eq '.mp4' -and $_.BaseName -notmatch '(_bw|_ai4k)' -and $_.Name -notlike '*.part.*'
            })
            if ($files.Count -eq 1) { try { Set-DesktopSource $files[0].FullName } catch { Show-N4KError $_.Exception.Message }; break }
        }
    }
})
try { [Windows.Forms.Application]::Run($script:Form) }
finally { $script:Timer.Stop(); $script:Timer.Dispose(); $script:Form.Dispose() }
