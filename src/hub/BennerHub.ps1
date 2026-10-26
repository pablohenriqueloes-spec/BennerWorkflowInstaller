#requires -Version 5.1
<#
HUB Benner: janela com menu de modulos de configuracao.
Execute via Iniciar-BennerHub.cmd (eleva, STA, ExecutionPolicy Bypass so neste processo).

Cada modulo fica em Modules\<Nome>\ com um module.psd1 (manifesto) que diz qual
arquivo monta a tela e qual funcao a cria. O HUB so carrega o modulo na primeira
vez que ele e aberto no menu. Ver docs/HUB.md.
#>

Add-Type -AssemblyName PresentationFramework

# A janela de console fica oculta: qualquer erro fatal na abertura vira mensagem
# na tela e fica registrado em %ProgramData%\Benner\Hub\BennerHub_erro.log.
trap {
    $msg = $_.Exception.Message
    try {
        $dir = Join-Path $env:ProgramData 'Benner\Hub'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $dir 'BennerHub_erro.log') -Encoding UTF8 -Value ("{0} {1}`r`n{2}" -f (Get-Date -Format o), $msg, $_.ScriptStackTrace)
    } catch {}
    [void][System.Windows.MessageBox]::Show("O HUB Benner não pôde ser aberto:`r`n`r`n$msg", 'Benner HUB', 'OK', 'Error')
    exit 1
}

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'O HUB precisa rodar em STA. Use Iniciar-BennerHub.cmd ou powershell.exe -STA -File BennerHub.ps1.'
}

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Core\BennerHub.Core.psm1') -Global -DisableNameChecking -Force

# Tema global: Application.Resources vale para a janela e para todas as telas de modulo.
$app = [System.Windows.Application]::Current
if ($null -eq $app) { $app = New-Object System.Windows.Application }
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$app.Resources.MergedDictionaries.Add((Import-HubXaml -Path (Join-Path $PSScriptRoot 'Core\Theme.xaml')))
# Rede de seguranca: erro nao tratado vira mensagem em vez de fechar o HUB.
$app.add_DispatcherUnhandledException({ param($s, $e)
        $e.Handled = $true
        Show-HubMessage -Text $e.Exception.Message -Title 'Erro inesperado' -Kind Error | Out-Null
    })

$shellPath = Join-Path $PSScriptRoot 'Core\HubShell.xaml'
$window = Import-HubXaml -Path $shellPath
$shell = Get-HubNamedElements -Root $window -XamlPath $shellPath
Set-HubOwnerWindow $window

# Logo: ao lado do HUB (pacote) ou em ..\..\assets (repositorio).
foreach ($candidate in @((Join-Path $PSScriptRoot 'benner-logo.png'), (Join-Path $PSScriptRoot '..\..\assets\benner-logo.png'))) {
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
    try {
        $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.StreamSource = New-Object System.IO.MemoryStream(, [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $candidate).Path))
        $bmp.EndInit()
        $shell.LogoImage.Source = $bmp
        $shell.LogoImage.Visibility = 'Visible'
        $shell.BrandText.Visibility = 'Collapsed'
    } catch {}
    break
}

$shell.MachineText.Text = $env:COMPUTERNAME
if (-not (Test-HubIsAdministrator)) {
    $shell.AdminDot.Fill = $app.FindResource('Brush.Error')
    $shell.AdminText.Text = 'Sem elevação'
}

# ---------------------------------------------------------------------------
# Modulos
# ---------------------------------------------------------------------------
$script:Modules = New-Object System.Collections.ArrayList
$modulesRoot = Join-Path $PSScriptRoot 'Modules'
$loadErrors = New-Object 'System.Collections.Generic.List[string]'
foreach ($dir in @(Get-ChildItem -LiteralPath $modulesRoot -Directory -ErrorAction SilentlyContinue)) {
    $manifestPath = Join-Path $dir.FullName 'module.psd1'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
    try {
        $m = Import-PowerShellDataFile -LiteralPath $manifestPath
        foreach ($key in 'Id', 'Name', 'View', 'Factory') { if (-not $m[$key]) { throw "chave '$key' ausente" } }
        [void]$script:Modules.Add([pscustomobject]@{
                Id = $m.Id; Name = $m.Name; Description = [string]$m.Description; Subtitle = [string]$m.Subtitle
                Order = $(if ($m.Order) { [int]$m.Order } else { 100 }); Glyph = [string]$m.Glyph
                Root = $dir.FullName; View = $m.View; Factory = $m.Factory; BusyFunction = [string]$m.BusyFunction
                Instance = $null
            })
    } catch { $loadErrors.Add("$($dir.Name): $($_.Exception.Message)") }
}
$script:Modules = @($script:Modules | Sort-Object Order, Name)

function Set-HubStatus([string]$Text) { $shell.StatusText.Text = $Text }

function New-NavItem([string]$Glyph, [string]$Text, $Tag) {
    $item = New-Object System.Windows.Controls.ListBoxItem
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Orientation = 'Horizontal'
    $icon = New-Object System.Windows.Controls.TextBlock
    $icon.FontFamily = New-Object System.Windows.Media.FontFamily('Segoe MDL2 Assets')
    $icon.FontSize = 15
    $icon.Width = 26
    $icon.VerticalAlignment = 'Center'
    if ($Glyph) { $icon.Text = [string][char][Convert]::ToInt32($Glyph, 16) }
    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $Text
    $label.VerticalAlignment = 'Center'
    [void]$panel.Children.Add($icon); [void]$panel.Children.Add($label)
    $item.Content = $panel
    $item.Tag = $Tag
    return $item
}

