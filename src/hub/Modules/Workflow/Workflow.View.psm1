#requires -Version 5.1
<#
Tela do modulo Workflow no HUB Benner. Somente liga controles as funcoes de
Workflow.Core.psm1; nenhuma regra de negocio deve ficar aqui.
Contrato com o HUB (module.psd1): New-WorkflowView devolve o UserControl e
Test-WorkflowViewBusy informa se ha lote em andamento (o HUB nao fecha nesse caso).
#>

Import-Module (Join-Path $PSScriptRoot 'Workflow.Core.psm1') -DisableNameChecking

$script:Settings = Get-WorkflowSettings
$script:UI = @{}
$script:FoundRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:InstalledRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:HeaderChecks = New-Object System.Collections.ArrayList
$script:BulkUpdate = $false
$script:Flags = @{ Installing = $false; Unlocking = $false; EditingConfig = $false; Removing = $false; ChangingLogin = $false }

$script:FoundSearchKeys = @('First', 'Second', 'ServiceName', 'SuperServerHost', 'SystemName', 'WorkflowUser', 'NotifySenderUser', 'ConfigText', 'Status', 'UnlockStatus')
$script:InstalledSearchKeys = @('Name', 'Display', 'State', 'StartName', 'Folder', 'Result')

# Fila de instalacao e de desbloqueio (acompanhadas por timer na thread da interface).
$script:Queue = @(); $script:QueuePosition = 0; $script:CurrentProcess = $null; $script:CurrentTask = $null; $script:SessionLog = $null
$script:UnlockQueue = @(); $script:UnlockPosition = 0; $script:UnlockProcess = $null; $script:CurrentUnlockJob = $null; $script:UnlockLog = $null

function Test-WorkflowViewBusy {
    foreach ($v in $script:Flags.Values) { if ($v) { return $true } }
    return $false
}

# ---------------------------------------------------------------------------
# Utilitarios de linha e de selecao
# ---------------------------------------------------------------------------
function Set-RowState($Row, [string]$Key, [string]$Text, [string]$Kind = '') {
    $Row[$Key] = $Text
    $Row[$Key + 'Kind'] = $Kind
}
# Sempre devolvem um array (a virgula impede o PowerShell de transformar lista vazia em $null
# ou lista de um item em item solto) e ignoram entradas nulas.
function Get-CheckedRows($Rows, [string]$Key) { return , @($Rows | Where-Object { $null -ne $_ -and $_.IsChecked($Key) }) }
function Get-VisibleRows($Rows) { return , @($Rows | Where-Object { $null -ne $_ -and $_['Visible'] -eq $true }) }
function Get-HiddenCount($Rows) { return @($Rows | Where-Object { $null -ne $_ -and $_['Visible'] -ne $true }).Count }

function Get-BulkNote([int]$Count, [int]$Hidden) {
    $note = ''
    if ($Count -gt 2) { $note += "ATENÇÃO: $Count serviços serão afetados por esta ação.`r`n`r`n" }
    if ($Hidden -gt 0) { $note += "$Hidden deles estão ocultos pelo filtro de pesquisa atual.`r`n`r`n" }
    return $note
}

# Alerta visivel quando mais de 2 itens estao marcados (ou ha marcados ocultos pelo filtro).
function Update-AlertText($Label, [object[]]$Groups) {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $show = $false
    foreach ($grp in $Groups) {
        $rows = @($grp.Rows)
        if ($rows.Count -eq 0) { continue }
        $hidden = Get-HiddenCount $rows
        if ($rows.Count -gt 2 -or $hidden -gt 0) { $show = $true }
        $text = "$($rows.Count) serviço(s) em $($grp.Name)"
        if ($hidden -gt 0) { $text += " ($hidden oculto(s) pelo filtro)" }
        $parts.Add($text)
    }
    $Label.Text = $(if ($show) { 'ATENÇÃO: ' + ($parts -join '  |  ') } else { '' })
    $Label.Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
}

function Commit-Grid($Grid) {
    [void]$Grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Cell, $true)
    [void]$Grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)
}

# ---------------------------------------------------------------------------
# "Marcar todos" no cabecalho das colunas de selecao (atua so nas linhas visiveis)
# ---------------------------------------------------------------------------
function Add-HeaderCheck($Grid, [int]$ColumnIndex, [string]$Key, [string]$Text, $Rows, [scriptblock]$After) {
    $box = New-Object System.Windows.Controls.CheckBox
    $box.Content = $Text
    $box.ToolTip = 'Marcar/desmarcar todas as linhas visíveis (respeita a pesquisa)'
    $box.Foreground = [System.Windows.Application]::Current.FindResource('Brush.Muted')
    $entry = [pscustomobject]@{ Grid = $Grid; Key = $Key; Box = $box; Rows = $Rows; After = $After }
    $box.Tag = $entry
    $box.Add_Click({ param($s, $e) Invoke-HubSafe { Switch-ColumnChecked $s.Tag } })
    $Grid.Columns[$ColumnIndex].Header = $box
    [void]$script:HeaderChecks.Add($entry)
}
function Set-ColumnChecked($Entry, [bool]$State) {
    if ($Entry.Grid.IsReadOnly) { Sync-HeaderChecks; return }
    Commit-Grid $Entry.Grid
    $script:BulkUpdate = $true
    try { foreach ($row in (Get-VisibleRows $Entry.Rows)) { $row[$Entry.Key] = $State } }
    finally { $script:BulkUpdate = $false }
    & $Entry.After
}
function Switch-ColumnChecked($Entry) {
    # Parcial ou nenhum -> marca todos; todos marcados -> desmarca.
    $visible = Get-VisibleRows $Entry.Rows
    $checked = @($visible | Where-Object { $_.IsChecked($Entry.Key) }).Count
    Set-ColumnChecked $Entry (-not ($visible.Count -gt 0 -and $checked -eq $visible.Count))
}
function Sync-HeaderChecks {
    foreach ($h in $script:HeaderChecks) {
        $visible = Get-VisibleRows $h.Rows
        $checked = @($visible | Where-Object { $_.IsChecked($h.Key) }).Count
        if ($visible.Count -gt 0 -and $checked -eq $visible.Count) { $h.Box.IsChecked = $true }
        elseif ($checked -gt 0) { $h.Box.IsChecked = $null }
        else { $h.Box.IsChecked = $false }
        $h.Box.IsEnabled = (-not $h.Grid.IsReadOnly)
    }
}

