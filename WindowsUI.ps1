# Shared Windows Forms helpers. Windows PowerShell 5.1, no extra UI packages.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:C = @{
    Background = [Drawing.ColorTranslator]::FromHtml('#101722')
    Card = [Drawing.ColorTranslator]::FromHtml('#1A2433')
    Field = [Drawing.ColorTranslator]::FromHtml('#263346')
    Text = [Drawing.ColorTranslator]::FromHtml('#F1F5FA')
    Muted = [Drawing.ColorTranslator]::FromHtml('#A9B8CC')
    Accent = [Drawing.ColorTranslator]::FromHtml('#67D9C5')
    Dark = [Drawing.ColorTranslator]::FromHtml('#102C2B')
    Border = [Drawing.ColorTranslator]::FromHtml('#3C4E64')
}

function New-N4KLabel {
    param([string]$Text, [float]$Size = 10, [switch]$Muted, [switch]$Bold)
    $c = [Windows.Forms.Label]::new()
    $c.Text = $Text
    $c.AutoSize = $true
    $c.Dock = 'Fill'
    $c.ForeColor = if ($Muted) { $script:C.Muted } else { $script:C.Text }
    $style = if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular }
    $c.Font = [Drawing.Font]::new('Segoe UI', $Size, $style)
    $c.Margin = [Windows.Forms.Padding]::new(0, 0, 0, 7)
    return $c
}

function New-N4KTable {
    param([int]$Columns = 1, [switch]$Card)
    $c = [Windows.Forms.TableLayoutPanel]::new()
    $c.ColumnCount = $Columns
    $c.RowCount = 0
    $c.Dock = 'Top'
    $c.AutoSize = $true
    $c.AutoSizeMode = 'GrowAndShrink'
    $c.Margin = [Windows.Forms.Padding]::new(0, 0, 0, 10)
    $c.BackColor = if ($Card) { $script:C.Card } else { $script:C.Background }
    if ($Card) { $c.Padding = [Windows.Forms.Padding]::new(16) }
    for ($i = 0; $i -lt $Columns; $i++) {
        $null = $c.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, (100 / $Columns)))
    }
    return $c
}

function Add-N4KRow {
    param($Table, $Control)
    $row = $Table.RowCount
    $Table.RowCount++
    $null = $Table.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::AutoSize))
    $Table.Controls.Add($Control, 0, $row)
    if ($Table.ColumnCount -gt 1) { $Table.SetColumnSpan($Control, $Table.ColumnCount) }
}

function New-N4KButton {
    param([string]$Text, [switch]$Primary)
    $c = [Windows.Forms.Button]::new()
    $c.Text = $Text
    $c.AutoSize = $true
    $c.AutoSizeMode = 'GrowAndShrink'
    $c.MinimumSize = [Drawing.Size]::new(120, 40)
    $c.Padding = [Windows.Forms.Padding]::new(12, 6, 12, 6)
    $c.FlatStyle = 'Flat'
    $c.FlatAppearance.BorderSize = 1
    $c.FlatAppearance.BorderColor = $script:C.Border
    $c.BackColor = if ($Primary) { $script:C.Accent } else { $script:C.Field }
    $c.ForeColor = if ($Primary) { $script:C.Dark } else { $script:C.Text }
    $c.Font = [Drawing.Font]::new('Segoe UI', 10, [Drawing.FontStyle]::Bold)
    $c.Cursor = [Windows.Forms.Cursors]::Hand
    $c.Margin = [Windows.Forms.Padding]::new(0, 0, 10, 0)
    return $c
}

function New-N4KField {
    param([string]$Text = '', [switch]$ReadOnly)
    $c = [Windows.Forms.TextBox]::new()
    $c.Text = $Text
    $c.ReadOnly = $ReadOnly
    $c.Dock = 'Fill'
    $c.BorderStyle = 'FixedSingle'
    $c.BackColor = $script:C.Field
    $c.ForeColor = $script:C.Text
    $c.Font = [Drawing.Font]::new('Segoe UI', 11)
    $c.Margin = [Windows.Forms.Padding]::new(0, 6, 12, 6)
    return $c
}

function New-N4KCombo {
    param([string[]]$Items)
    $c = [Windows.Forms.ComboBox]::new()
    $c.DropDownStyle = 'DropDownList'
    $c.FlatStyle = 'Flat'
    $c.Dock = 'Fill'
    $c.BackColor = $script:C.Field
    $c.ForeColor = $script:C.Text
    $c.Font = [Drawing.Font]::new('Segoe UI', 11)
    $c.Margin = [Windows.Forms.Padding]::new(0, 6, 14, 8)
    $c.Items.AddRange([object[]]$Items)
    $c.SelectedIndex = 0
    return $c
}

