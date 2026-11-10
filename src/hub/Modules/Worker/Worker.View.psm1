#requires -Version 5.1
<#
Tela do modulo Worker no HUB Benner. Somente liga controles as funcoes de
Worker.Core.psm1; nenhuma regra de negocio deve ficar aqui.
Contrato com o HUB (module.psd1): New-WorkerView devolve o UserControl e
Test-WorkerViewBusy informa se ha lote em andamento (o HUB nao fecha nesse caso).
#>

Import-Module (Join-Path $PSScriptRoot 'Worker.Core.psm1') -DisableNameChecking

$script:Settings = Get-WorkerSettings
$script:UI = @{}
$script:Package = $null
$script:FolderRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:InstalledRows = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$script:HeaderChecks = New-Object System.Collections.ArrayList
$script:BulkUpdate = $false
$script:Flags = @{ Installing = $false; Removing = $false; ChangingLogin = $false }
$script:FolderSearchKeys = @('Name', 'Path', 'Servidor', 'Sistema', 'DisplayName', 'Fila', 'Usuario', 'State', 'Status')
$script:InstalledSearchKeys = @('Name', 'Display', 'Version', 'State', 'StartName', 'Folder', 'Result')
$script:EditableKeys = @('Servidor', 'Sistema', 'DisplayName', 'Fila', 'Providers', 'Win32', 'Usuario', 'PoolDinamica', 'UseCOMFree')

# Fila de instalacao (acompanhada por timer na thread da interface). Cada tarefa passa pelas fases
# copy -> (config) -> register (so no 23) -> start -> fim.
$script:Queue = @(); $script:QueuePosition = 0; $script:CurrentTask = $null; $script:SessionLog = $null

# Colunas da grade de pastas (indices no XAML).
$script:Col = @{ Providers = 6; Win32 = 7; Usuario = 8; Pool = 9; ComFree = 10 }

function Test-WorkerViewBusy {
    foreach ($v in $script:Flags.Values) { if ($v) { return $true } }
    return $false
}

# ---------------------------------------------------------------------------
# Utilitarios de linha e de selecao (mesmo comportamento do modulo Workflow)
# ---------------------------------------------------------------------------
function Set-RowState($Row, [string]$Key, [string]$Text, [string]$Kind = '') {
    $Row[$Key] = $Text
    $Row[$Key + 'Kind'] = $Kind
}
function Get-CheckedRows($Rows, [string]$Key) { return , @($Rows | Where-Object { $null -ne $_ -and $_.IsChecked($Key) }) }
function Get-VisibleRows($Rows) { return , @($Rows | Where-Object { $null -ne $_ -and $_['Visible'] -eq $true }) }
function Get-HiddenCount($Rows) { return @($Rows | Where-Object { $null -ne $_ -and $_['Visible'] -ne $true }).Count }

function Get-BulkNote([int]$Count, [int]$Hidden) {
    $note = ''
    if ($Count -gt 2) { $note += "ATENÇÃO: $Count itens serão afetados por esta ação.`r`n`r`n" }
    if ($Hidden -gt 0) { $note += "$Hidden deles estão ocultos (pesquisa ou pasta recolhida).`r`n`r`n" }
    return $note
}

function Update-AlertText($Label, [object[]]$Groups) {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    $show = $false
    foreach ($grp in $Groups) {
        $rows = @($grp.Rows)
        if ($rows.Count -eq 0) { continue }
        $hidden = Get-HiddenCount $rows
        if ($rows.Count -gt 2 -or $hidden -gt 0) { $show = $true }
        $text = "$($rows.Count) em $($grp.Name)"
        if ($hidden -gt 0) { $text += " ($hidden oculto(s))" }
        $parts.Add($text)
    }
    $Label.Text = $(if ($show) { 'ATENÇÃO: ' + ($parts -join '  |  ') } else { '' })
    $Label.Visibility = $(if ($show) { 'Visible' } else { 'Collapsed' })
}

function Commit-Grid($Grid) {
    [void]$Grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Cell, $true)
    [void]$Grid.CommitEdit([System.Windows.Controls.DataGridEditingUnit]::Row, $true)
}

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

function Format-List([string[]]$Items, [int]$Max = 8) {
    $items = @($Items)
    if ($items.Count -le $Max) { return ($items -join "`r`n") }
    return ((@($items[0..($Max - 1)]) -join "`r`n") + "`r`n... e mais $($items.Count - $Max)")
}

# ---------------------------------------------------------------------------
# Estado dos botoes, previa e selecao
# ---------------------------------------------------------------------------
function Update-Commands {
    $f = $script:Flags
    $busy = Test-WorkerViewBusy
    $installCount = (Get-CheckedRows $script:FolderRows 'Install').Count
    $loginCount = (Get-CheckedRows $script:InstalledRows 'LoginSel').Count
    $removeCount = (Get-CheckedRows $script:InstalledRows 'Remove').Count
    foreach ($n in 'PackageBox', 'PackageBrowse', 'PackageDetect', 'PackagePanel', 'RootBox', 'RootBrowse', 'ListButton', 'NewFolderBox', 'AddFolderButton',
        'RefreshButton', 'StartAfterCheck', 'DeleteFolderCheck') { $script:UI[$n].IsEnabled = -not $busy }
    $script:UI.FolderGrid.IsReadOnly = $f.Installing
    $script:UI.InstalledGrid.IsReadOnly = ($f.Removing -or $f.ChangingLogin)
    $script:UI.InstallButton.IsEnabled = ($installCount -gt 0 -and -not $busy -and $null -ne $script:Package)
    $script:UI.ApplyDefaultsButton.IsEnabled = ($installCount -gt 0 -and -not $busy)
    $script:UI.CheckChildrenButton.IsEnabled = (-not $busy -and @((Get-CheckedRows $script:FolderRows 'Install') | Where-Object { $_['Level'] -eq 0 }).Count -gt 0)
    $script:UI.ChangeLoginButton.IsEnabled = ($loginCount -gt 0 -and -not $busy)
    $script:UI.RemoveButton.IsEnabled = ($removeCount -gt 0 -and -not $busy)
    $script:UI.AccountBox.IsEnabled = -not $f.ChangingLogin
    $script:UI.PasswordInput.IsEnabled = -not $f.ChangingLogin
    Sync-HeaderChecks
}

function Get-RowParameters($Row) {
    <# Hashtable de parametros (Get-WorkerDefaultParameters + campos da linha) para a versao do pacote selecionado. #>
    $v = $script:Package.Version
    $p = Get-WorkerDefaultParameters -Version $v
    $p.Servidor = ([string]$Row['Servidor']).Trim()
    $p.Sistema = ([string]$Row['Sistema']).Trim()
    $p.Nome = [string]$Row['Nome']
    $p.DisplayName = ([string]$Row['DisplayName']).Trim()
    $p.Fila = ([string]$Row['Fila']).Trim()
    if ($v -eq '23') {
        $p.Usuario = ([string]$Row['Usuario']).Trim()
        $p.NumeroDeProviders = ([string]$Row['Providers']).Trim()
        $p.PoolDinamica = $Row.IsChecked('PoolDinamica')
        $p.UseCOMFree = $Row.IsChecked('UseCOMFree')
    } else {
        $p.UserHandle = ([string]$Row['Usuario']).Trim()
        $p.MaxPoolItem = ([string]$Row['Providers']).Trim()
        $p.MaxLegacyPoolItem = ([string]$Row['Win32']).Trim()
    }
    return $p
}