# ---------------------------------------------------------------------------
# Estado dos botoes
# ---------------------------------------------------------------------------
function Update-Commands {
    $f = $script:Flags
    $busy = Test-WorkflowViewBusy
    $installCount = (Get-CheckedRows $script:FoundRows 'Install').Count
    $unlockCount = (Get-CheckedRows $script:FoundRows 'Unlock').Count
    $loginCount = (Get-CheckedRows $script:InstalledRows 'LoginSel').Count
    $removeCount = (Get-CheckedRows $script:InstalledRows 'Remove').Count
    foreach ($n in 'RootBox', 'BrowseButton', 'ScanButton', 'IncludeFirstCheck', 'MarkAllButton', 'UnmarkAllButton', 'RefreshButton') { $script:UI[$n].IsEnabled = -not $busy }
    $script:UI.FoundGrid.IsReadOnly = ($f.Installing -or $f.Unlocking -or $f.EditingConfig)
    $script:UI.InstalledGrid.IsReadOnly = ($f.Removing -or $f.ChangingLogin)
    $canInstall = ($installCount -gt 0 -and -not $busy)
    $script:UI.InstallButton.IsEnabled = $canInstall
    $script:UI.EditConfigButton.IsEnabled = $canInstall
    $script:UI.InitialConfigButton.IsEnabled = $canInstall
    $script:UI.UnlockButton.IsEnabled = ($unlockCount -gt 0 -and -not $busy)
    $script:UI.ChangeLoginButton.IsEnabled = ($loginCount -gt 0 -and -not $busy)
    $script:UI.RemoveButton.IsEnabled = ($removeCount -gt 0 -and -not $busy)
    $script:UI.AccountBox.IsEnabled = -not $f.ChangingLogin
    $script:UI.PasswordInput.IsEnabled = -not $f.ChangingLogin
    Sync-HeaderChecks
}

function Update-Preview {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in (Get-CheckedRows $script:FoundRows 'Install')) {
        $parts.Add((Get-WorkflowInstallCommand -Name ([string]$row['ServiceName']) -Exe ([string]$row['Exe'])))
    }
    $script:UI.PreviewBox.Text = ($parts -join [Environment]::NewLine)
}

function Update-Selection {
    $installRows = Get-CheckedRows $script:FoundRows 'Install'
    $unlockRows = Get-CheckedRows $script:FoundRows 'Unlock'
    $count = $installRows.Count
    $hidden = Get-HiddenCount $installRows
    $script:UI.SelectedCountText.Text = $(if ($hidden -gt 0) { "$count selecionado(s), $hidden oculto(s)" } else { "$count selecionado(s)" })
    $script:UI.SummaryText.Text = "$count serviço(s) selecionado(s) para instalação"
    $script:UI.SummaryText.Foreground = $(if ($count -gt 2) { [System.Windows.Application]::Current.FindResource('Brush.Warn') } else { [System.Windows.Application]::Current.FindResource('Brush.Ink') })
    Update-AlertText $script:UI.FoundAlert @([pscustomobject]@{ Name = 'Instalar/.config'; Rows = $installRows }, [pscustomobject]@{ Name = 'Desbloquear'; Rows = $unlockRows })
    Update-Preview
    Update-Commands
}

function Update-InstalledSelection {
    $loginRows = Get-CheckedRows $script:InstalledRows 'LoginSel'
    $removeRows = Get-CheckedRows $script:InstalledRows 'Remove'
    Update-AlertText $script:UI.InstalledAlert @([pscustomobject]@{ Name = 'Login'; Rows = $loginRows }, [pscustomobject]@{ Name = 'Remover'; Rows = $removeRows })
    Update-Commands
}

# ---------------------------------------------------------------------------
# Pesquisa
# ---------------------------------------------------------------------------
function Apply-FoundFilter {
    $term = $script:UI.FoundSearch.Text
    foreach ($row in $script:FoundRows) { $row['Visible'] = [bool](Test-HubRowMatch -Row $row -Term $term -Keys $script:FoundSearchKeys) }
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:FoundRows).Refresh()
    $total = $script:FoundRows.Count
    $shown = (Get-VisibleRows $script:FoundRows).Count
    $script:UI.FoundText.Text = $(if ($shown -ne $total) { "$total serviço(s) encontrado(s)  |  $shown exibido(s) pela pesquisa" } else { "$total serviço(s) encontrado(s)" })
    Update-Selection
}

function Apply-InstalledFilter {
    $term = $script:UI.InstalledSearch.Text
    foreach ($row in $script:InstalledRows) { $row['Visible'] = [bool](Test-HubRowMatch -Row $row -Term $term -Keys $script:InstalledSearchKeys) }
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:InstalledRows).Refresh()
    $total = $script:InstalledRows.Count
    $shown = (Get-VisibleRows $script:InstalledRows).Count
    $script:UI.InstalledTitle.Text = $(if ($shown -ne $total) { "Workflow Services instalados no Windows ($shown de $total)" } else { "Workflow Services instalados no Windows ($total)" })
    Update-InstalledSelection
}

