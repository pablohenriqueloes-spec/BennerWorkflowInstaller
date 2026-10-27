#requires -Version 5.1
<#
Modulo Workflow do HUB Benner: cada etapa da configuracao como funcao independente,
sem nenhuma dependencia da tela. A tela (Workflow.View.psm1) so chama estas funcoes,
e qualquer outro script pode chamar as mesmas funcoes direto. Exemplo:

    Import-Module .\Modules\Workflow\Workflow.Core.psm1
    $log = New-HubLogFile -Directory (Get-WorkflowSettings).LogDirectory -Prefix 'Workflow_Script'
    Find-WorkflowFolder -Root 'E:\Benner\WFL' | ForEach-Object {
        Install-WorkflowService -Name $_.SuggestedName -Exe $_.Exe -LogFile $log `
            -SuperServerHost 'servidor' -SystemName $_.Second -User 'SYSDBA' -NotifySenderUser 'SYSDBA'
    }

Mais exemplos em docs/HUB.md.
#>

if (-not (Get-Module -Name 'BennerHub.Core')) {
    Import-Module (Join-Path $PSScriptRoot '..\..\Core\BennerHub.Core.psm1') -Global -DisableNameChecking
}

$script:Settings = [pscustomobject]@{
    ExeName      = 'Benner.Tecnologia.Workflow.Runtime.Application.exe'
    InstallUtil  = (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\InstallUtil.exe')
    LogDirectory = (Join-Path $env:ProgramData 'Benner\WorkflowInstaller\Logs')
    DefaultRoot  = 'E:\Benner\WFL'
    CopySource   = 'E:\Benner\WorkflowService'
    CopyTarget   = 'E:\Benner\Ferramentas\WFL'
    DefaultUser  = 'SYSDBA'
    ServiceMatch = '*Workflow Service*'
}

function Get-WorkflowSettings {
    <# Constantes do modulo (nome do executavel, InstallUtil, pasta de logs, padroes). #>
    return $script:Settings
}

# ---------------------------------------------------------------------------
# Etapa 0: criar/atualizar pastas a partir de uma origem (copiar e substituir)
# A copia usa o robocopy do Windows (/E /IS /IT: tudo, inclusive arquivos iguais,
# sobrescrevendo; /XJ: nao segue junctions). Antes, cada .config que sera
# substituido recebe backup <arquivo>.backup_<data>.
# ---------------------------------------------------------------------------
function Get-WorkflowCopyTarget {
    <#
    Subpastas diretas de -Root (sem junctions/links), com a quantidade de .config no primeiro nivel
    e HasChildren (se ha pastas dentro dela). Serve tanto para a raiz de destino quanto para abrir uma subpasta.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $base = $Root.Trim().TrimEnd('\')
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "Pasta de destino nao encontrada: $base" }
    foreach ($dir in @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction Stop | Sort-Object Name)) {
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $configs = @(Get-ChildItem -LiteralPath $dir.FullName -File -Filter '*.config' -Force -ErrorAction SilentlyContinue)
        $children = @(Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 })
        [pscustomobject]@{ Name = $dir.Name; Path = $dir.FullName; ConfigCount = $configs.Count; HasChildren = ($children.Count -gt 0) }
    }
}

function Test-WorkflowFolderName {
    <# Nome simples de pasta (sem caminho): nao vazio, sem \ / : * ? " < > |, diferente de . e .., sem espaco/ponto no fim. #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -match '[\\/:*?"<>|]' -or $Name -eq '.' -or $Name -eq '..' -or $Name -match '[ .]$') { return $false }
    return ($Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0)
}

function New-WorkflowTargetFolder {
    <#
    Cria -Name dentro de -Parent (pasta vazia). Nao segue junctions: recusa -Parent que seja link.
    Devolve Path e Created ($false quando ja existia).
    #>
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Name, [string]$LogFile)
    if (-not (Test-WorkflowFolderName -Name $Name)) { throw "Nome de pasta invalido: '$Name'" }
    $item = Get-Item -LiteralPath $Parent -Force -ErrorAction Stop
    if (-not $item.PSIsContainer) { throw "Nao e uma pasta: $Parent" }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Pasta e um link/junction, nao sera usada: $Parent" }
    $path = Join-Path $item.FullName $Name
    if (Test-Path -LiteralPath $path -PathType Container) { return [pscustomobject]@{ Path = $path; Created = $false } }
    if (Test-Path -LiteralPath $path) { throw "Ja existe um arquivo com esse nome: $path" }
    New-Item -ItemType Directory -Path $path -ErrorAction Stop | Out-Null
    if ($LogFile) { Write-HubLog -Path $LogFile -Message "PASTA CRIADA | $path" }
    return [pscustomobject]@{ Path = $path; Created = $true }
}

function Test-WorkflowCopyPaths {
    <# Problemas que impedem copiar de -Source para -Destination (vazio = pode copiar). #>
    param([string]$Source, [string]$Destination)
    $problems = New-Object 'System.Collections.Generic.List[string]'
    if ([string]::IsNullOrWhiteSpace($Source) -or -not (Test-Path -LiteralPath $Source -PathType Container)) { $problems.Add("Pasta de origem nao encontrada: $Source"); return , $problems.ToArray() }
    if ([string]::IsNullOrWhiteSpace($Destination)) { $problems.Add('Destino vazio.'); return , $problems.ToArray() }
    try {
        $src = [IO.Path]::GetFullPath($Source).TrimEnd('\')
        $dst = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    } catch { $problems.Add("Caminho invalido: $Destination"); return , $problems.ToArray() }
    if ($dst -ieq $src) { $problems.Add("Destino igual a origem: $dst") }
    elseif ($dst.StartsWith($src + '\', [StringComparison]::OrdinalIgnoreCase)) { $problems.Add("Destino dentro da origem: $dst") }
    elseif ($src.StartsWith($dst + '\', [StringComparison]::OrdinalIgnoreCase)) { $problems.Add("Origem dentro do destino: $dst") }
    if ($dst.Length -le 3) { $problems.Add("Destino nao pode ser a raiz de um disco: $dst") }
    if ($src.Length -le 3) { $problems.Add("Origem nao pode ser a raiz de um disco: $src") }
    return , $problems.ToArray()
}

function Get-WorkflowSourceConfigFiles {
    <# Caminhos relativos (a partir da origem) de todos os *.config da origem. #>
    param([Parameter(Mandatory)][string]$Source)
    $src = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $list = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -Filter '*.config' -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -notlike '*.config') { continue }
        $list.Add($f.FullName.Substring($src.Length + 1))
    }
    return , $list.ToArray()
}

function Get-WorkflowCopyPlan {
    <#
    O que a copia vai fazer com os .config de um destino:
    Replaced = .config que ja existem no destino e serao substituidos; New = .config que serao criados.
    Passe -SourceConfigs (de Get-WorkflowSourceConfigFiles) para nao varrer a origem a cada destino.
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [string[]]$SourceConfigs)
    if ($null -eq $SourceConfigs) { $SourceConfigs = Get-WorkflowSourceConfigFiles -Source $Source }
    $dst = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    $exists = Test-Path -LiteralPath $dst -PathType Container
    $replaced = New-Object 'System.Collections.Generic.List[string]'
    $new = New-Object 'System.Collections.Generic.List[string]'
    foreach ($rel in $SourceConfigs) {
        if ($exists -and (Test-Path -LiteralPath (Join-Path $dst $rel) -PathType Leaf)) { $replaced.Add($rel) } else { $new.Add($rel) }
    }
    return [pscustomobject]@{ Destination = $dst; Exists = $exists; Replaced = $replaced.ToArray(); New = $new.ToArray() }
}

function Backup-WorkflowConfigFiles {
    <# Copia cada .config (relativo ao destino) para <arquivo>.backup_<data>. Devolve a quantidade. #>
    param([Parameter(Mandatory)][string]$Destination, [string[]]$RelativePaths, [string]$LogFile)
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss_fff'
    $n = 0
    foreach ($rel in @($RelativePaths)) {
        $file = Join-Path $Destination $rel
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { continue }
        Copy-Item -LiteralPath $file -Destination ($file + '.backup_' + $stamp) -Force -ErrorAction Stop
        Write-HubLog -Path $LogFile -Message "BACKUP .config | $file -> $file.backup_$stamp"
        $n++
    }
    return $n
}

function Start-WorkflowFolderCopy {
    <#
    Cria o destino se preciso e inicia o robocopy (copiar e substituir) em processo oculto.
    -ExcludeConfigs: caminhos relativos de .config que NAO devem ser copiados (mantem os atuais).
    Devolve o Process. Codigo de saida do robocopy: 0 a 7 = sucesso, 8 ou mais = falha.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$RobocopyLog,
        [string[]]$ExcludeConfigs = @()
    )
    $problems = Test-WorkflowCopyPaths -Source $Source -Destination $Destination
    if ($problems.Count -gt 0) { throw ($problems -join [Environment]::NewLine) }
    $src = [IO.Path]::GetFullPath($Source).TrimEnd('\')
    $dst = [IO.Path]::GetFullPath($Destination).TrimEnd('\')
    New-Item -ItemType Directory -Path $dst -Force -ErrorAction Stop | Out-Null
    $robocopy = Join-Path $env:WINDIR 'System32\robocopy.exe'
    $arguments = '"{0}" "{1}" /E /IS /IT /XJ /R:2 /W:2 /NP /NDL /UNILOG+:"{2}"' -f $src, $dst, $RobocopyLog
    $exclude = @($ExcludeConfigs | Where-Object { $_ } | ForEach-Object { '"{0}"' -f (Join-Path $src $_) })
    if ($exclude.Count -gt 0) { $arguments += ' /XF ' + ($exclude -join ' ') }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $robocopy
    $psi.Arguments = $arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    return $p
}

function Get-WorkflowServicesInFolder {
    <# Workflow Services cujo executavel esta dentro de -Folder (para avisar sobre arquivos em uso). #>
    <# -Services: lista ja obtida com Get-WorkflowInstalledService (evita consultar o Windows a cada pasta). #>
    param([Parameter(Mandatory)][string]$Folder, [object[]]$Services)
    if ($null -eq $Services) { $Services = @(Get-WorkflowInstalledService) }
    $dst = [IO.Path]::GetFullPath($Folder).TrimEnd('\')
    return @($Services | Where-Object {
            $_.Folder -and ($_.Folder.TrimEnd('\') -ieq $dst -or $_.Folder.StartsWith($dst + '\', [StringComparison]::OrdinalIgnoreCase))
        })
}

function Copy-WorkflowFolder {
    <#
    Versao sincrona para scripts: copia e substitui -Source em -Destination.
    Por padrao substitui tambem os .config (com backup); -KeepConfigs mantem os atuais.
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$LogFile, [switch]$KeepConfigs)
    $plan = Get-WorkflowCopyPlan -Source $Source -Destination $Destination
    if (-not $KeepConfigs) { [void](Backup-WorkflowConfigFiles -Destination $plan.Destination -RelativePaths $plan.Replaced -LogFile $LogFile) }
    $robolog = [IO.Path]::ChangeExtension($LogFile, $null).TrimEnd('.') + '_robocopy.log'
    $p = Start-WorkflowFolderCopy -Source $Source -Destination $Destination -RobocopyLog $robolog -ExcludeConfigs $(if ($KeepConfigs) { $plan.Replaced } else { @() })
    try { $p.WaitForExit(); $code = $p.ExitCode } finally { $p.Dispose() }
    Write-HubLog -Path $LogFile -Message ("COPIA | {0} -> {1} | robocopy={2} | .config substituidos={3} | mantidos={4}" -f $Source, $plan.Destination, $code, $(if ($KeepConfigs) { 0 } else { $plan.Replaced.Count }), $(if ($KeepConfigs) { $plan.Replaced.Count } else { 0 }))
    return [pscustomobject]@{ Destination = $plan.Destination; ExitCode = $code; Success = ($code -lt 8); Plan = $plan }
}

# ---------------------------------------------------------------------------
# Etapa 1: descoberta
# ---------------------------------------------------------------------------
function Get-WorkflowServiceName {
    <# Nome sugerido: VAR1_VAR2 ou apenas VAR2. #>
    param([Parameter(Mandatory)][string]$First, [Parameter(Mandatory)][string]$Second, [bool]$IncludeFirst = $true)
    if ($IncludeFirst) { return ('{0}_{1}' -f $First, $Second) }
    return $Second
}

function Test-WorkflowServiceName {
    <# Letras, numeros, _ . - e no maximo 230 caracteres. #>
    param([string]$Name)
    return (-not [string]::IsNullOrWhiteSpace($Name)) -and $Name.Length -le 230 -and ($Name -match '^[a-zA-Z0-9_.-]+$')
}

function Get-WorkflowConfigState {
    <# 'config' (ja existe), 'modelo' (sera gerado do .config.modelo) ou 'ausente'. #>
    param([Parameter(Mandatory)][string]$Exe)
    if (Test-Path -LiteralPath ($Exe + '.config') -PathType Leaf) { return 'config' }
    if (Test-Path -LiteralPath ($Exe + '.config.modelo') -PathType Leaf) { return 'modelo' }
    return 'ausente'
}

function Find-WorkflowFolder {
    <#
    Procura <Raiz>\VAR1\VAR2\ contendo o executavel do Runtime.
    Pastas que nao puderam ser lidas viram avisos (Write-Warning); use -WarningVariable para coletar.
    #>
    param([Parameter(Mandatory)][string]$Root, [bool]$IncludeFirst = $true)
    $base = $Root.Trim().TrimEnd('\')
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "Diretorio base nao encontrado: $base" }
    foreach ($parent in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction Stop | Sort-Object Name)) {
        try {
            foreach ($child in @(Get-ChildItem -LiteralPath $parent.FullName -Directory -ErrorAction Stop | Sort-Object Name)) {
                $exe = Join-Path $child.FullName $script:Settings.ExeName
                if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { continue }
                [pscustomobject]@{
                    First         = $parent.Name
                    Second        = $child.Name
                    Folder        = $child.FullName
                    Exe           = $exe
                    SuggestedName = (Get-WorkflowServiceName -First $parent.Name -Second $child.Name -IncludeFirst $IncludeFirst)
                    ConfigState   = (Get-WorkflowConfigState -Exe $exe)
                }
            }
        } catch { Write-Warning "$($parent.FullName): $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------------
# Etapa 2: .exe.config
# ---------------------------------------------------------------------------
function Test-WorkflowConfigValues {
    <# Devolve a lista de problemas (vazia = valores validos). #>
    param([string]$SuperServerHost, [string]$SystemName, [string]$User, [string]$NotifySenderUser, [string]$Label = '')
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $suffix = $(if ($Label) { " para '$Label'" } else { '' })
    if ([string]::IsNullOrWhiteSpace($SuperServerHost) -or $SuperServerHost.Trim() -notmatch '^[a-zA-Z0-9_.-]+(:[0-9]{1,5})?$') { $problems.Add("Benner Server invalido ou vazio$suffix.") }
    if ([string]::IsNullOrWhiteSpace($SystemName)) { $problems.Add("SYSTEMNAME vazio$suffix.") }
    if ([string]::IsNullOrWhiteSpace($User)) { $problems.Add("Usuario vazio$suffix.") }
    if ([string]::IsNullOrWhiteSpace($NotifySenderUser)) { $problems.Add("Usuario de notificacao vazio$suffix.") }
    return , $problems.ToArray()
}

function Set-WorkflowConfig {
    <#
    Grava somente superServerHost, systemName, user e notifySenderUser, preservando o resto
    (inclusive passEncrypted). Devolve 'atualizado' (com backup) ou 'gerado' (a partir do modelo).

    Sem .config, reproduz o primeiro salvamento do Configurar.exe (verificado no assembly):
    o Configurar renomeia o .config.modelo para .config, grava os campos da tela, define
    passwordAuth=false e remove a chave 'pass'. O passEncrypted do modelo fica intacto e
    o servico so o le quando passwordAuth=true. Aqui o modelo e copiado (nao movido) e o
    .config so e gravado depois de todo o XML validado.
    #>
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$SuperServerHost,
        [Parameter(Mandatory)][string]$SystemName,
        [Parameter(Mandatory)][string]$User,
        [Parameter(Mandatory)][string]$NotifySenderUser,
        [string]$LogFile
    )
    $cfg = $Exe + '.config'
    $model = $cfg + '.modelo'
    $fromModel = -not (Test-Path -LiteralPath $cfg -PathType Leaf)
    if ($fromModel -and -not (Test-Path -LiteralPath $model -PathType Leaf)) { throw "Arquivo de configuracao nao encontrado: $cfg (nem modelo: $model)" }
    $source = $(if ($fromModel) { $model } else { $cfg })
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($source)
    $node = $doc.SelectSingleNode('/configuration/appSettings')
    if ($null -eq $node) { throw "Secao appSettings nao encontrada: $source" }
    $values = [ordered]@{ superServerHost = $SuperServerHost; systemName = $SystemName; user = $User; notifySenderUser = $NotifySenderUser }
    if ($fromModel) { $values['passwordAuth'] = 'false' }
    # Atualizacao estrita: cada chave precisa existir uma unica vez.
    foreach ($key in $values.Keys) {
        $found = @($node.SelectNodes('add') | Where-Object { $_.GetAttribute('key') -ceq $key })
        if ($found.Count -ne 1) { throw "Chave '$key' ausente ou duplicada em $source" }
        $found[0].SetAttribute('value', [string]$values[$key])
    }
    if ($fromModel) {
        foreach ($old in @($node.SelectNodes('add') | Where-Object { $_.GetAttribute('key') -ceq 'pass' })) { [void]$node.RemoveChild($old) }
        try { $doc.Save($cfg) }
        catch { Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue; throw }
        Write-HubLog -Path $LogFile -Message ("CONFIG GERADO DO MODELO | Arquivo: {0} | Modelo: {1} | superServerHost={2} | systemName={3} | user={4} | notifySenderUser={5} | passwordAuth=false" -f $cfg, $model, $SuperServerHost, $SystemName, $User, $NotifySenderUser)
        return 'gerado'
    }
    $backup = $cfg + '.backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
    Copy-Item -LiteralPath $cfg -Destination $backup -ErrorAction Stop
    try { $doc.Save($cfg) }
    catch { Copy-Item -LiteralPath $backup -Destination $cfg -Force -ErrorAction SilentlyContinue; throw }
    Write-HubLog -Path $LogFile -Message ("CONFIG OK | Arquivo: {0} | Backup: {1} | superServerHost={2} | systemName={3} | user={4} | notifySenderUser={5}" -f $cfg, $backup, $SuperServerHost, $SystemName, $User, $NotifySenderUser)
    return 'atualizado'
}

function Find-WorkflowConfigurator {
    <# Procura Configurar.exe na pasta do Workflow, na pasta pai ou nas pastas extras informadas. #>
    param([Parameter(Mandatory)][string]$Exe, [string[]]$ExtraFolders = @())
    $folder = [IO.Path]::GetDirectoryName($Exe)
    $candidates = @((Join-Path $folder 'Configurar.exe'), (Join-Path (Split-Path $folder -Parent) 'Configurar.exe')) + @($ExtraFolders | ForEach-Object { Join-Path $_ 'Configurar.exe' })
    return @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
}

# ---------------------------------------------------------------------------
# Etapa 3: instalacao (InstallUtil /sys=<nome> <exe>)
# ---------------------------------------------------------------------------
function Get-WorkflowInstallCommand {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Exe)
    return ('"{0}" /sys={1} "{2}"' -f $script:Settings.InstallUtil, $Name, $Exe)
}

function Get-WorkflowExistingServiceNames {
    <# Nomes internos de todos os servicos do Windows (para checar duplicados). #>
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    Add-Type -AssemblyName System.ServiceProcess
    foreach ($svc in [System.ServiceProcess.ServiceController]::GetServices()) { [void]$set.Add($svc.ServiceName) }
    return , $set
}

$script:InstallChildCode = @'
$ErrorActionPreference='Continue'
$util=$args[0]
$name=$args[1]
$exe=$args[2]
$log=$args[3]
try {
    & $util ("/sys="+$name) $exe *> $log
    if($null -eq $LASTEXITCODE){exit 1}
    exit ([int]$LASTEXITCODE)
} catch {
    $_ | Out-String | Add-Content -LiteralPath $log
    exit 1
}
'@

function Start-WorkflowInstall {
    <#
    Inicia o InstallUtil em processo filho oculto e devolve o Process (nao espera).
    A saida do InstallUtil vai para -DetailLog. Codigo de saida 0 = sucesso.
    #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string]$DetailLog)
    if (-not (Test-Path -LiteralPath $script:Settings.InstallUtil -PathType Leaf)) { throw "InstallUtil nao encontrado: $($script:Settings.InstallUtil)" }
    return Start-HubPowerShellProcess -Code $script:InstallChildCode -Arguments @($script:Settings.InstallUtil, $Name, $Exe, $DetailLog) -WorkingDirectory ([IO.Path]::GetDirectoryName($Exe))
}

function Write-WorkflowInstallResult {
    <# Registra no log da sessao o resultado de uma instalacao, com a saida do InstallUtil. #>
    param([string]$SessionLog, [string]$Name, [string]$Exe, [int]$ExitCode, [string]$DetailLog)
    $detail = ''
    if ($DetailLog -and (Test-Path -LiteralPath $DetailLog)) { try { $detail = [IO.File]::ReadAllText($DetailLog) } catch {} }
    $state = $(if ($ExitCode -eq 0) { 'SUCESSO' } else { 'FALHA' })
    $entry = (@(
            ('=' * 80), "Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "Servico: $Name", "Executavel: $Exe",
            ('Comando: ' + (Get-WorkflowInstallCommand -Name $Name -Exe $Exe)),
            "Resultado: $state | Codigo: $ExitCode | Log detalhado: $DetailLog", $detail
        ) -join [Environment]::NewLine)
    Write-HubLog -Path $SessionLog -Message $entry -NoTimestamp
}

function Install-WorkflowService {
    <#
    Versao sincrona para scripts: (opcional) grava o .config e instala, esperando o fim.
    Informe os quatro valores do .config para edita-lo antes; sem eles, so instala.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$LogFile,
        [string]$SuperServerHost, [string]$SystemName, [string]$User, [string]$NotifySenderUser
    )
    if (-not (Test-WorkflowServiceName -Name $Name)) { throw "Nome invalido: '$Name'." }
    if ((Get-WorkflowExistingServiceNames).Contains($Name)) { throw "Ja existe um servico no Windows com nome: $Name" }
    $configResult = ''
    if ($SuperServerHost) {
        $problems = Test-WorkflowConfigValues -SuperServerHost $SuperServerHost -SystemName $SystemName -User $User -NotifySenderUser $NotifySenderUser -Label $Name
        if ($problems.Count -gt 0) { throw ($problems -join [Environment]::NewLine) }
        if ((Get-WorkflowConfigState -Exe $Exe) -ne 'ausente') {
            $configResult = Set-WorkflowConfig -Exe $Exe -SuperServerHost $SuperServerHost -SystemName $SystemName -User $User -NotifySenderUser $NotifySenderUser -LogFile $LogFile
        }
    }
    $detail = [IO.Path]::ChangeExtension($LogFile, $null).TrimEnd('.') + "_$Name.install.log"
    $p = Start-WorkflowInstall -Name $Name -Exe $Exe -DetailLog $detail
    try { $p.WaitForExit(); $code = $p.ExitCode } finally { $p.Dispose() }
    Write-WorkflowInstallResult -SessionLog $LogFile -Name $Name -Exe $Exe -ExitCode $code -DetailLog $detail
    return [pscustomobject]@{ Name = $Name; Exe = $Exe; ExitCode = $code; Success = ($code -eq 0); ConfigResult = $configResult; DetailLog = $detail }
}

# ---------------------------------------------------------------------------
# Etapa 4: desbloqueio (remove somente Zone.Identifier / Mark of the Web)
# Nao altera ACLs e nao libera locks de processos. Nao segue junctions/reparse points.
# ---------------------------------------------------------------------------
$script:UnblockChildCode = @'
$folder=$args[0]
$log=$args[1]
$ErrorActionPreference='Stop'
$count=0; $failed=0; $visited=0
$dirs=New-Object 'System.Collections.Generic.Stack[string]'
$dirs.Push($folder)
try {
    while($dirs.Count -gt 0) {
        $current=$dirs.Pop()
        foreach($item in @(Get-ChildItem -LiteralPath $current -Force -ErrorAction Stop)) {
            if(($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0){continue}
            if($item.PSIsContainer){$dirs.Push($item.FullName);continue}
            $visited++
            try {
                $ads=Get-Item -LiteralPath $item.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue
                if($null -ne $ads){
                    Unblock-File -LiteralPath $item.FullName -ErrorAction Stop
                    $count++
                }
            } catch { $failed++; Add-Content -LiteralPath $log -Value ("FALHA: {0}: {1}" -f $item.FullName,$_.Exception.Message) }
        }
    }
} catch {
    $failed++
    Add-Content -LiteralPath $log -Value ("FALHA AO PERCORRER: {0}" -f $_.Exception.Message)
}
Add-Content -LiteralPath $log -Value ("Pasta: {0}; Inspecionados: {1}; Desbloqueados: {2}; Falhas: {3}" -f $folder,$visited,$count,$failed)
if($failed -gt 0){exit 1} else {exit 0}
'@

function Start-WorkflowUnblock {
    <# Inicia o desbloqueio recursivo da pasta em processo filho e devolve o Process. #>
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$LogFile)
    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { throw "Pasta nao encontrada: $Folder" }
    return Start-HubPowerShellProcess -Code $script:UnblockChildCode -Arguments @($Folder, $LogFile) -WorkingDirectory $Folder
}

function Unblock-WorkflowFolder {
    <# Versao sincrona: desbloqueia e devolve $true se nao houve falhas. #>
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$LogFile)
    $p = Start-WorkflowUnblock -Folder $Folder -LogFile $LogFile
    try { $p.WaitForExit(); return ($p.ExitCode -eq 0) } finally { $p.Dispose() }
}

# ---------------------------------------------------------------------------
# Etapa 5: servicos instalados
# ---------------------------------------------------------------------------
function Test-WorkflowServiceMatch {
    param($Service)
    return ($Service.Name -like $script:Settings.ServiceMatch -or $Service.DisplayName -like $script:Settings.ServiceMatch)
}

function Get-WorkflowInstalledService {
    <# Servicos com "Workflow Service" no nome interno ou no nome exibido. #>
    foreach ($svc in @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { Test-WorkflowServiceMatch $_ } | Sort-Object DisplayName)) {
        $exe = Get-HubServiceExePath -BinaryPath ([string]$svc.PathName)
        [pscustomobject]@{
            Name        = [string]$svc.Name
            DisplayName = [string]$svc.DisplayName
            State       = [string]$svc.State
            StartName   = [string]$svc.StartName
            Exe         = $exe
            Folder      = $(if ($exe) { [IO.Path]::GetDirectoryName($exe) } else { '' })
        }
    }
}

function Test-WorkflowRemovalFolder {
    <#
    A pasta so pode ser apagada se: estiver exatamente em <Raiz>\VAR1\VAR2, contiver o executavel
    do servico, e nem a raiz nem a arvore tiverem junctions/symlinks (reparse points).
    #>
    param([string]$Folder, [string]$Exe, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Folder) -or [string]::IsNullOrWhiteSpace($Root) -or [string]::IsNullOrWhiteSpace($Exe)) { return $false }
    try {
        $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        $f = [IO.Path]::GetFullPath($Folder).TrimEnd('\')
        $expected = [IO.Path]::GetFullPath((Join-Path $f $script:Settings.ExeName))
        if (-not $f.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $relative = $f.Substring($r.Length + 1).Split('\')
        if ($relative.Count -ne 2 -or @($relative | Where-Object { -not $_ -or $_ -in @('.', '..') }).Count -gt 0) { return $false }
        if (-not [string]::Equals($expected, [IO.Path]::GetFullPath($Exe), [StringComparison]::OrdinalIgnoreCase)) { return $false }
        if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) { return $false }
        foreach ($segment in @($r, (Join-Path $r $relative[0]), $f)) {
            if (([IO.File]::GetAttributes($segment) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        $linked = Get-ChildItem -LiteralPath $f -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } | Select-Object -First 1
        if ($linked) { return $false }
        return $true
    } catch { return $false }
}

function Get-WorkflowRemovalIssues {
    <# Recebe objetos com Name, Exe e Folder. Devolve os motivos que bloqueiam a remocao (vazio = pode remover). #>
    param([Parameter(Mandatory)][object[]]$Services, [Parameter(Mandatory)][string]$Root)
    $all = @(Get-CimInstance Win32_Service -ErrorAction Stop)
    $issues = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $Services) {
        if (-not (Test-WorkflowRemovalFolder -Folder $item.Folder -Exe $item.Exe -Root $Root)) { $issues.Add("Caminho fora do padrao WFL ou inseguro: $($item.Name) -> $($item.Folder)"); continue }
        $shared = @($all | Where-Object { $_.Name -ne $item.Name -and [string]::Equals((Get-HubServiceExePath -BinaryPath ([string]$_.PathName)), $item.Exe, [StringComparison]::OrdinalIgnoreCase) })
        if ($shared.Count -gt 0) { $issues.Add("Executavel compartilhado por outro servico: $($item.Name)") }
        if (-not @($all | Where-Object { $_.Name -eq $item.Name -and (Test-WorkflowServiceMatch $_) }).Count) { $issues.Add("Servico mudou desde a leitura: $($item.Name)") }
    }
    return , $issues.ToArray()
}

function Remove-WorkflowService {
    <#
    Para o servico, executa sc delete, confirma que sumiu do SCM e so entao apaga a pasta,
    revalidando a seguranca do caminho logo antes. -OnWait e chamado durante as esperas
    (a tela usa para continuar respondendo). Lanca excecao se algo falhar; a pasta e preservada.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Root,
        [string]$LogFile,
        [scriptblock]$OnWait
    )
    try {
        $service = Get-Service -Name $Name -ErrorAction Stop
        if ($service.Status -ne 'Stopped') {
            Stop-Service -InputObject $service -ErrorAction Stop
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
        $out = & "$env:WINDIR\System32\sc.exe" delete $Name 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "sc delete falhou: $out" }
        $gone = $false
        for ($n = 0; $n -lt 30; $n++) {
            if ($OnWait) { & $OnWait }
            if (-not (Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''")) -ErrorAction SilentlyContinue)) { $gone = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $gone) { throw 'Servico ainda listado pelo Windows (possivelmente marcado para exclusao). Pasta preservada.' }
        if (-not (Test-WorkflowRemovalFolder -Folder $Folder -Exe $Exe -Root $Root)) { throw 'Pasta nao passou na verificacao de seguranca final.' }
        $stillUsing = @(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { [string]::Equals((Get-HubServiceExePath -BinaryPath ([string]$_.PathName)), $Exe, [StringComparison]::OrdinalIgnoreCase) })
        if ($stillUsing.Count) { throw 'Outro servico ainda referencia o executavel. Pasta preservada.' }
        Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction Stop
        Write-HubLog -Path $LogFile -Message "OK $Name $Folder"
    } catch {
        Write-HubLog -Path $LogFile -Message "FALHA ${Name}: $($_.Exception.Message)"
        throw
    }
}

# ---------------------------------------------------------------------------
# Ultimo erro registrado pelo servico (arquivo "errors" na pasta de instalacao)
# Registros separados por linhas de asteriscos; os de erro trazem "Categoria: Error".
# ---------------------------------------------------------------------------
function Get-WorkflowErrorFile {
    <# Arquivo errors (sem extensao ou errors.<ext>) mais recente da pasta, ou $null. #>
    param([string]$Folder)
    if ([string]::IsNullOrWhiteSpace($Folder) -or -not (Test-Path -LiteralPath $Folder -PathType Container)) { return $null }
    return Get-ChildItem -LiteralPath $Folder -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^errors(\.[^.]+)?$' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}

function ConvertFrom-WorkflowErrorLog {
    <# Separa o texto em registros e devolve os de "Categoria: Error" com Data/Hora interpretada. #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text, [bool]$Partial = $false)
    $blocks = [regex]::Split($Text, '(?m)^[ \t]*\*{10,}[ \t]*\r?$')
    $culture = [System.Globalization.CultureInfo]::GetCultureInfo('pt-BR')
    $formats = [string[]]@('dd/MM/yyyy HH:mm:ss', 'd/M/yyyy H:mm:ss', 'dd/MM/yyyy HH:mm', 'd/M/yyyy H:mm')
    for ($i = 0; $i -lt $blocks.Count; $i++) {
        # Com leitura parcial, o primeiro pedaco pode ser o fim de um registro cortado.
        if ($Partial -and $i -eq 0) { continue }
        $block = $blocks[$i].Trim()
        if ($block -notmatch 'Categoria:\s*Error\b') { continue }
        $stamp = $null
        $m = [regex]::Match($block, 'Data/Hora:\s*(\d{1,2}/\d{1,2}/\d{4}\s+\d{1,2}:\d{2}(?::\d{2})?)')
        if ($m.Success) {
            $value = ($m.Groups[1].Value -replace '\s+', ' ')
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParseExact($value, $formats, $culture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) { $stamp = $parsed }
        }
        $message = ''
        $mm = [regex]::Match($block, '(?s)Mensagem:\s*(.*?)\s*(?:\r?\n\s*(?:StackTrace:|Categoria:)|$)')
        if ($mm.Success) { $message = (($mm.Groups[1].Value -split '\r?\n') | Where-Object { $_.Trim() } | Select-Object -First 1) }
        [pscustomobject]@{ Index = $i; Timestamp = $stamp; Message = ([string]$message).Trim(); Text = $block }
    }
}

function Get-WorkflowLastError {
    <#
    Ultimos registros "Categoria: Error" (ate -Count, padrao 10) do arquivo errors da pasta do
    servico, do mais recente para o mais antigo pela Data/Hora. Le so o fim do arquivo (1 MB,
    ampliando ate 32 MB enquanto faltarem registros). Devolve um objeto com Status: 'erro',
    'sem-erros' ou 'sem-arquivo'. Records traz os registros; Timestamp/Message/Text sao do mais
    recente; AllText junta todos, separados como no arquivo.
    #>
    param([string]$Folder, [int]$Count = 10)
    $empty = @{ Timestamp = $null; Message = ''; Text = ''; AllText = ''; Records = @() }
    $file = Get-WorkflowErrorFile -Folder $Folder
    if ($null -eq $file) { return [pscustomobject](@{ Status = 'sem-arquivo'; File = $null } + $empty) }
    $records = @()
    foreach ($size in @(1MB, 8MB, 32MB)) {
        $tail = Read-HubFileTail -Path $file.FullName -MaxBytes $size
        $records = @(ConvertFrom-WorkflowErrorLog -Text $tail.Text -Partial $tail.Partial)
        if ($records.Count -ge $Count -or -not $tail.Partial) { break }
    }
    if ($records.Count -eq 0) { return [pscustomobject](@{ Status = 'sem-erros'; File = $file.FullName } + $empty) }
    $sorted = @($records | Sort-Object @{ Expression = { if ($_.Timestamp) { $_.Timestamp } else { [datetime]::MinValue } } }, Index -Descending | Select-Object -First $Count)
    $separator = [Environment]::NewLine + ('*' * 50) + [Environment]::NewLine
    return [pscustomobject]@{
        Status = 'erro'; File = $file.FullName; Records = $sorted
        Timestamp = $sorted[0].Timestamp; Message = $sorted[0].Message; Text = $sorted[0].Text
        AllText = (($sorted | ForEach-Object { $_.Text }) -join $separator)
    }
}

# ---------------------------------------------------------------------------
# Etapa 6: conta de logon
# ---------------------------------------------------------------------------
function Test-WorkflowLogonInput {
    <# Valida conta e senha antes de alterar. Devolve a mensagem de erro ou $null. #>
    param([string]$Account, [System.Security.SecureString]$Password)
    if (-not (Test-HubServiceAccountFormat -Account $Account) -or $Account -eq 'DOMINIO\usuario') { return 'Informe DOMINIO\usuario ou .\usuario (conta local).' }
    $hasPassword = ($null -ne $Password -and $Password.Length -gt 0)
    if ($Account.EndsWith('$') -and $hasPassword) { return 'Contas gMSA (terminadas em $) nao usam senha. Deixe o campo Senha vazio.' }
    if (-not $Account.EndsWith('$') -and -not $hasPassword) { return 'Informe a senha da conta. A senha nao sera salva nos logs.' }
    return $null
}

function Grant-WorkflowLogonRight {
    <#
    Tenta conceder 'Log on as a service'. Uma falha (ex.: GPO) nao impede a troca de conta,
    pois o direito pode ja existir: devolve a mensagem de erro (ou $null) e registra aviso.
    #>
    param([Parameter(Mandatory)][string]$Account, [string]$LogFile)
    try { Grant-HubServiceLogonRight -Account $Account; return $null }
    catch {
        Write-HubLog -Path $LogFile -Message "AVISO nao foi possivel conceder Log on as a service a ${Account}: $($_.Exception.Message)"
        return $_.Exception.Message
    }
}

function Set-WorkflowServiceLogon {
    <# Troca a conta de um Workflow Service (relendo e conferindo o SID). A senha nunca vai para o log. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Account,
        [System.Security.SecureString]$Password,
        [string]$LogFile
    )
    try {
        $before = Get-HubServiceInfo -Name $Name
        if (-not (Test-WorkflowServiceMatch $before)) { throw 'O servico nao corresponde mais ao filtro Workflow Service.' }
        $secret = $(if ($Account.EndsWith('$')) { $null } else { $Password })
        $after = Set-HubServiceLogon -Name $Name -Account $Account -Password $secret
        Write-HubLog -Path $LogFile -Message "LOGIN ALTERADO $Name $($after.StartName); estado=$($after.State); senha omitida"
        return $after
    } catch {
        Write-HubLog -Path $LogFile -Message "FALHA $Name - $($_.Exception.Message)"
        throw
    }
}

function Test-WorkflowServiceStart {
    <# Reinicia o servico para validar a credencial. Devolve $true se iniciou. #>
    param([Parameter(Mandatory)][string]$Name, [string]$LogFile)
    try {
        Restart-HubService -Name $Name -TimeoutSeconds 60
        Write-HubLog -Path $LogFile -Message "START OK $Name"
        return $true
    } catch {
        Write-HubLog -Path $LogFile -Message "START FALHOU $Name - $($_.Exception.Message)"
        return $false
    }
}

Export-ModuleMember -Function *-Workflow*