function Update-Preview {
    if ($null -eq $script:Package) { $script:UI.PreviewBox.Text = 'Selecione um pacote Worker (23 ou 25).'; return }
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($row in (Get-CheckedRows $script:FolderRows 'Install')) {
        try { $parts.Add((Get-WorkerInstallPreview -Package $script:Package -Folder ([string]$row['Path']) -Parameters (Get-RowParameters $row))) }
        catch { $parts.Add("# $($row['Path']): $($_.Exception.Message)") }
    }
    $script:UI.PreviewBox.Text = ($parts -join ([Environment]::NewLine + [Environment]::NewLine))
}

function Update-Selection {
    $rows = Get-CheckedRows $script:FolderRows 'Install'
    $count = $rows.Count
    $hidden = Get-HiddenCount $rows
    $script:UI.SelectedCountText.Text = $(if ($hidden -gt 0) { "$count selecionada(s), $hidden oculta(s)" } else { "$count selecionada(s)" })
    $script:UI.SummaryText.Text = "$count pasta(s) selecionada(s) para instalação"
    $app = [System.Windows.Application]::Current
    $script:UI.SummaryText.Foreground = $(if ($count -gt 2) { $app.FindResource('Brush.Warn') } else { $app.FindResource('Brush.Ink') })
    $top = @($script:FolderRows | Where-Object { $_['Level'] -eq 0 }).Count
    $script:UI.FoldersText.Text = "$top pasta(s) na raiz, $count marcada(s)"
    Update-AlertText $script:UI.FolderAlert @([pscustomobject]@{ Name = 'Instalar'; Rows = $rows })
    Update-Preview
    Update-Commands
}

function Update-InstalledSelection {
    $loginRows = Get-CheckedRows $script:InstalledRows 'LoginSel'
    $removeRows = Get-CheckedRows $script:InstalledRows 'Remove'
    Update-AlertText $script:UI.InstalledAlert @([pscustomobject]@{ Name = 'Login'; Rows = $loginRows }, [pscustomobject]@{ Name = 'Remover'; Rows = $removeRows })
    Update-Commands
}

function Apply-FolderFilter {
    $term = $script:UI.FolderSearch.Text
    foreach ($row in $script:FolderRows) {
        $matchSearch = [bool](Test-HubRowMatch -Row $row -Term $term -Keys $script:FolderSearchKeys)
        $parentOpen = $true
        if ($row['Level'] -eq 1) {
            $parent = @($script:FolderRows | Where-Object { $_['Level'] -eq 0 -and [string]$_['Path'] -ieq [string]$row['ParentPath'] }) | Select-Object -First 1
            $parentOpen = ($null -ne $parent -and $parent['Expanded'] -eq $true)
        }
        $row['Visible'] = ($matchSearch -and ($parentOpen -or ([string]$term).Trim().Length -gt 0))
    }
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:FolderRows).Refresh()
    Update-Selection
}

function Apply-InstalledFilter {
    $term = $script:UI.InstalledSearch.Text
    foreach ($row in $script:InstalledRows) { $row['Visible'] = [bool](Test-HubRowMatch -Row $row -Term $term -Keys $script:InstalledSearchKeys) }
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:InstalledRows).Refresh()
    $total = $script:InstalledRows.Count
    $shown = (Get-VisibleRows $script:InstalledRows).Count
    $script:UI.InstalledTitle.Text = $(if ($shown -ne $total) { "Benner Workers instalados no Windows ($shown de $total)" } else { "Benner Workers instalados no Windows ($total)" })
    Update-InstalledSelection
}

# ---------------------------------------------------------------------------
# Pacote
# ---------------------------------------------------------------------------
function Get-VersionOrDefault { if ($null -ne $script:Package) { return $script:Package.Version } return '23' }

function Set-DefaultsForVersion([string]$Version) {
    $info = Get-WorkerVersionInfo -Version $Version
    $ui = $script:UI
    $ui.DefaultFilaBox.Text = $info.DefaultFila
    $ui.DefaultFilaBox.ToolTip = 'Filas do modelo: ' + ($info.Queues -join ', ')
    if ($Version -eq '23') {
        $ui.DefaultProvidersLabel.Text = 'Nº providers (0 = automático)'
        $ui.DefaultProvidersBox.Text = '0'
        $ui.DefaultUserLabel.Text = 'Usuário'
        if (-not $ui.DefaultUserBox.Text.Trim() -or $ui.DefaultUserBox.Text.Trim() -match '^\d+$') { $ui.DefaultUserBox.Text = $script:Settings.DefaultUser }
        $ui.DefaultWin32Panel.Visibility = 'Collapsed'
        $ui.DefaultFlagsPanel.Visibility = 'Visible'
    } else {
        $ui.DefaultProvidersLabel.Text = 'Providers Core'
        $ui.DefaultProvidersBox.Text = '4'
        $ui.DefaultWin32Box.Text = '4'
        $ui.DefaultUserLabel.Text = 'UserHandle (opcional)'
        if ($ui.DefaultUserBox.Text.Trim() -notmatch '^\d+$') { $ui.DefaultUserBox.Text = '' }
        $ui.DefaultWin32Panel.Visibility = 'Visible'
        $ui.DefaultFlagsPanel.Visibility = 'Collapsed'
    }
    # Colunas por versao: Win32 so no 25; Pool dinamica e COMFree so no 23.
    $grid = $ui.FolderGrid
    $grid.Columns[$script:Col.Win32].Visibility = $(if ($Version -eq '25') { 'Visible' } else { 'Collapsed' })
    $grid.Columns[$script:Col.Pool].Visibility = $(if ($Version -eq '23') { 'Visible' } else { 'Collapsed' })
    $grid.Columns[$script:Col.ComFree].Visibility = $(if ($Version -eq '23') { 'Visible' } else { 'Collapsed' })
    $grid.Columns[$script:Col.Providers].Header = $(if ($Version -eq '23') { 'Nº providers (0=auto)' } else { 'Providers Core' })
    $grid.Columns[$script:Col.Usuario].Header = $(if ($Version -eq '23') { 'Usuário' } else { 'UserHandle' })
}