# ---------------------------------------------------------------------------
# Descoberta
# ---------------------------------------------------------------------------
function Get-ConfigBadge([string]$State) {
    switch ($State) {
        'config' { return @('Existe', 'ok') }
        'modelo' { return @('Gerar do modelo', 'warn') }
        default { return @('Ausente', 'err') }
    }
}

function On-FoundRowChanged($Row, [string]$Key) {
    if ($script:BulkUpdate) { return }
    switch ($Key) {
        'Install' { Update-Selection }
        'Unlock' { Update-Selection }
        'ServiceName' {
            $expected = Get-WorkflowServiceName -First $Row['First'] -Second $Row['Second'] -IncludeFirst ([bool]$script:UI.IncludeFirstCheck.IsChecked)
            $Row['AutoName'] = ([string]$Row['ServiceName'] -ceq $expected)
            Update-Preview
        }
    }
}

function Invoke-Scan {
    if (Test-WorkflowViewBusy) { return }
    $root = $script:UI.RootBox.Text.Trim().TrimEnd('\')
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Show-HubMessage -Text 'Diretório base não encontrado. Confira o caminho.' -Title 'Diretório inválido' -Kind Warning | Out-Null
        return
    }
    $includeFirst = [bool]$script:UI.IncludeFirstCheck.IsChecked
    $warnings = $null
    $found = @(Find-WorkflowFolder -Root $root -IncludeFirst $includeFirst -WarningVariable warnings -WarningAction SilentlyContinue)
    $script:FoundRows.Clear()
    foreach ($item in $found) {
        $row = New-Object BennerHub.HubRow
        $row['Install'] = $false; $row['Unlock'] = $false
        $row['First'] = $item.First; $row['Second'] = $item.Second; $row['Exe'] = $item.Exe
        $row['ServiceName'] = $item.SuggestedName; $row['AutoName'] = $true
        $row['SuperServerHost'] = ''; $row['SystemName'] = $item.Second
        $row['WorkflowUser'] = $script:Settings.DefaultUser; $row['NotifySenderUser'] = $script:Settings.DefaultUser
        $badge = Get-ConfigBadge $item.ConfigState
        Set-RowState $row 'ConfigText' $badge[0] $badge[1]
        Set-RowState $row 'Status' 'Pronto para instalar'
        Set-RowState $row 'UnlockStatus' 'Não executado'
        $row['Visible'] = $true
        $row.add_ValueChanged({ param($s, $e) Invoke-HubSafe { On-FoundRowChanged $s $e.Key } })
        $script:FoundRows.Add($row)
    }
    $script:UI.Progress.Value = 0
    $script:UI.ProgressText.Text = 'Busca concluída'
    Apply-FoundFilter
    if (@($warnings).Count -gt 0) {
        Show-HubMessage -Text ("Algumas pastas não puderam ser consultadas:`r`n" + (@($warnings | ForEach-Object { $_.Message }) -join "`r`n")) -Title 'Busca parcial' -Kind Warning | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Edicao do .config e Configurar
# ---------------------------------------------------------------------------
function Get-SelectedConfigTasks {
    Commit-Grid $script:UI.FoundGrid
    $tasks = New-Object 'System.Collections.Generic.List[object]'
    $errors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in (Get-CheckedRows $script:FoundRows 'Install')) {
        $t = [pscustomobject]@{
            Row = $row; Name = ([string]$row['ServiceName']).Trim(); Exe = [string]$row['Exe']
            Host = ([string]$row['SuperServerHost']).Trim(); System = ([string]$row['SystemName']).Trim()
            User = ([string]$row['WorkflowUser']).Trim(); NotifyUser = ([string]$row['NotifySenderUser']).Trim()
        }
        $problems = Test-WorkflowConfigValues -SuperServerHost $t.Host -SystemName $t.System -User $t.User -NotifySenderUser $t.NotifyUser -Label $t.Name
        if ($problems.Count -gt 0) { $errors.AddRange([string[]]$problems); continue }
        $tasks.Add($t)
    }
    if ($errors.Count -gt 0) { throw ($errors -join [Environment]::NewLine) }
    return $tasks.ToArray()
}

function Invoke-OpenConfigurator {
    if (Test-WorkflowViewBusy) { return }
    Commit-Grid $script:UI.FoundGrid
    $selected = Get-CheckedRows $script:FoundRows 'Install'
    if ($selected.Count -ne 1) {
        Show-HubMessage -Text 'Para abrir o Configurar, marque apenas uma linha por vez.' -Title 'Configuração inicial' | Out-Null; return
    }
    $exe = [string]$selected[0]['Exe']
    $folder = [IO.Path]::GetDirectoryName($exe)
    $cfg = $exe + '.config'
    if (Test-Path -LiteralPath $cfg -PathType Leaf) {
        if ((Show-HubMessage -Text 'Este serviço já possui .config. Deseja abrir o configurador mesmo assim?' -Title 'Configuração existente' -Kind Warning -YesNo) -ne 'Yes') { return }
    }
    $hubRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $configurator = @(Find-WorkflowConfigurator -Exe $exe -ExtraFolders @($PSScriptRoot, $hubRoot))
    if ($configurator.Count -eq 0) {
        Show-HubMessage -Text "Configurar.exe não encontrado. Coloque o configurador e suas dependências na pasta do Workflow:`r`n$folder`r`n`r`nOu coloque-o junto do HUB." -Title 'Configurar não localizado' -Kind Warning | Out-Null; return
    }
    Start-Process -FilePath $configurator[0] -WorkingDirectory (Split-Path $configurator[0] -Parent) -ErrorAction Stop | Out-Null
    Show-HubMessage -Text "Configurador aberto:`r`n$($configurator[0])`r`n`r`nO Configurar só é necessário para ajustes extras (e-mail, log centralizado etc.). Os quatro campos da grade são gravados por 'Editar .config selecionados' ou 'Instalar selecionados', inclusive gerando o .config a partir do .config.modelo. Arquivo:`r`n$cfg" -Title 'Configuração inicial' | Out-Null
}

function Invoke-EditConfig {
    if (Test-WorkflowViewBusy) { return }
    try { $tasks = @(Get-SelectedConfigTasks) }
    catch { Show-HubMessage -Text $_.Exception.Message -Title 'Campos inválidos' -Kind Warning | Out-Null; return }
    if ($tasks.Count -eq 0) { return }
    $missing = @($tasks | Where-Object { (Get-WorkflowConfigState -Exe $_.Exe) -eq 'ausente' })
    if ($missing.Count -gt 0) {
        $paths = ($missing | ForEach-Object { $_.Exe + '.config' }) -join "`r`n"
        Show-HubMessage -Text "Não existe .config nem .config.modelo para as seguintes linhas:`r`n$paths`r`n`r`nCopie a pasta completa do Workflow Service, que inclui o arquivo .config.modelo. Nenhum arquivo foi criado nem modificado." -Title 'Configuração inicial necessária' -Kind Warning | Out-Null; return
    }
    $fromModel = @($tasks | Where-Object { (Get-WorkflowConfigState -Exe $_.Exe) -eq 'modelo' })
    $modelNote = $(if ($fromModel.Count -gt 0) { "`r`n`r`n$($fromModel.Count) linha(s) ainda sem .config: o arquivo será gerado a partir do .config.modelo, como o Configurar faz no primeiro salvamento." } else { '' })
    $bulk = Get-BulkNote $tasks.Count (Get-HiddenCount @($tasks | ForEach-Object { $_.Row }))
    if ((Show-HubMessage -Text ($bulk + "Editar o .config de $($tasks.Count) linha(s) selecionada(s), sem instalar serviços? Será criado backup de cada arquivo existente.$modelNote") -Title 'Confirmar edição .config' -Kind Question -YesNo) -ne 'Yes') { return }
    $log = New-HubLogFile -Directory $script:Settings.LogDirectory -Prefix 'Workflow_EdicaoConfig'
    $script:Flags.EditingConfig = $true; Update-Commands
    $ok = 0; $failed = 0
    try {
        foreach ($t in $tasks) {
            try {
                $result = Set-WorkflowConfig -Exe $t.Exe -SuperServerHost $t.Host -SystemName $t.System -User $t.User -NotifySenderUser $t.NotifyUser -LogFile $log
                Set-RowState $t.Row 'Status' $(if ($result -eq 'gerado') { 'Config gerado do modelo' } else { 'Config atualizado' }) 'ok'
                Set-RowState $t.Row 'ConfigText' 'Existe' 'ok'
                $ok++
            } catch {
                Set-RowState $t.Row 'Status' 'Falha (config)' 'err'; $failed++
                Write-HubLog -Path $log -Message ("CONFIG FALHA | {0} | {1}" -f $t.Exe, $_.Exception.Message)
            }
            Invoke-HubDoEvents
        }
    } finally { $script:Flags.EditingConfig = $false; Update-Selection }
    $script:UI.ProgressText.Text = "Config: $ok sucesso(s), $failed falha(s)"
    Show-HubMessage -Text "Atualização concluída. Sucessos: $ok / Falhas: $failed.`r`nNenhum serviço foi instalado.`r`nLog: $log" -Title 'Edição .config' | Out-Null
}

# ---------------------------------------------------------------------------
# Instalacao em lote (sequencial)
# ---------------------------------------------------------------------------
function Invoke-Install {
    if (Test-WorkflowViewBusy) { return }
    Commit-Grid $script:UI.FoundGrid
    $tasks = New-Object 'System.Collections.Generic.List[object]'
    $names = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $problems = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in (Get-CheckedRows $script:FoundRows 'Install')) {
        $name = ([string]$row['ServiceName']).Trim()
        if (-not (Test-WorkflowServiceName -Name $name)) { $problems.Add("Nome inválido: '$name'. Use apenas letras, números, _ . - (máx. 230 caracteres)."); continue }
        if (-not $names.Add($name)) { $problems.Add("Nome duplicado na seleção: $name"); continue }
        if (-not (Test-Path -LiteralPath $row['Exe'] -PathType Leaf)) { $problems.Add("Executável ausente: $($row['Exe'])"); continue }
        $t = [pscustomobject]@{
            Row = $row; Name = $name; Exe = [string]$row['Exe']
            Host = ([string]$row['SuperServerHost']).Trim(); System = ([string]$row['SystemName']).Trim()
            User = ([string]$row['WorkflowUser']).Trim(); NotifyUser = ([string]$row['NotifySenderUser']).Trim()
            ConfigResult = ''; DetailLog = $null
        }
        $bad = Test-WorkflowConfigValues -SuperServerHost $t.Host -SystemName $t.System -User $t.User -NotifySenderUser $t.NotifyUser -Label $name
        if ($bad.Count -gt 0) { $problems.AddRange([string[]]$bad); continue }
        $tasks.Add($t)
    }
    if ($problems.Count -gt 0) { Show-HubMessage -Text ($problems -join "`r`n") -Title 'Corrija antes de instalar' -Kind Warning | Out-Null; return }
    if ($tasks.Count -eq 0) { return }
    if (-not (Test-Path -LiteralPath $script:Settings.InstallUtil -PathType Leaf)) {
        Show-HubMessage -Text "InstallUtil não encontrado: $($script:Settings.InstallUtil)" -Title 'Dependência ausente' -Kind Error | Out-Null; return
    }
    $existing = Get-WorkflowExistingServiceNames
    foreach ($t in $tasks) { if ($existing.Contains($t.Name)) { $problems.Add("Já existe um serviço no Windows com nome: $($t.Name)") } }
    if ($problems.Count -gt 0) { Show-HubMessage -Text ($problems -join "`r`n") -Title 'Serviço existente' -Kind Warning | Out-Null; return }
    $noConfig = @($tasks | Where-Object { (Get-WorkflowConfigState -Exe $_.Exe) -eq 'ausente' })
    $fromModel = @($tasks | Where-Object { (Get-WorkflowConfigState -Exe $_.Exe) -eq 'modelo' })
    $note = ''
    if ($fromModel.Count -gt 0) { $note += "`r`n`r`n$($fromModel.Count) linha(s) ainda sem .config: o arquivo será gerado a partir do .config.modelo, como o Configurar faz no primeiro salvamento:`r`n" + (($fromModel | ForEach-Object { $_.Name }) -join "`r`n") }
    if ($noConfig.Count -gt 0) { $note += "`r`n`r`nATENÇÃO: $($noConfig.Count) linha(s) não têm .config nem .config.modelo e serão instaladas SEM editar a configuração:`r`n" + (($noConfig | ForEach-Object { $_.Name }) -join "`r`n") }
    $bulk = Get-BulkNote $tasks.Count (Get-HiddenCount @($tasks | ForEach-Object { $_.Row }))
    $confirm = $bulk + "Instalar $($tasks.Count) serviço(s) Workflow no Windows?`r`n`r`nAntes de instalar, o .config existente de cada serviço será atualizado e receberá um backup. Instalações sequenciais não são revertidas automaticamente em caso de falha.$note`r`n`r`nDeseja continuar?"
    if ((Show-HubMessage -Text $confirm -Title 'Confirmar instalação' -Kind Question -YesNo) -ne 'Yes') { return }
    $script:SessionLog = New-HubLogFile -Directory $script:Settings.LogDirectory -Prefix 'Workflow_Instalacao'
    foreach ($t in $tasks) { Set-RowState $t.Row 'Status' 'Na fila' }
    $script:UI.Progress.Value = 0
    $script:Queue = $tasks.ToArray(); $script:QueuePosition = 0
    $script:Flags.Installing = $true; Update-Commands
    Start-NextInstallation
    if ($script:Flags.Installing) { $script:InstallTimer.Start() }
}