function New-HomeView {
    $scroll = New-Object System.Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $stack = New-Object System.Windows.Controls.StackPanel
    $stack.Margin = '28,4,28,20'
    $intro = New-Object System.Windows.Controls.TextBlock
    $intro.Text = 'Escolha um módulo de configuração. Cada módulo pode ser aberto pelo menu à esquerda ou pelos cartões abaixo.'
    $intro.Foreground = $app.FindResource('Brush.Muted')
    $intro.TextWrapping = 'Wrap'
    $intro.Margin = '0,0,0,18'
    [void]$stack.Children.Add($intro)
    $wrap = New-Object System.Windows.Controls.WrapPanel
    foreach ($m in $script:Modules) {
        $card = New-Object System.Windows.Controls.Border
        $card.Style = $app.FindResource('Card')
        $card.Width = 330
        $card.Margin = '0,0,14,14'
        $inner = New-Object System.Windows.Controls.StackPanel
        $eyebrow = New-Object System.Windows.Controls.TextBlock
        $eyebrow.Text = 'MÓDULO'; $eyebrow.Style = $app.FindResource('Text.Eyebrow'); $eyebrow.HorizontalAlignment = 'Left'
        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $m.Name; $title.Style = $app.FindResource('Text.Section'); $title.HorizontalAlignment = 'Left'; $title.Margin = '0,4,0,6'
        $desc = New-Object System.Windows.Controls.TextBlock
        $desc.Text = $m.Description; $desc.Foreground = $app.FindResource('Brush.Muted'); $desc.TextWrapping = 'Wrap'; $desc.MinHeight = 38
        $open = New-Object System.Windows.Controls.Button
        $open.Content = "Abrir $($m.Name)"; $open.Style = $app.FindResource('Btn.Primary'); $open.HorizontalAlignment = 'Left'; $open.Margin = '0,14,0,0'
        $open.Tag = $m.Id
        $open.Add_Click({ param($s, $e) Invoke-HubSafe { Select-HubPage $s.Tag } })
        foreach ($c in $eyebrow, $title, $desc, $open) { [void]$inner.Children.Add($c) }
        $card.Child = $inner
        [void]$wrap.Children.Add($card)
    }
    [void]$stack.Children.Add($wrap)
    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Text = "Novos módulos: crie uma pasta em $modulesRoot com um module.psd1. Veja docs\HUB.md."
    $hint.Foreground = $app.FindResource('Brush.Muted'); $hint.FontSize = 11.5; $hint.TextWrapping = 'Wrap'; $hint.Margin = '0,6,0,0'
    [void]$stack.Children.Add($hint)
    $scroll.Content = $stack
    return $scroll
}

$script:HomeView = $null

function Select-HubPage([string]$Id) {
    foreach ($item in $shell.NavList.Items) {
        if ([string]$item.Tag -eq $Id -and -not $item.IsSelected) { $item.IsSelected = $true; return }
    }
    Show-HubPage $Id
}

function Show-HubPage([string]$Id) {
    if ($Id -eq 'home') {
        if ($null -eq $script:HomeView) { $script:HomeView = New-HomeView }
        $shell.PageEyebrow.Text = 'HUB BENNER'
        $shell.PageTitle.Text = 'Início'
        $shell.PageSubtitle.Text = "$($script:Modules.Count) módulo(s) disponível(is)"
        $shell.ModuleHost.Content = $script:HomeView
        return
    }
    $m = $script:Modules | Where-Object { $_.Id -eq $Id } | Select-Object -First 1
    if ($null -eq $m) { return }
    if ($null -eq $m.Instance) {
        Set-HubStatus "Carregando $($m.Name)..."
        $window.Cursor = [System.Windows.Input.Cursors]::Wait
        try {
            Import-Module (Join-Path $m.Root $m.View) -Global -DisableNameChecking -Force
            $context = [pscustomobject]@{ Window = $window; HubRoot = $PSScriptRoot; ModuleRoot = $m.Root; Manifest = $m }
            $m.Instance = & $m.Factory -Context $context
        } finally {
            $window.Cursor = $null
            Set-HubStatus 'Pronto'
        }
    }
    $shell.PageEyebrow.Text = 'MÓDULO'
    $shell.PageTitle.Text = $m.Name
    $shell.PageSubtitle.Text = $m.Subtitle
    $shell.ModuleHost.Content = $m.Instance
}

[void]$shell.NavList.Items.Add((New-NavItem 'E80F' 'Início' 'home'))
foreach ($m in $script:Modules) { [void]$shell.NavList.Items.Add((New-NavItem $m.Glyph $m.Name $m.Id)) }
$shell.NavList.Add_SelectionChanged({
        $item = $shell.NavList.SelectedItem
        if ($null -ne $item) { Invoke-HubSafe { Show-HubPage ([string]$item.Tag) } -Title 'Falha ao abrir módulo' }
    })

# Nao fechar com lote em andamento em nenhum modulo carregado.
$window.Add_Closing({ param($s, $e)
        foreach ($m in $script:Modules) {
            if ($null -eq $m.Instance -or -not $m.BusyFunction) { continue }
            if (& $m.BusyFunction) {
                $e.Cancel = $true
                Show-HubMessage -Text "Aguarde o fim da operação em andamento no módulo $($m.Name) antes de fechar." -Title 'Operação em andamento' | Out-Null
                return
            }
        }
    })

# Abre direto no unico modulo quando so existe um; senao, no Inicio.
$window.Add_Loaded({
        if ($loadErrors.Count -gt 0) {
            Show-HubMessage -Text ("Alguns módulos não foram carregados:`r`n" + ($loadErrors -join "`r`n")) -Title 'Módulos' -Kind Warning | Out-Null
        }
        $start = $(if ($script:Modules.Count -eq 1) { $script:Modules[0].Id } else { 'home' })
        Select-HubPage $start
    })

[void]$window.ShowDialog()
$app.Shutdown()