function Select-WorkerPackage($Package) {
    $old = Get-VersionOrDefault
    $hadPackage = ($null -ne $script:Package)
    $script:Package = $Package
    if ($null -eq $Package) {
        $script:UI.PackageInfo.Text = 'Nenhum pacote Worker selecionado.'
        Update-Selection
        return
    }
    $issues = Test-WorkerPrerequisites -Version $Package.Version
    $text = "$($Package.Label)  |  $($Package.Lib)"
    if ($issues.Count -gt 0) { $text += "`r`nATENÇÃO: " + ($issues -join ' ') }
    $script:UI.PackageInfo.Text = $text
    $script:UI.PackageInfo.Foreground = [System.Windows.Application]::Current.FindResource($(if ($issues.Count -gt 0) { 'Brush.Warn' } else { 'Brush.Muted' }))
    if (-not $hadPackage -or $old -ne $Package.Version) {
        Set-DefaultsForVersion $Package.Version
        # Troca de versao: campos que dependem da versao voltam ao padrao em todas as linhas.
        $script:BulkUpdate = $true
        try { foreach ($row in $script:FolderRows) { Set-RowVersionDefaults $row } }
        finally { $script:BulkUpdate = $false }
    }
    Update-Selection
}

function Invoke-DetectPackages {
    if (Test-WorkerViewBusy) { return }
    $path = $script:UI.PackageBox.Text.Trim().TrimEnd('\')
    $panel = $script:UI.PackagePanel
    $panel.Children.Clear()
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        Select-WorkerPackage $null
        $script:UI.PackageInfo.Text = "Pasta do pacote não encontrada: $path"
        return
    }
    $found = @(Find-WorkerPackage -Root $path)
    if ($found.Count -eq 0) {
        Select-WorkerPackage $null
        $script:UI.PackageInfo.Text = "Nenhum pacote Worker em $path (procurei Lib\Benner.Tecnologia.Tasks.Worker.exe e Lib\Benner.Core.Worker.exe nela e nas subpastas)."
        return
    }
    $first = $null
    foreach ($pkg in $found) {
        $radio = New-Object System.Windows.Controls.RadioButton
        $radio.GroupName = 'WorkerPackage'
        $radio.Content = "$($pkg.Name)  ·  Worker $($pkg.Version)"
        $radio.ToolTip = "$($pkg.Label)`r`n$($pkg.Path)"
        $radio.Foreground = [System.Windows.Application]::Current.FindResource('Brush.Ink')
        $radio.Margin = '0,0,22,0'
        $radio.Tag = $pkg
        $radio.Add_Checked({ param($s, $e) Invoke-HubSafe { Select-WorkerPackage $s.Tag } })
        [void]$panel.Children.Add($radio)
        if ($null -eq $first) { $first = $radio }
    }
    $keep = $null
    if ($null -ne $script:Package) { $keep = @($panel.Children | Where-Object { $_.Tag.Path -ieq $script:Package.Path }) | Select-Object -First 1 }
    if ($null -ne $keep) { $keep.IsChecked = $true; Select-WorkerPackage $keep.Tag } else { $first.IsChecked = $true }
}