function Finish-Installation {
    $script:InstallTimer.Stop()
    $script:CurrentProcess = $null
    $script:Flags.Installing = $false
    $ok = @($script:Queue | Where-Object { [string]$_.Row['Status'] -like 'Sucesso*' }).Count
    $failed = @($script:Queue | Where-Object { [string]$_.Row['Status'] -like 'Falha*' }).Count
    $script:UI.Progress.Value = 100
    $script:UI.ProgressText.Text = "Lote concluído: $ok sucesso(s), $failed falha(s)."
    Update-Selection
    Refresh-Installed
    Show-HubMessage -Text "Instalação finalizada.`r`n`r`nSucesso: $ok`r`nFalha: $failed`r`n`r`nLogs: $($script:Settings.LogDirectory)" -Title 'Resultado da instalação' | Out-Null
}

function Start-NextInstallation {
    while ($script:QueuePosition -lt $script:Queue.Count) {
        $t = $script:Queue[$script:QueuePosition]
        $script:CurrentTask = $t
        $n = $script:QueuePosition + 1
        if ((Get-WorkflowConfigState -Exe $t.Exe) -ne 'ausente') {
            try {
                Set-RowState $t.Row 'Status' 'Configurando...' 'run'
                $t.ConfigResult = Set-WorkflowConfig -Exe $t.Exe -SuperServerHost $t.Host -SystemName $t.System -User $t.User -NotifySenderUser $t.NotifyUser -LogFile $script:SessionLog
                Set-RowState $t.Row 'ConfigText' 'Existe' 'ok'
            } catch {
                Set-RowState $t.Row 'Status' 'Falha (config)' 'err'
                Write-HubLog -Path $script:SessionLog -Message "CONFIG FALHA | $($t.Name) | $($_.Exception.Message)"
                $script:QueuePosition++
                continue
            }
        } else {
            # Sem .config e sem .config.modelo: instala sem editar, conforme confirmado.
            Write-HubLog -Path $script:SessionLog -Message "CONFIG IGNORADO | $($t.Name) | arquivo ausente: $($t.Exe).config (sem .config.modelo)"
        }
        Set-RowState $t.Row 'Status' 'Instalando...' 'run'
        $script:UI.ProgressText.Text = "Instalando $n/$($script:Queue.Count): $($t.Name)"
        $script:UI.Progress.Value = [int](($script:QueuePosition * 100) / $script:Queue.Count)
        $t.DetailLog = Join-Path $script:Settings.LogDirectory ("{0:D3}_{1}.log" -f $n, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
        try {
            $script:CurrentProcess = Start-WorkflowInstall -Name $t.Name -Exe $t.Exe -DetailLog $t.DetailLog
            return
        } catch {
            Set-RowState $t.Row 'Status' 'Falha (inicialização)' 'err'
            Write-HubLog -Path $script:SessionLog -Message "FALHA INICIANDO $($t.Name): $($_.Exception.Message)"
            $script:QueuePosition++
        }
    }
    Finish-Installation
}

function On-InstallTick {
    if ($null -eq $script:CurrentProcess -or -not $script:CurrentProcess.HasExited) { return }
    $code = $script:CurrentProcess.ExitCode
    $t = $script:CurrentTask
    if ($code -ne 0) { Set-RowState $t.Row 'Status' "Falha (código $code)" 'err' }
    elseif ($t.ConfigResult -eq 'gerado') { Set-RowState $t.Row 'Status' 'Sucesso (.config gerado)' 'ok' }
    elseif ($t.ConfigResult) { Set-RowState $t.Row 'Status' 'Sucesso' 'ok' }
    else { Set-RowState $t.Row 'Status' 'Sucesso (sem .config)' 'ok' }
    try { Write-WorkflowInstallResult -SessionLog $script:SessionLog -Name $t.Name -Exe $t.Exe -ExitCode $code -DetailLog $t.DetailLog } catch {}
    $script:CurrentProcess.Dispose(); $script:CurrentProcess = $null
    $script:QueuePosition++
    Start-NextInstallation
}

# ---------------------------------------------------------------------------
# Desbloqueio em lote (sequencial)
# ---------------------------------------------------------------------------
function Invoke-Unblock {
    if (Test-WorkflowViewBusy) { return }
    Commit-Grid $script:UI.FoundGrid
    $jobs = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in (Get-CheckedRows $script:FoundRows 'Unlock')) {
        $folder = [IO.Path]::GetDirectoryName([string]$row['Exe'])
        if (-not (Test-Path -LiteralPath $folder -PathType Container)) {
            Show-HubMessage -Text "Pasta não encontrada: $folder" -Title 'Erro' -Kind Error | Out-Null; return
        }
        $jobs.Add([pscustomobject]@{ Row = $row; Folder = $folder; Name = [string]$row['ServiceName'] })
    }
    if ($jobs.Count -eq 0) { return }
    $bulk = Get-BulkNote $jobs.Count (Get-HiddenCount @($jobs | ForEach-Object { $_.Row }))
    $msg = $bulk + "Desbloquear arquivos de $($jobs.Count) pasta(s) Workflow (incluindo subpastas)?`r`n`r`nIsto remove o marcador de origem da Internet (Zone.Identifier) dos arquivos encontrados. Não remove bloqueios de processos nem permissões NTFS.`r`n`r`nContinuar?"
    if ((Show-HubMessage -Text $msg -Title 'Confirmar desbloqueio' -Kind Warning -YesNo) -ne 'Yes') { return }
    $script:UnlockLog = New-HubLogFile -Directory $script:Settings.LogDirectory -Prefix 'Workflow_Desbloqueio'
    $script:UnlockQueue = $jobs.ToArray(); $script:UnlockPosition = 0; $script:UnlockProcess = $null
    foreach ($job in $jobs) { Set-RowState $job.Row 'UnlockStatus' 'Na fila' }
    $script:Flags.Unlocking = $true; Update-Commands
    Start-NextUnlock
    if ($script:Flags.Unlocking) { $script:UnlockTimer.Start() }
}