function New-N4KWindow {
    param([string]$Title, [int]$Width = 1060, [int]$Height = 860)
    $form = [Windows.Forms.Form]::new()
    $form.Text = $Title
    $form.Size = [Drawing.Size]::new($Width, $Height)
    $form.MinimumSize = [Drawing.Size]::new(820, 600)
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $script:C.Background
    $form.ForeColor = $script:C.Text
    $form.Font = [Drawing.Font]::new('Segoe UI', 10)
    $form.AutoScaleDimensions = [Drawing.SizeF]::new(96, 96)
    $form.AutoScaleMode = 'Dpi'
    $scroll = [Windows.Forms.Panel]::new()
    $scroll.AutoScroll = $true
    $scroll.Dock = 'Fill'
    $form.Controls.Add($scroll)
    $root = New-N4KTable
    $root.Padding = [Windows.Forms.Padding]::new(24)
    $root.Margin = [Windows.Forms.Padding]::new(0)
    $scroll.Controls.Add($root)
    $form.Add_Shown({
        $work = [Windows.Forms.Screen]::FromControl($this).WorkingArea
        $this.MinimumSize = [Drawing.Size]::new([Math]::Min(820, $work.Width - 30), [Math]::Min(600, $work.Height - 40))
        $this.Width = [Math]::Min($this.Width, $work.Width - 30)
        $this.Height = [Math]::Min($this.Height, $work.Height - 40)
        $this.Location = [Drawing.Point]::new($work.Left + [Math]::Max(0, ($work.Width - $this.Width) / 2),
                                            $work.Top + [Math]::Max(0, ($work.Height - $this.Height) / 2))
    })
    return @{ Form = $form; Root = $root; Scroll = $scroll }
}

function Quote-N4KArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Start-N4KProcess {
    param([string]$Program, [string[]]$Arguments, [string]$WorkingDirectory)
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $Program
    $info.Arguments = (($Arguments | ForEach-Object { Quote-N4KArgument $_ }) -join ' ')
    $info.WorkingDirectory = $WorkingDirectory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [Text.Encoding]::UTF8
    $info.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    $info.EnvironmentVariables['PYTHONUNBUFFERED'] = '1'
    $info.EnvironmentVariables['PIP_PROGRESS_BAR'] = 'off'
    $p = [Diagnostics.Process]::new()
    $p.StartInfo = $info
    $null = $p.Start()
    return @{ Process = $p; OutTask = $p.StandardOutput.ReadLineAsync(); ErrTask = $p.StandardError.ReadLineAsync(); Cancelled = $false }
}

function Read-N4KProcess {
    param($Job, [scriptblock]$OnLine)
    foreach ($kind in @('Out', 'Err')) {
        $key = $kind + 'Task'
        for ($i = 0; $i -lt 60 -and $null -ne $Job[$key] -and $Job[$key].IsCompleted; $i++) {
            $line = $Job[$key].GetAwaiter().GetResult()
            if ($null -eq $line) { $Job[$key] = $null; break }
            if ($line.Length -gt 0) { $null = & $OnLine $line }
            $reader = if ($kind -eq 'Out') { $Job.Process.StandardOutput } else { $Job.Process.StandardError }
            $Job[$key] = $reader.ReadLineAsync()
        }
    }
    return ($Job.Process.HasExited -and $null -eq $Job.OutTask -and $null -eq $Job.ErrTask)
}

function Stop-N4KProcess {
    param($Job)
    if ($null -ne $Job -and -not $Job.Process.HasExited) {
        $Job.Cancelled = $true
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = Join-Path $env:SystemRoot 'System32\taskkill.exe'
        $info.Arguments = '/PID ' + $Job.Process.Id + ' /T /F'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $null = [Diagnostics.Process]::Start($info)
    }
}

function Show-N4KLog {
    param([string]$Text)
    $form = [Windows.Forms.Form]::new()
    $form.Text = 'Журнал Nostalgia4K'
    $form.Size = [Drawing.Size]::new(900, 580)
    $form.StartPosition = 'CenterParent'
    $box = [Windows.Forms.TextBox]::new()
    $box.Multiline = $true
    $box.ReadOnly = $true
    $box.ScrollBars = 'Both'
    $box.WordWrap = $false
    $box.Dock = 'Fill'
    $box.Font = [Drawing.Font]::new('Consolas', 10)
    $box.BackColor = $script:C.Background
    $box.ForeColor = $script:C.Text
    $box.Text = $Text
    $form.Controls.Add($box)
    $box.Select($box.TextLength, 0)
    $box.ScrollToCaret()
    $null = $form.ShowDialog()
    $form.Dispose()
}

function Show-N4KError {
    param([string]$Message)
    $null = [Windows.Forms.MessageBox]::Show($Message, 'Nostalgia4K', 'OK', 'Error')
}