# ---------------------------------------------------------------------------
# Pastas de instalacao (grade com um nivel de subpastas, como o Criar/Atualizar pasta do Workflow)
# ---------------------------------------------------------------------------
function Get-RelativeName([string]$Path) {
    $root = $script:UI.RootBox.Text.Trim().TrimEnd('\')
    try {
        $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
        $r = [IO.Path]::GetFullPath($root).TrimEnd('\')
        if ($full.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $full.Substring($r.Length + 1) }
    } catch {}
    return (Split-Path $Path -Leaf)
}

function Get-DefaultDisplayName($Row) {
    $info = Get-WorkerVersionInfo -Version (Get-VersionOrDefault)
    $rel = (Get-RelativeName ([string]$Row['Path'])).Replace('\', '-')
    return ('{0} [{1}]' -f $info.Display, $rel)
}

function Set-RowVersionDefaults($Row) {
    <# Campos que dependem da versao: valores do painel de padroes; nome de exibicao automatico. #>
    $ui = $script:UI
    $Row['Fila'] = $ui.DefaultFilaBox.Text.Trim()
    $Row['Providers'] = $ui.DefaultProvidersBox.Text.Trim()
    $Row['Win32'] = $ui.DefaultWin32Box.Text.Trim()
    $Row['Usuario'] = $ui.DefaultUserBox.Text.Trim()
    $Row['PoolDinamica'] = [bool]$ui.DefaultPoolCheck.IsChecked
    $Row['UseCOMFree'] = [bool]$ui.DefaultComFreeCheck.IsChecked
    if ($Row['AutoDisplay'] -eq $true) { $Row['DisplayName'] = Get-DefaultDisplayName $Row }
}

function Set-ExpandState($Row) {
    $can = ($Row['Level'] -eq 0 -and $Row['HasChildren'] -eq $true)
    $Row['ExpandVisibility'] = $(if ($can) { [System.Windows.Visibility]::Visible } else { [System.Windows.Visibility]::Hidden })
    $Row['ExpandGlyph'] = $(if ($Row['Expanded'] -eq $true) { [string][char]0x25B2 } else { [string][char]0x25BC })
    $Row['ExpandTip'] = $(if ($Row['Expanded'] -eq $true) { 'Recolher as pastas de dentro' } else { 'Ver as pastas de dentro' })
}

function Get-StateBadgeKind([string]$State) {
    switch ($State) { 'instalado' { 'err' } 'arquivos' { 'warn' } 'worker' { 'warn' } 'vazia' { 'ok' } 'nova' { 'ok' } default { '' } }
}

function Update-RowFolderState($Row, [object[]]$Services) {
    $st = Get-WorkerFolderState -Folder ([string]$Row['Path']) -Services $Services
    $Row['FolderState'] = $st.State
    Set-RowState $Row 'State' $st.Text (Get-StateBadgeKind $st.State)
}

function New-FolderRow([string]$Name, [string]$Path, [int]$Level, [string]$ParentPath, [bool]$HasChildren, [object[]]$Services) {
    $row = New-Object BennerHub.HubRow
    $row['Install'] = $false
    $row['Name'] = $Name; $row['Path'] = $Path
    $row['Level'] = $Level; $row['ParentPath'] = $ParentPath
    $row['HasChildren'] = $HasChildren; $row['Expanded'] = $false; $row['ChildrenLoaded'] = $false
    $row['Indent'] = New-Object System.Windows.Thickness ((22 * $Level), 0, 0, 0)
    Set-ExpandState $row
    $row['Servidor'] = $script:UI.DefaultServerBox.Text.Trim()
    $row['Sistema'] = $Name
    $row['Nome'] = Get-WorkerSafeName ((Get-RelativeName $Path).Replace('\', '_'))
    $row['AutoDisplay'] = $true
    Set-RowVersionDefaults $row
    Update-RowFolderState $row $Services
    Set-RowState $row 'Status' 'Não executado'
    $row['StatusTip'] = ''
    $row['Visible'] = ($Level -eq 0)
    $row.add_ValueChanged({ param($s, $e) Invoke-HubSafe { On-FolderRowChanged $s $e.Key } })
    return $row
}

function On-FolderRowChanged($Row, [string]$Key) {
    if ($script:BulkUpdate) { return }
    switch ($Key) {
        'Install' { Update-Selection }
        'DisplayName' { $Row['AutoDisplay'] = ([string]$Row['DisplayName'] -ceq (Get-DefaultDisplayName $Row)); Update-Preview }
        default { if ($script:EditableKeys -contains $Key) { Update-Preview } }
    }
}

function Invoke-ListFolders {
    if (Test-WorkerViewBusy) { return }
    $root = $script:UI.RootBox.Text.Trim().TrimEnd('\')
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Show-HubMessage -Text "Raiz de instalação não encontrada: $root`r`n`r`nCrie a pasta ou ajuste o caminho." -Title 'Raiz inválida' -Kind Warning | Out-Null
        return
    }
    $services = @(Get-WorkerInstalledService -All)
    $script:FolderRows.Clear()
    foreach ($item in @(Get-WorkerTargetFolder -Root $root)) {
        $script:FolderRows.Add((New-FolderRow $item.Name $item.Path 0 '' $item.HasChildren $services))
    }
    $script:UI.Progress.Value = 0
    $script:UI.ProgressText.Text = 'Marque as pastas onde instalar e preencha os campos de cada linha.'
    Apply-FolderFilter
}

function Get-ChildRows($Row) {
    if ($Row['ChildrenLoaded'] -ne $true) {
        $services = @(Get-WorkerInstalledService -All)
        $index = $script:FolderRows.IndexOf($Row)
        foreach ($item in @(Get-WorkerTargetFolder -Root ([string]$Row['Path']))) {
            $index++
            $script:FolderRows.Insert($index, (New-FolderRow $item.Name $item.Path 1 ([string]$Row['Path']) $false $services))
        }
        $Row['ChildrenLoaded'] = $true
    }
    return , @($script:FolderRows | Where-Object { $_['Level'] -eq 1 -and [string]$_['ParentPath'] -ieq [string]$Row['Path'] })
}

function Set-RowExpanded($Row, [bool]$Expanded) {
    $children = Get-ChildRows $Row
    $Row['Expanded'] = $Expanded
    if ($children.Count -eq 0) { $Row['HasChildren'] = $false; $Row['Expanded'] = $false }
    Set-ExpandState $Row
    Apply-FolderFilter
}

function Switch-RowExpanded($Row) {
    if ($script:Flags.Installing -or $Row['Level'] -ne 0) { return }
    Commit-Grid $script:UI.FolderGrid
    Set-RowExpanded $Row (-not ($Row['Expanded'] -eq $true))
}

function Add-ChildRow($Parent, [string]$Name, [string]$Path) {
    $Parent['HasChildren'] = $true
    if ($Parent['ChildrenLoaded'] -eq $true) {
        $children = Get-ChildRows $Parent
        $row = @($children | Where-Object { [string]$_['Path'] -ieq $Path }) | Select-Object -First 1
        if ($null -eq $row) {
            $row = New-FolderRow $Name $Path 1 ([string]$Parent['Path']) $false @(Get-WorkerInstalledService -All)
            $after = $(if ($children.Count -gt 0) { $children[$children.Count - 1] } else { $Parent })
            $script:FolderRows.Insert($script:FolderRows.IndexOf($after) + 1, $row)
        }
    }
    $Parent['Expanded'] = $true
    [void](Get-ChildRows $Parent)
    Set-ExpandState $Parent
    return @((Get-ChildRows $Parent) | Where-Object { [string]$_['Path'] -ieq $Path }) | Select-Object -First 1
}

function Invoke-AddFolder {
    if (Test-WorkerViewBusy) { return }
    Commit-Grid $script:UI.FolderGrid
    $root = $script:UI.RootBox.Text.Trim().TrimEnd('\')
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($n in ($script:UI.NewFolderBox.Text -split '[;,]')) {
        $n = $n.Trim()
        if ($n -and -not ($names -contains $n)) { $names.Add($n) }
    }
    if ($names.Count -eq 0) { return }
    $bad = @($names | Where-Object { -not (Test-WorkerFolderName -Name $_) })
    if ($bad.Count -gt 0) {
        Show-HubMessage -Text ("Nome(s) de pasta inválido(s):`r`n" + ($bad -join "`r`n") + "`r`n`r`nInforme só o nome, sem \ / : * ? `" < > |. Para várias pastas, separe com ; ou ,") -Title 'Nome inválido' -Kind Warning | Out-Null; return
    }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        Show-HubMessage -Text "Raiz de instalação não encontrada: $root" -Title 'Raiz inválida' -Kind Warning | Out-Null; return
    }
    $parents = Get-CheckedRows $script:FolderRows 'Install'
    $targets = New-Object 'System.Collections.Generic.List[object]'
    if ($parents.Count -eq 0) {
        foreach ($n in $names) { $targets.Add([pscustomobject]@{ Parent = $null; ParentPath = $root; Name = $n; Path = (Join-Path $root $n) }) }
    } else {
        foreach ($p in $parents) { foreach ($n in $names) { $targets.Add([pscustomobject]@{ Parent = $p; ParentPath = [string]$p['Path']; Name = $n; Path = (Join-Path ([string]$p['Path']) $n) }) } }
    }
    $lines = @($targets | ForEach-Object { $_.Path + $(if (Test-Path -LiteralPath $_.Path -PathType Container) { '  (já existe)' } else { '' }) })
    $where = $(if ($parents.Count -eq 0) { 'na raiz de instalação (nenhuma pasta marcada)' } else { "dentro de $($parents.Count) pasta(s) marcada(s)" })
    $msg = "Criar $($targets.Count) pasta(s) $where`?`r`n`r`n" + (Format-List $lines 15)
    if ($parents.Count -gt 0) { $msg += "`r`n`r`nAs pastas criadas ficam marcadas para instalar e as pastas mãe são desmarcadas." }
    if ((Show-HubMessage -Text $msg -Title 'Criar pastas' -Kind Question -YesNo) -ne 'Yes') { return }

    $log = New-HubLogFile -Directory $script:Settings.LogDirectory -Prefix 'Worker_Pastas'
    $failed = New-Object 'System.Collections.Generic.List[string]'
    $notShown = New-Object 'System.Collections.Generic.List[string]'
    $created = 0
    $script:BulkUpdate = $true
    try {
        foreach ($t in $targets) {
            try { $r = New-WorkerTargetFolder -Parent $t.ParentPath -Name $t.Name -LogFile $log }
            catch { $failed.Add("$($t.Path): $($_.Exception.Message)"); Write-HubLog -Path $log -Message "FALHA CRIANDO $($t.Path): $($_.Exception.Message)"; continue }
            if ($r.Created) { $created++ }
            if ($null -eq $t.Parent) {
                $row = @($script:FolderRows | Where-Object { [string]$_['Path'] -ieq $r.Path }) | Select-Object -First 1
                if ($null -eq $row) { $row = New-FolderRow $t.Name $r.Path 0 '' $false @(); $script:FolderRows.Add($row) }
                $row['Install'] = $true
            } elseif ($t.Parent['Level'] -eq 0) {
                $row = Add-ChildRow $t.Parent $t.Name $r.Path
                if ($row) { $row['Install'] = $true }
                $t.Parent['Install'] = $false
            } else {
                $notShown.Add($r.Path)
            }
        }
    } finally { $script:BulkUpdate = $false }
    $script:UI.NewFolderBox.Clear()
    Apply-FolderFilter
    $script:UI.ProgressText.Text = "$created pasta(s) criada(s). Log: $log"
    if ($failed.Count -gt 0 -or $notShown.Count -gt 0) {
        $text = "$created pasta(s) criada(s)."
        if ($failed.Count -gt 0) { $text += "`r`n`r`nNão foi possível criar:`r`n" + ($failed -join "`r`n") }
        if ($notShown.Count -gt 0) { $text += "`r`n`r`nCriadas dentro de pastas internas (a grade mostra só um nível, então elas não aparecem):`r`n" + ($notShown -join "`r`n") }
        Show-HubMessage -Text $text -Title 'Criar pastas' -Kind $(if ($failed.Count -gt 0) { 'Warning' } else { 'Info' }) | Out-Null
    }
}

function Invoke-CheckChildren {
    if (Test-WorkerViewBusy) { return }
    Commit-Grid $script:UI.FolderGrid
    $parents = @((Get-CheckedRows $script:FolderRows 'Install') | Where-Object { $_['Level'] -eq 0 })
    if ($parents.Count -eq 0) { return }
    $empty = New-Object 'System.Collections.Generic.List[string]'
    $script:BulkUpdate = $true
    try {
        foreach ($parent in $parents) {
            $children = Get-ChildRows $parent
            if ($children.Count -eq 0) { $parent['HasChildren'] = $false; Set-ExpandState $parent; $empty.Add([string]$parent['Name']); continue }
            $parent['Expanded'] = $true; Set-ExpandState $parent
            foreach ($child in $children) { $child['Install'] = $true }
            $parent['Install'] = $false
        }
    } finally { $script:BulkUpdate = $false }
    Apply-FolderFilter
    if ($empty.Count -gt 0) {
        Show-HubMessage -Text ("Estas pastas não têm pastas dentro e continuam marcadas:`r`n" + ($empty -join "`r`n")) -Title 'Marcar pastas das subpastas' | Out-Null
    }
}

function Invoke-ApplyDefaults {
    if (Test-WorkerViewBusy) { return }
    Commit-Grid $script:UI.FolderGrid
    $rows = Get-CheckedRows $script:FolderRows 'Install'
    if ($rows.Count -eq 0) { return }
    $script:BulkUpdate = $true
    try {
        foreach ($row in $rows) {
            $row['Servidor'] = $script:UI.DefaultServerBox.Text.Trim()
            Set-RowVersionDefaults $row
        }
    } finally { $script:BulkUpdate = $false }
    Update-Selection
    $script:UI.ProgressText.Text = "Valores padrão aplicados a $($rows.Count) linha(s)."
}

# ---------------------------------------------------------------------------
# Instalacao em lote (sequencial, com fases acompanhadas por timer)
# ---------------------------------------------------------------------------
function Invoke-Install {
    if (Test-WorkerViewBusy) { return }
    Commit-Grid $script:UI.FolderGrid
    $pkg = $script:Package
    if ($null -eq $pkg) { Show-HubMessage -Text 'Selecione um pacote Worker.' -Title 'Pacote' -Kind Warning | Out-Null; return }
    try { $pkg = Get-WorkerPackage -Path $pkg.Path } catch { Show-HubMessage -Text $_.Exception.Message -Title 'Pacote inválido' -Kind Error | Out-Null; return }
    $root = $script:UI.RootBox.Text.Trim().TrimEnd('\')
    $rows = Get-CheckedRows $script:FolderRows 'Install'
    if ($rows.Count -eq 0) { return }
    $services = @(Get-WorkerInstalledService -All)
    $existingDisplay = Get-WorkerExistingDisplayNames
    $displays = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $tasks = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $rows) {
        Update-RowFolderState $row $services
        $folder = [string]$row['Path']
        $label = Get-RelativeName $folder
        if (-not (Test-WorkerInsideRoot -Folder $folder -Root $root)) { $problems.Add("${label}: pasta fora da raiz de instalação ou com link/junction."); continue }
        if ($row['FolderState'] -eq 'instalado') { $problems.Add("${label}: $($row['State']). Remova o serviço antes ou escolha outra pasta."); continue }
        $p = Get-RowParameters $row
        $bad = Test-WorkerParameters -Parameters $p -Label $label
        if ($bad.Count -gt 0) { $problems.AddRange([string[]]$bad); continue }
        $display = Resolve-WorkerDisplayName -Parameters $p
        if (-not $displays.Add($display)) { $problems.Add("${label}: nome de exibição repetido na seleção: $display"); continue }
        if ($existingDisplay.Contains($display)) { $problems.Add("${label}: já existe um serviço com o nome de exibição: $display"); continue }
        $tasks.Add([pscustomobject]@{
                Row = $row; Folder = $folder; Label = $label; Params = $p; Display = $display
                Phase = ''; Process = $null; ServiceName = ''; ConfigResult = ''; CopyLog = ''; DetailLog = ''; Deadline = $null
            })
    }
    $full = @($tasks | ForEach-Object { [IO.Path]::GetFullPath($_.Folder).TrimEnd('\') })
    foreach ($a in $full) { foreach ($b in $full) { if ($a -ne $b -and $b.StartsWith($a + '\', [StringComparison]::OrdinalIgnoreCase)) { $problems.Add("Pastas uma dentro da outra na seleção: $a e $b") } } }
    if ($problems.Count -gt 0) { Show-HubMessage -Text (Format-List $problems.ToArray() 20) -Title 'Corrija antes de instalar' -Kind Warning | Out-Null; return }
    if ($tasks.Count -eq 0) { return }

    $note = ''
    $pre = Test-WorkerPrerequisites -Version $pkg.Version
    if ($pre.Count -gt 0) { $note += "`r`n`r`nATENÇÃO (pré-requisitos):`r`n" + ($pre -join "`r`n") }
    $withFiles = @($tasks | Where-Object { $_.Row['FolderState'] -in @('arquivos', 'worker') })
    if ($withFiles.Count -gt 0) { $note += "`r`n`r`n$($withFiles.Count) pasta(s) já têm arquivos. Os arquivos do pacote vão sobrescrever os de mesmo nome (nada é apagado; configuração existente recebe backup):`r`n" + (Format-List @($withFiles | ForEach-Object { $_.Label })) }
    $start = [bool]$script:UI.StartAfterCheck.IsChecked
    $bulk = Get-BulkNote $tasks.Count (Get-HiddenCount @($tasks | ForEach-Object { $_.Row }))
    $confirm = $bulk + "Instalar $($tasks.Count) Worker(s) $($pkg.Version) a partir de:`r`n$($pkg.Path)`r`n`r`n" + (Format-List @($tasks | ForEach-Object { "$($_.Display)  ->  $($_.Folder)" }) 10) +
    "`r`n`r`nEm cada pasta: copia Lib\, gera a configuração a partir do modelo, cria o serviço$(if ($start) { ' e inicia' }). Instalações sequenciais não são revertidas automaticamente em caso de falha.$note`r`n`r`nDeseja continuar?"
    if ((Show-HubMessage -Text $confirm -Title 'Confirmar instalação' -Kind Question -YesNo) -ne 'Yes') { return }

    $script:SessionLog = New-HubLogFile -Directory $script:Settings.LogDirectory -Prefix 'Worker_Instalacao'
    Write-HubLog -Path $script:SessionLog -Message "PACOTE | Worker $($pkg.Version) | $($pkg.Path)"
    $script:InstallPackage = $pkg
    $script:InstallStart = $start
    foreach ($t in $tasks) { Set-RowState $t.Row 'Status' 'Na fila'; $t.Row['StatusTip'] = '' }
    $script:UI.Progress.Value = 0
    $script:Queue = $tasks.ToArray(); $script:QueuePosition = 0
    $script:Flags.Installing = $true; Update-Commands
    Start-NextInstallation
    if ($script:Flags.Installing) { $script:InstallTimer.Start() }
}

function Set-TaskFailed($Task, [string]$Text, [string]$Detail) {
    Set-RowState $Task.Row 'Status' $Text 'err'
    $Task.Row['StatusTip'] = $Detail
    Write-HubLog -Path $script:SessionLog -Message "FALHA | $($Task.Label) | $Text | $Detail"
    if ($null -ne $Task.Process) { try { $Task.Process.Dispose() } catch {}; $Task.Process = $null }
    $Task.Phase = 'done'
    $script:QueuePosition++
    Start-NextInstallation
}

function Set-TaskDone($Task, [string]$Text, [string]$Kind) {
    Set-RowState $Task.Row 'Status' $Text $Kind
    $Task.Row['StatusTip'] = "Serviço: $($Task.ServiceName)"
    Write-HubLog -Path $script:SessionLog -Message "RESULTADO | $($Task.Label) | $Text | $($Task.ServiceName) | $($Task.Display)"
    $Task.Phase = 'done'
    $script:QueuePosition++
    Start-NextInstallation
}

function Start-NextInstallation {
    if ($script:QueuePosition -ge $script:Queue.Count) { Finish-Installation; return }
    $t = $script:Queue[$script:QueuePosition]
    $script:CurrentTask = $t
    $n = $script:QueuePosition + 1
    $script:UI.ProgressText.Text = "Instalando $n/$($script:Queue.Count): $($t.Display)"
    $script:UI.Progress.Value = [int](($script:QueuePosition * 100) / $script:Queue.Count)
    Write-HubLog -Path $script:SessionLog -Message ("INICIO | {0} | {1} | Servidor={2} Sistema={3} Fila={4}" -f $t.Label, $t.Folder, $t.Params.Servidor, $t.Params.Sistema, $t.Params.Fila)
    $stamp = '{0:D3}_{1}' -f $n, (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
    $t.CopyLog = Join-Path $script:Settings.LogDirectory "Worker_${stamp}_copia.log"
    $t.DetailLog = Join-Path $script:Settings.LogDirectory "Worker_${stamp}_servico.log"
    Set-RowState $t.Row 'Status' 'Copiando arquivos...' 'run'
    try {
        $t.Process = Start-WorkerFileCopy -Package $script:InstallPackage -Folder $t.Folder -CopyLog $t.CopyLog
        $t.Phase = 'copy'
    } catch { Set-TaskFailed $t 'Falha (cópia)' $_.Exception.Message }
}

function Complete-CopyPhase($t) {
    $code = $t.Process.ExitCode
    $t.Process.Dispose(); $t.Process = $null
    Write-HubLog -Path $script:SessionLog -Message "COPIA | $($t.Label) | robocopy/saida=$code | $($t.CopyLog)"
    if (-not (Test-WorkerCopyExitCode $code)) { Set-TaskFailed $t "Falha (cópia, código $code)" "Veja $($t.CopyLog)"; return }
    if ($code -eq 20) { Write-HubLog -Path $script:SessionLog -Message "AVISO | $($t.Label) | alguns arquivos nao puderam ser desbloqueados" }
    Set-RowState $t.Row 'Status' 'Configurando...' 'run'
    Invoke-HubDoEvents
    try {
        if ($script:InstallPackage.Version -eq '23') {
            $t.ConfigResult = Set-Worker23Config -Folder $t.Folder -Parameters $t.Params -LogFile $script:SessionLog
            Set-RowState $t.Row 'Status' 'Criando serviço...' 'run'
            $t.Process = Start-Worker23ServiceInstall -Folder $t.Folder -Parameters $t.Params -DetailLog $t.DetailLog
            $t.Phase = 'register'
        } else {
            $t.ServiceName = New-WorkerServiceName -Version '25'
            $t.ConfigResult = Set-Worker25Config -Folder $t.Folder -Package $script:InstallPackage -ServiceName $t.ServiceName -Parameters $t.Params -LogFile $script:SessionLog
            Set-RowState $t.Row 'Status' 'Criando serviço...' 'run'
            New-Worker25Service -Folder $t.Folder -ServiceName $t.ServiceName -DisplayName $t.Display -LogFile $script:SessionLog
            Start-TaskService $t
        }
    } catch { Set-TaskFailed $t 'Falha (configuração/serviço)' $_.Exception.Message }
}

function Complete-RegisterPhase($t) {
    $code = $t.Process.ExitCode
    $t.Process.Dispose(); $t.Process = $null
    Write-HubLog -Path $script:SessionLog -Message "INSTALL TOPSHELF | $($t.Label) | codigo=$code | $($t.DetailLog)"
    if (-not (Test-Worker23InstallExitCode $code)) { Set-TaskFailed $t "Falha (instalação, código $code)" "Veja $($t.DetailLog)"; return }
    try {
        $svc = Find-WorkerServiceByFolder -Folder $t.Folder
        if ($null -eq $svc) { Set-TaskFailed $t 'Falha (serviço não encontrado)' "O instalador terminou (código $code), mas nenhum serviço aponta para a pasta. Veja $($t.DetailLog)"; return }
        $t.ServiceName = $svc.Name
        Set-WorkerDisplayName -Name $svc.Name -DisplayName $t.Display -LogFile $script:SessionLog
        Start-TaskService $t
    } catch { Set-TaskFailed $t 'Falha (serviço)' $_.Exception.Message }
}

function Start-TaskService($t) {
    if (-not $script:InstallStart) { Set-TaskDone $t 'Instalado (parado)' 'ok'; return }
    Set-RowState $t.Row 'Status' 'Iniciando...' 'run'
    try { Start-WorkerService -Name $t.ServiceName -LogFile $script:SessionLog }
    catch { Set-TaskDone $t 'Instalado, não iniciou' 'warn'; $t.Row['StatusTip'] = $_.Exception.Message; return }
    $t.Deadline = (Get-Date).AddSeconds(90)
    $t.Phase = 'start'
}

function Complete-StartPhase($t) {
    $state = Get-WorkerServiceState -Name $t.ServiceName
    if ($state -eq 'StartPending' -and (Get-Date) -lt $t.Deadline) { return }
    Write-HubLog -Path $script:SessionLog -Message "START | $($t.ServiceName) | $state"
    switch ($state) {
        'Running' { Set-TaskDone $t 'Sucesso (em execução)' 'ok' }
        'StartPending' { Set-TaskDone $t 'Instalado (ainda iniciando)' 'warn' }
        default { Set-TaskDone $t "Instalado, não iniciou ($state)" 'warn' }
    }
}

function On-InstallTick {
    $t = $script:CurrentTask
    if (-not $script:Flags.Installing -or $null -eq $t) { return }
    switch ($t.Phase) {
        'copy' { if ($t.Process.HasExited) { Complete-CopyPhase $t } }
        'register' { if ($t.Process.HasExited) { Complete-RegisterPhase $t } }
        'start' { Complete-StartPhase $t }
    }
}

function Finish-Installation {
    $script:InstallTimer.Stop()
    $script:Flags.Installing = $false
    $script:CurrentTask = $null
    $ok = @($script:Queue | Where-Object { $_.Row['StatusKind'] -eq 'ok' }).Count
    $warn = @($script:Queue | Where-Object { $_.Row['StatusKind'] -eq 'warn' }).Count
    $failed = @($script:Queue | Where-Object { $_.Row['StatusKind'] -eq 'err' }).Count
    $script:UI.Progress.Value = 100
    $script:UI.ProgressText.Text = "Lote concluído: $ok sucesso(s), $warn com aviso, $failed falha(s)."
    $services = @(Get-WorkerInstalledService -All)
    foreach ($t in $script:Queue) { Update-RowFolderState $t.Row $services }
    Update-Selection
    Refresh-Installed
    Show-HubMessage -Text "Instalação finalizada.`r`n`r`nSucesso: $ok`r`nCom aviso: $warn`r`nFalha: $failed`r`n`r`nPasse o mouse no Resultado para ver o detalhe.`r`nLog: $($script:SessionLog)" -Title 'Resultado da instalação' | Out-Null
}

# ---------------------------------------------------------------------------
# Workers instalados, remocao e login
# ---------------------------------------------------------------------------
function Get-StateKind([string]$State) {
    switch ($State) { 'Running' { 'ok' } 'Stopped' { '' } default { 'run' } }
}

function Refresh-Installed {
    if (Test-WorkerViewBusy) { return }
    $script:InstalledRows.Clear()
    try {
        foreach ($svc in @(Get-WorkerInstalledService)) {
            $row = New-Object BennerHub.HubRow
            $row['LoginSel'] = $false; $row['Remove'] = $false
            $row['Name'] = $svc.Name; $row['Display'] = $svc.DisplayName
            $row['Version'] = $(if ($svc.Version) { $svc.Version } else { '?' })
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
    if (Test-WorkerViewBusy) { return }
    Commit-Grid $script:UI.InstalledGrid
    $targets = Get-CheckedRows $script:InstalledRows 'Remove'
    if ($targets.Count -eq 0) { return }
    $root = $script:UI.RootBox.Text.Trim().TrimEnd('\')
    $deleteFolder = [bool]$script:UI.DeleteFolderCheck.IsChecked
    $items = @($targets | ForEach-Object { [pscustomobject]@{ Name = $_['Name']; Exe = $_['Exe']; Folder = $_['Folder'] } })
    $issues = Get-WorkerRemovalIssues -Services $items -Root $root -DeleteFolder $deleteFolder
    if ($issues.Count -gt 0) {
        $hint = $(if ($deleteFolder) { "`r`n`r`nA pasta só é apagada dentro da raiz de instalação ($root). Para remover só o serviço, desmarque 'Apagar também a pasta'." } else { '' })
        Show-HubMessage -Text ((Format-List $issues 15) + $hint) -Title 'Remoção bloqueada' -Kind Warning | Out-Null; return
    }
    $detail = Format-List @($targets | ForEach-Object { "$($_['Display'])  ->  $($_['Folder'])" }) 15
    $bulk = Get-BulkNote $targets.Count (Get-HiddenCount $targets)
    $what = $(if ($deleteFolder) { 'serviço(s) E suas pastas' } else { 'serviço(s) (as pastas serão mantidas)' })
    $msg = $bulk + "ATENÇÃO: remoção PERMANENTE de $($targets.Count) $what`:`r`n`r`n$detail`r`n`r`nIsso não pode ser desfeito. Continuar?"
    if ((Show-HubMessage -Text $msg -Title 'Confirmar exclusão' -Kind Warning -YesNo -DefaultNo) -ne 'Yes') { return }
    $log = New-HubLogFile -Directory $script:Settings.LogDirectory -Prefix 'Worker_Remocao'
    Set-InstalledBusy 'Removing' $true
    try {
        foreach ($row in $targets) {
            Set-RowState $row 'Result' 'Removendo...' 'run'
            Invoke-HubDoEvents
            try {
                Remove-WorkerService -Name $row['Name'] -Folder $row['Folder'] -Exe $row['Exe'] -Root $root -DeleteFolder $deleteFolder -LogFile $log -OnWait { Invoke-HubDoEvents }
                Set-RowState $row 'Result' $(if ($deleteFolder) { 'Removido + pasta' } else { 'Removido (pasta mantida)' }) 'ok'
            } catch {
                Set-RowState $row 'Result' 'Falha / verificar log' 'err'
            }
        }
    } finally {
        Set-InstalledBusy 'Removing' $false
    }
    $services = @(Get-WorkerInstalledService -All)
    foreach ($r in $script:FolderRows) { Update-RowFolderState $r $services }
    Show-HubMessage -Text "Remoção concluída. Consulte os resultados na grade e o log:`r`n$log" -Title 'Resultado da remoção' | Out-Null
}

function Invoke-ChangeLogin {
    if (Test-WorkerViewBusy) { return }
    Commit-Grid $script:UI.InstalledGrid
    $targets = Get-CheckedRows $script:InstalledRows 'LoginSel'
    if ($targets.Count -eq 0) { return }
    $account = ConvertTo-HubServiceAccount -Account $script:UI.AccountBox.Text
    $secure = $script:UI.PasswordInput.SecurePassword
    $log = $null
    $changed = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $grantError = $null
    try {
        $problem = Test-WorkerLogonInput -Account $account -Password $secure
        if ($problem) { Show-HubMessage -Text $problem -Title 'Dados de login' -Kind Warning | Out-Null; return }
        $names = Format-List @($targets | ForEach-Object { $_['Display'] }) 15
        $bulk = Get-BulkNote $targets.Count (Get-HiddenCount $targets)
        $question = $bulk + "Alterar a conta de logon de $($targets.Count) serviço(s) para $account ?`r`n`r`n$names`r`n`r`nOs serviços em execução precisam ser reiniciados para usar a nova conta."
        if ((Show-HubMessage -Text $question -Title 'Confirmar alteração de login' -Kind Question -YesNo -DefaultNo) -ne 'Yes') { return }
        $log = New-HubLogFile -Directory $script:Settings.LogDirectory -Prefix 'Worker_Logon'
        Set-InstalledBusy 'ChangingLogin' $true
        try {
            $grantError = Grant-WorkerLogonRight -Account $account -LogFile $log
            foreach ($row in $targets) {
                Set-RowState $row 'Result' 'Alterando login...' 'run'
                Invoke-HubDoEvents
                try {
                    $after = Set-WorkerServiceLogon -Name $row['Name'] -Account $account -Password $secure -LogFile $log
                    $row['StartName'] = [string]$after.StartName
                    Set-RowState $row 'Result' $(if ($grantError) { 'Login alterado (sem direito confirmado)' } else { 'Login alterado (não testado)' }) 'warn'
                    [void]$changed.Add([string]$row['Name'])
                } catch {
                    Set-RowState $row 'Result' 'Falha no login / ver log' 'err'
                }
            }
        } finally {
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
                if (Test-WorkerServiceStart -Name $row['Name'] -LogFile $log) {
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
function New-WorkerView {
    param([Parameter(Mandatory)]$Context)
    $xamlPath = Join-Path $PSScriptRoot 'Worker.View.xaml'
    $view = Import-HubXaml -Path $xamlPath
    $script:UI = Get-HubNamedElements -Root $view -XamlPath $xamlPath
    $script:UI.Window = $Context.Window
    $ui = $script:UI

    $ui.PackageBox.Text = $script:Settings.DefaultPackage
    $ui.RootBox.Text = $script:Settings.DefaultRoot
    $ui.DefaultUserBox.Text = $script:Settings.DefaultUser
    $ui.FolderGrid.ItemsSource = $script:FolderRows
    $ui.InstalledGrid.ItemsSource = $script:InstalledRows
    $visibleOnly = [Predicate[object]] { param($r) return ($r['Visible'] -eq $true) }
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:FolderRows).Filter = $visibleOnly
    [System.Windows.Data.CollectionViewSource]::GetDefaultView($script:InstalledRows).Filter = $visibleOnly
    Set-DefaultsForVersion '23'

    Add-HeaderCheck $ui.FolderGrid 0 'Install' 'Instalar' $script:FolderRows { Update-Selection }
    Add-HeaderCheck $ui.InstalledGrid 0 'LoginSel' 'Login' $script:InstalledRows { Update-InstalledSelection }
    Add-HeaderCheck $ui.InstalledGrid 1 'Remove' 'Remover' $script:InstalledRows { Update-InstalledSelection }

    $script:InstallTimer = New-HubTimer -IntervalMs 400 -OnTick {
        try { On-InstallTick }
        catch {
            $t = $script:CurrentTask
            if ($null -ne $t -and $t.Phase -ne 'done') { Set-TaskFailed $t 'Falha (erro inesperado)' $_.Exception.Message }
            else { Write-HubErrorLog -ErrorRecord $_ }
        }
    }

    $ui.PackageBrowse.Add_Click({ Invoke-HubSafe {
                $path = Select-HubFolder -Description 'Selecione a pasta do pacote Worker (com Lib\ ou com as pastas worker23/worker25)' -InitialPath $script:UI.PackageBox.Text
                if ($path) { $script:UI.PackageBox.Text = $path; Invoke-DetectPackages }
            } })
    $ui.PackageDetect.Add_Click({ Invoke-HubSafe { Invoke-DetectPackages } })
    $ui.PackageBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-HubSafe { Invoke-DetectPackages } } })
    $ui.RootBrowse.Add_Click({ Invoke-HubSafe {
                $path = Select-HubFolder -Description 'Selecione a raiz de instalação dos Workers' -InitialPath $script:UI.RootBox.Text
                if ($path) { $script:UI.RootBox.Text = $path; Invoke-ListFolders }
            } })
    $ui.ListButton.Add_Click({ Invoke-HubSafe { Invoke-ListFolders } })
    $ui.RootBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-HubSafe { Invoke-ListFolders } } })
    $ui.AddFolderButton.Add_Click({ Invoke-HubSafe { Invoke-AddFolder } })
    $ui.NewFolderBox.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-HubSafe { Invoke-AddFolder } } })
    $ui.CheckChildrenButton.Add_Click({ Invoke-HubSafe { Invoke-CheckChildren } -Title 'Falha ao marcar pastas' })
    $ui.ApplyDefaultsButton.Add_Click({ Invoke-HubSafe { Invoke-ApplyDefaults } })
    $ui.FolderGrid.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler] {
            param($s, $e)
            $src = $e.OriginalSource
            if ($src -is [System.Windows.Controls.Button] -and [string]$src.Tag -eq 'Expand' -and $src.DataContext -is [BennerHub.HubRow]) {
                $e.Handled = $true
                Invoke-HubSafe { Switch-RowExpanded $src.DataContext } -Title 'Falha ao abrir a pasta'
            }
        })
    $ui.FolderSearch.Add_TextChanged({ Invoke-HubSafe { Apply-FolderFilter } })
    $ui.InstalledSearch.Add_TextChanged({ Invoke-HubSafe { Apply-InstalledFilter } })
    foreach ($box in @($ui.FolderSearch, $ui.InstalledSearch)) {
        $box.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Escape') { $s.Clear(); $e.Handled = $true } })
    }
    $ui.LogsButton.Add_Click({ Invoke-HubSafe {
                New-Item -ItemType Directory -Path $script:Settings.LogDirectory -Force | Out-Null
                Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:Settings.LogDirectory)
            } })
    $ui.InstallButton.Add_Click({ Invoke-HubSafe { Invoke-Install } })
    $ui.RefreshButton.Add_Click({ Invoke-HubSafe { Refresh-Installed } })
    $ui.RemoveButton.Add_Click({ Invoke-HubSafe { Invoke-RemoveServices } })
    $ui.ChangeLoginButton.Add_Click({ Invoke-HubSafe { Invoke-ChangeLogin } })

    Refresh-Installed
    Invoke-HubSafe { Invoke-DetectPackages } -Title 'Falha ao detectar pacotes'
    if (Test-Path -LiteralPath $ui.RootBox.Text -PathType Container) { Invoke-HubSafe { Invoke-ListFolders } -Title 'Falha ao listar pastas' } else { Update-Selection }
    return $view
}

Export-ModuleMember -Function New-WorkerView, Test-WorkerViewBusy