function Finish-Unblock {
    $script:UnlockTimer.Stop()
    $script:Flags.Unlocking = $false
    $script:UI.Progress.Value = 100
    $script:UI.ProgressText.Text = 'Desbloqueio finalizado. Consulte a coluna Desbloqueio e o log.'
    Update-Selection
    Show-HubMessage -Text "Desbloqueio finalizado.`r`nConfira os resultados por linha.`r`nLog: $($script:UnlockLog)" -Title 'Desbloqueio concluído' | Out-Null
}

function Start-NextUnlock {
    while ($script:UnlockPosition -lt $script:UnlockQueue.Count) {
        $job = $script:UnlockQueue[$script:UnlockPosition]
        $script:CurrentUnlockJob = $job
        $n = $script:UnlockPosition + 1
        Set-RowState $job.Row 'UnlockStatus' 'Desbloqueando...' 'run'
        $script:UI.ProgressText.Text = "Desbloqueando $n/$($script:UnlockQueue.Count): $($job.Name)"
        $script:UI.Progress.Value = [int](($script:UnlockPosition * 100) / $script:UnlockQueue.Count)
        try {
            $script:UnlockProcess = Start-WorkflowUnblock -Folder $job.Folder -LogFile $script:UnlockLog
            return
        } catch {
            Set-RowState $job.Row 'UnlockStatus' 'Falha ao iniciar' 'err'
            Write-HubLog -Path $script:UnlockLog -Message ("FALHA INICIANDO {0}: {1}" -f $job.Folder, $_.Exception.Message)
            $script:UnlockPosition++
        }
    }
    Finish-Unblock
}

function On-UnlockTick {
    if ($null -eq $script:UnlockProcess -or -not $script:UnlockProcess.HasExited) { return }
    $code = $script:UnlockProcess.ExitCode
    $job = $script:CurrentUnlockJob
    if ($code -eq 0) { Set-RowState $job.Row 'UnlockStatus' 'Concluído' 'ok' } else { Set-RowState $job.Row 'UnlockStatus' 'Falha (ver log)' 'err' }
    $script:UnlockProcess.Dispose(); $script:UnlockProcess = $null
    $script:UnlockPosition++
    Start-NextUnlock
}

# ---------------------------------------------------------------------------
# Servicos instalados
# ---------------------------------------------------------------------------
function Get-StateKind([string]$State) {
    switch ($State) { 'Running' { 'ok' } 'Stopped' { '' } default { 'run' } }
}

function Refresh-Installed {
    if (Test-WorkflowViewBusy) { return }
    $script:InstalledRows.Clear()
    try {
        foreach ($svc in @(Get-WorkflowInstalledService)) {
            $row = New-Object BennerHub.HubRow
            $row['LoginSel'] = $false; $row['Remove'] = $false
            $row['Name'] = $svc.Name; $row['Display'] = $svc.DisplayName
            Set-RowState $row 'State' $svc.State (Get-StateKind $svc.State)
            $row['StartName'] = $svc.StartName; $row['Folder'] = $svc.Folder; $row['Exe'] = $svc.Exe
            Set-RowState $row 'Result' ''
            $row['Visible'] = $true
            $row.add_ValueChanged({ param($s, $e) if (-not $script:BulkUpdate -and ($e.Key -eq 'LoginSel' -or $e.Key -eq 'Remove')) { Invoke-HubSafe { Update-InstalledSelection } } })
            $script:InstalledRows.Add($row)
        }
    } catch {
        Show-HubMessage -Text $_.Exception.Message -Title 'Falha consultando serviços' -Kind Error | Out-Null
    }
    Apply-InstalledFilter
}

function Set-InstalledBusy([string]$Flag, [bool]$Value) {
    $script:Flags[$Flag] = $Value
    Update-Commands
}

function Invoke-RemoveServices {
    if (Test-WorkflowViewBusy) { return }
    Commit-Grid $script:UI.InstalledGrid
    $targets = Get-CheckedRows $script:InstalledRows 'Remove'
    if ($targets.Count -eq 0) { return }
    $root = $script:UI.RootBox.Text.Trim()
    $items = @($targets | ForEach-Object { [pscustomobject]@{ Name = $_['Name']; Exe = $_['Exe']; Folder = $_['Folder'] } })
    $issues = Get-WorkflowRemovalIssues -Services $items -Root $root
    if ($issues.Count -gt 0) { Show-HubMessage -Text ($issues -join "`r`n") -Title 'Remoção bloqueada' -Kind Warning | Out-Null; return }
    $detail = ($targets | ForEach-Object { "$($_['Name'])  ->  $($_['Folder'])" }) -join "`r`n"
    $bulk = Get-BulkNote $targets.Count (Get-HiddenCount $targets)
    $msg = $bulk + "ATENÇÃO: remoção PERMANENTE de $($targets.Count) serviço(s) E suas pastas:`r`n`r`n$detail`r`n`r`nIsso não pode ser desfeito. Continuar?"
    if ((Show-HubMessage -Text $msg -Title 'Confirmar exclusão de serviços e arquivos' -Kind Warning -YesNo -DefaultNo) -ne 'Yes') { return }
    $log = New-HubLogFile -Directory $script:Settings.LogDirectory -Prefix 'Workflow_Remocao'
    Set-InstalledBusy 'Removing' $true
    try {
        foreach ($row in $targets) {
            Set-RowState $row 'Result' 'Removendo...' 'run'
            Invoke-HubDoEvents
            try {
                Remove-WorkflowService -Name $row['Name'] -Folder $row['Folder'] -Exe $row['Exe'] -Root $root -LogFile $log -OnWait { Invoke-HubDoEvents }
                Set-RowState $row 'Result' 'Removido + pasta' 'ok'
            } catch {
                Set-RowState $row 'Result' 'Falha / verificar log' 'err'
            }
        }
    } finally {
        Set-InstalledBusy 'Removing' $false
        Update-Selection
    }
    Show-HubMessage -Text "Remoção concluída. Consulte os resultados na grade e o log:`r`n$log" -Title 'Resultado da remoção' | Out-Null
}

function Invoke-ChangeLogin {
    if (Test-WorkflowViewBusy) { return }
    Commit-Grid $script:UI.InstalledGrid
    $targets = Get-CheckedRows $script:InstalledRows 'LoginSel'
    if ($targets.Count -eq 0) { return }
    $account = ConvertTo-HubServiceAccount -Account $script:UI.AccountBox.Text
    $secure = $script:UI.PasswordInput.SecurePassword
    try {
        $problem = Test-WorkflowLogonInput -Account $account -Password $secure
        if ($problem) { Show-HubMessage -Text $problem -Title 'Dados de login' -Kind Warning | Out-Null; return }
        $names = ($targets | ForEach-Object { $_['Name'] }) -join "`r`n"
        $bulk = Get-BulkNote $targets.Count (Get-HiddenCount $targets)
        $question = $bulk + "Alterar a conta de logon de $($targets.Count) serviço(s) para $account ?`r`n`r`n$names`r`n`r`nOs serviços em execução precisam ser reiniciados para usar a nova conta."
        if ((Show-HubMessage -Text $question -Title 'Confirmar alteração de login' -Kind Question -YesNo -DefaultNo) -ne 'Yes') { return }
        $log = New-HubLogFile -Directory $script:Settings.LogDirectory -Prefix 'Workflow_Logon'
        $changed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        Set-InstalledBusy 'ChangingLogin' $true
        try {
            $grantError = Grant-WorkflowLogonRight -Account $account -LogFile $log
            foreach ($row in $targets) {
                Set-RowState $row 'Result' 'Alterando login...' 'run'
                Invoke-HubDoEvents
                try {
                    $after = Set-WorkflowServiceLogon -Name $row['Name'] -Account $account -Password $secure -LogFile $log
                    $row['StartName'] = [string]$after.StartName
                    Set-RowState $row 'Result' $(if ($grantError) { 'Login alterado (sem direito confirmado)' } else { 'Login alterado (não testado)' }) 'warn'
                    [void]$changed.Add([string]$row['Name'])
                } catch {
                    Set-RowState $row 'Result' 'Falha no login / ver log' 'err'
                }
            }
        } finally {
            # Nunca manter a senha depois de aplicada.
            $script:UI.PasswordInput.Clear()
            Set-InstalledBusy 'ChangingLogin' $false
        }
    } finally {
        if ($null -ne $secure) { $secure.Dispose() }
    }
    if ($changed.Count -eq 0) {
        Show-HubMessage -Text "Nenhum serviço foi alterado. Consulte o log:`r`n$log" -Title 'Alteração de login' -Kind Warning | Out-Null
        return
    }
    $grantNote = $(if ($grantError) { "`r`n`r`nATENÇÃO: não foi possível conceder 'Log on as a service' ($grantError). Se a conta ainda não tiver esse direito, o serviço não vai iniciar." } else { '' })
    $answer = Show-HubMessage -Text "Alteração registrada.$grantNote`r`n`r`nPara VALIDAR a senha, você pode reiniciar os serviços alterados (haverá interrupção).`r`n`r`nReiniciar agora?" -Title 'Validação das credenciais' -Kind Question -YesNo -DefaultNo
    if ($answer -eq 'Yes') {
        Set-InstalledBusy 'ChangingLogin' $true
        try {
            foreach ($row in $targets) {
                if (-not $changed.Contains([string]$row['Name'])) { continue }
                Set-RowState $row 'Result' 'Reiniciando...' 'run'
                Invoke-HubDoEvents
                if (Test-WorkflowServiceStart -Name $row['Name'] -LogFile $log) {
                    Set-RowState $row 'Result' 'Login OK (serviço iniciou)' 'ok'
                    Set-RowState $row 'State' 'Running' 'ok'
                } else {
                    Set-RowState $row 'Result' 'Início falhou / ver log' 'err'
                }
            }
        } finally { Set-InstalledBusy 'ChangingLogin' $false }
    }
    Show-HubMessage -Text "Consulte os resultados por serviço e o log:`r`n$log" -Title 'Alteração de login' | Out-Null
}

# ---------------------------------------------------------------------------
# Montagem da tela (chamada pelo HUB)
# ---------------------------------------------------------------------------
function New-WorkflowView {
    param([Parameter(Mandatory)]$Context)
    $xamlPath = Join-Path $PSScriptRoot 'Workflow.View.xaml'
    $view = Import-HubXaml -Path $xamlPath
    $script:UI = Get-HubNamedElements -Root $view -XamlPath $xamlPath
    $script:UI.Window = $Context.Window
    $ui = $script:UI

    $ui.RootBox.Text = $script:Settings.DefaultRoot
    $ui.FoundGrid.ItemsSource = $script:FoundRows
    $ui.InstalledGrid.ItemsSource = $script:InstalledRows
    $visibleOnly = [Predicate[object]] { param($r) return ($r['Visible'] -eq $true) }
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:FoundRows).Filter = $visibleOnly
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:InstalledRows).Filter = $visibleOnly

    Add-HeaderCheck $ui.FoundGrid 0 'Install' 'Instalar' $script:FoundRows { Update-Selection }
    Add-HeaderCheck $ui.FoundGrid 1 'Unlock' 'Desbloquear' $script:FoundRows { Update-Selection }
    Add-HeaderCheck $ui.InstalledGrid 0 'LoginSel' 'Login' $script:InstalledRows { Update-InstalledSelection }
    Add-HeaderCheck $ui.InstalledGrid 1 'Remove' 'Remover' $script:InstalledRows { Update-InstalledSelection }

    $script:InstallTimer = New-HubTimer -IntervalMs 350 -OnTick { Invoke-HubSafe { On-InstallTick } }
    $script:UnlockTimer = New-HubTimer -IntervalMs 350 -OnTick { Invoke-HubSafe { On-UnlockTick } }

    $ui.BrowseButton.Add_Click({ Invoke-HubSafe {
                $path = Select-HubFolder -Description 'Selecione o diretório base de Workflow (WFL)' -InitialPath $script:UI.RootBox.Text
                if ($path) { $script:UI.RootBox.Text = $path; Invoke-Scan }
            } })
    $ui.ScanButton.Add_Click({ Invoke-HubSafe { Invoke-Scan } })
    $ui.RootBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-HubSafe { Invoke-Scan } } })
    $ui.IncludeFirstCheck.Add_Click({ Invoke-HubSafe {
                $include = [bool]$script:UI.IncludeFirstCheck.IsChecked
                $script:BulkUpdate = $true
                try {
                    foreach ($row in $script:FoundRows) {
                        if ($row['AutoName'] -eq $true) { $row['ServiceName'] = Get-WorkflowServiceName -First $row['First'] -Second $row['Second'] -IncludeFirst $include }
                    }
                } finally { $script:BulkUpdate = $false }
                $script:UI.SampleText.Text = $(if ($include) { 'Exemplo: AMBIENTE_SISTEMA_PRJ' } else { 'Exemplo: SISTEMA_PRJ' })
                Update-Preview
            } })
    # Botoes equivalem ao "marcar todos" da coluna Instalar: atuam so nas linhas visiveis.
    $ui.MarkAllButton.Add_Click({ Invoke-HubSafe { Set-ColumnChecked $script:HeaderChecks[0] $true } })
    $ui.UnmarkAllButton.Add_Click({ Invoke-HubSafe { Set-ColumnChecked $script:HeaderChecks[0] $false } })
    $ui.FoundSearch.Add_TextChanged({ Invoke-HubSafe { Apply-FoundFilter } })
    $ui.InstalledSearch.Add_TextChanged({ Invoke-HubSafe { Apply-InstalledFilter } })
    foreach ($box in @($ui.FoundSearch, $ui.InstalledSearch)) {
        $box.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Clear(); $e.Handled = $true } })
    }
    $ui.InitialConfigButton.Add_Click({ Invoke-HubSafe { Invoke-OpenConfigurator } -Title 'Falha ao iniciar Configurar' })
    $ui.EditConfigButton.Add_Click({ Invoke-HubSafe { Invoke-EditConfig } })
    $ui.LogsButton.Add_Click({ Invoke-HubSafe {
                New-Item -ItemType Directory -Path $script:Settings.LogDirectory -Force | Out-Null
                Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:Settings.LogDirectory)
            } })
    $ui.UnlockButton.Add_Click({ Invoke-HubSafe { Invoke-Unblock } })
    $ui.InstallButton.Add_Click({ Invoke-HubSafe { Invoke-Install } })
    $ui.RefreshButton.Add_Click({ Invoke-HubSafe { Refresh-Installed } })
    $ui.RemoveButton.Add_Click({ Invoke-HubSafe { Invoke-RemoveServices } })
    $ui.ChangeLoginButton.Add_Click({ Invoke-HubSafe { Invoke-ChangeLogin } })

    Refresh-Installed
    if (Test-Path -LiteralPath $ui.RootBox.Text -PathType Container) { Invoke-Scan } else { Update-Selection }
    return $view
}

Export-ModuleMember -Function New-WorkflowView, Test-WorkflowViewBusy
