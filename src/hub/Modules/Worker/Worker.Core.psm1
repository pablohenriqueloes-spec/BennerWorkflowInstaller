#requires -Version 5.1
<#
Modulo Worker do HUB Benner: cada etapa da instalacao do Benner Tasks Worker como funcao
independente, sem nenhuma dependencia da tela. A tela (Worker.View.psm1) so chama estas
funcoes, e qualquer script pode chamar as mesmas funcoes direto. Exemplo:

    Import-Module .\Modules\Worker\Worker.Core.psm1
    $pkg = Get-WorkerPackage -Path 'E:\Benner\Worker\Worker25'
    $log = New-HubLogFile -Directory (Get-WorkerSettings).LogDirectory -Prefix 'Worker_Script'
    $p = Get-WorkerDefaultParameters -Version $pkg.Version
    $p.Servidor = 'servidor'; $p.Sistema = 'SISTEMA'; $p.Nome = 'SISTEMA_PRD'
    Install-WorkerInstance -Package $pkg -Folder 'E:\Benner\Ferramentas\Worker\SISTEMA_PRD' -Parameters $p -LogFile $log

Duas versoes, detectadas pelos arquivos do pacote (pasta com Lib\):
  23  Lib\Benner.Tecnologia.Tasks.Worker.exe  (.NET Framework, Topshelf, .exe.config)
  25  Lib\Benner.Core.Worker.exe               (.NET 8, backgroundtasksconfig.json)

A instalacao reproduz o que os instaladores oficiais fazem (Instalar.exe e
Benner.Core.Worker.Installer.exe), mas na pasta exata escolhida, sem criar subpasta extra:
  1. copia o conteudo de Lib\ para a pasta (robocopy) e remove o Zone.Identifier;
  2. gera a configuracao a partir do modelo do pacote;
  3. cria o servico (23: "<exe> install -Chave:valor ..." do Topshelf; 25: New-Service);
  4. inicia o servico (opcional).
Senhas nunca vao para log nem para linha de comando.
#>

if (-not (Get-Module -Name 'BennerHub.Core')) {
    Import-Module (Join-Path $PSScriptRoot '..\..\Core\BennerHub.Core.psm1') -Global -DisableNameChecking
}

$script:Settings = [pscustomobject]@{
    LogDirectory   = (Join-Path $env:ProgramData 'Benner\WorkerInstaller\Logs')
    DefaultPackage = 'E:\Benner\Worker'
    DefaultRoot    = 'E:\Benner\Ferramentas\Worker'
    DefaultUser    = 'SYSDBA'
    Versions       = @{
        '23' = [pscustomobject]@{
            Version     = '23'
            Label       = 'Worker 23 (Tasks Worker, .NET Framework)'
            ExeName     = 'Benner.Tecnologia.Tasks.Worker.exe'
            Model       = 'Benner.Tecnologia.Tasks.Worker.exe.config.modelo'
            NamePrefix  = 'BennerTasksWorker_'
            Display     = 'Benner Tasks Worker'
            Queues      = @('Z_BTLREQUISICOES', 'Z_AGENDAMENTOREQUISICOES')
            DefaultFila = 'Z_BTLREQUISICOES'
        }
        '25' = [pscustomobject]@{
            Version     = '25'
            Label       = 'Worker 25 (Core Worker, .NET 8)'
            ExeName     = 'Benner.Core.Worker.exe'
            Model       = 'backgroundtasksconfig.json'
            NamePrefix  = 'BennerCoreWorker_'
            Display     = 'Benner Core Worker'
            Queues      = @('FILA_PADRAO_AMBOS', 'FILA_PADRAO', 'FILA_PADRAO_AGENDAMENTO')
            DefaultFila = 'FILA_PADRAO_AMBOS'
        }
    }
}

function Get-WorkerSettings {
    <# Constantes do modulo (pastas padrao, logs e dados de cada versao). #>
    return $script:Settings
}

function Get-WorkerVersionInfo {
    param([Parameter(Mandatory)][ValidateSet('23', '25')][string]$Version)
    return $script:Settings.Versions[$Version]
}

# ---------------------------------------------------------------------------
# Pacote (pasta com Lib\ de uma das versoes)
# ---------------------------------------------------------------------------
function Get-WorkerPackage {
    <# Le a pasta do pacote e devolve Version, Path, Lib, ExeName etc. Lanca excecao se nao for um pacote Worker. #>
    param([Parameter(Mandatory)][string]$Path)
    $base = $Path.Trim().TrimEnd('\')
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "Pasta do pacote nao encontrada: $base" }
    $base = (Get-Item -LiteralPath $base -Force).FullName.TrimEnd('\')
    $lib = Join-Path $base 'Lib'
    foreach ($v in '25', '23') {
        $info = $script:Settings.Versions[$v]
        if (-not (Test-Path -LiteralPath (Join-Path $lib $info.ExeName) -PathType Leaf)) { continue }
        $model = Join-Path $lib $info.Model
        if (-not (Test-Path -LiteralPath $model -PathType Leaf)) { throw "Pacote Worker $v sem o modelo de configuracao: $model" }
        return [pscustomobject]@{
            Version = $v; Label = $info.Label; Path = $base; Lib = $lib; ExeName = $info.ExeName
            Model = $model; Name = (Split-Path $base -Leaf)
        }
    }
    throw "A pasta nao e um pacote Worker (falta Lib\Benner.Core.Worker.exe ou Lib\Benner.Tecnologia.Tasks.Worker.exe): $base"
}

function Find-WorkerPackage {
    <# A propria pasta (se for um pacote) e as subpastas diretas que forem pacotes Worker. #>
    param([Parameter(Mandatory)][string]$Root)
    $base = $Root.Trim().TrimEnd('\')
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "Pasta dos pacotes nao encontrada: $base" }
    $candidates = @($base) + @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { $_.FullName })
    foreach ($c in $candidates) {
        try { Get-WorkerPackage -Path $c } catch {}
    }
}

function Test-WorkerPrerequisites {
    <# Problemas do servidor para a versao informada (vazio = ok). O 25 precisa do .NET 8 (Microsoft.NETCore.App 8.x). #>
    param([Parameter(Mandatory)][ValidateSet('23', '25')][string]$Version)
    $problems = New-Object 'System.Collections.Generic.List[string]'
    if (-not (Test-HubIsAdministrator)) { $problems.Add('O HUB nao esta elevado (Administrador).') }
    if ($Version -eq '25') {
        $found = $false
        foreach ($root in @($env:ProgramFiles, ${env:ProgramW6432}) | Where-Object { $_ } | Select-Object -Unique) {
            $dir = Join-Path $root 'dotnet\shared\Microsoft.NETCore.App'
            if (@(Get-ChildItem -LiteralPath $dir -Directory -Filter '8.*' -ErrorAction SilentlyContinue).Count -gt 0) { $found = $true }
        }
        if (-not $found) { $problems.Add('.NET 8 Runtime (Microsoft.NETCore.App 8.x) nao encontrado em Program Files\dotnet. O Worker 25 nao vai iniciar sem ele.') }
    }
    return , $problems.ToArray()
}

# ---------------------------------------------------------------------------
# Pastas de instalacao
# ---------------------------------------------------------------------------
function Test-WorkerFolderName {
    <# Nome simples de pasta (sem caminho): nao vazio, sem \ / : * ? " < > |, diferente de . e .., sem espaco/ponto no fim. #>
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    if ($Name -match '[\\/:*?"<>|]' -or $Name -eq '.' -or $Name -eq '..' -or $Name -match '[ .]$') { return $false }
    return ($Name.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0)
}

function New-WorkerTargetFolder {
    <# Cria -Name dentro de -Parent. Recusa -Parent que seja link/junction. Devolve Path e Created. #>
    param([Parameter(Mandatory)][string]$Parent, [Parameter(Mandatory)][string]$Name, [string]$LogFile)
    if (-not (Test-WorkerFolderName -Name $Name)) { throw "Nome de pasta invalido: '$Name'" }
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

function Get-WorkerTargetFolder {
    <# Subpastas diretas de -Root (sem junctions), com HasChildren (ha pastas dentro). #>
    param([Parameter(Mandatory)][string]$Root)
    $base = $Root.Trim().TrimEnd('\')
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { throw "Pasta nao encontrada: $base" }
    foreach ($dir in @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction Stop | Sort-Object Name)) {
        if (($dir.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
        $children = @(Get-ChildItem -LiteralPath $dir.FullName -Directory -Force -ErrorAction SilentlyContinue | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 })
        [pscustomobject]@{ Name = $dir.Name; Path = $dir.FullName; HasChildren = ($children.Count -gt 0) }
    }
}

function Get-WorkerFolderState {
    <#
    Situacao de uma pasta de destino:
      State = 'nova' (nao existe), 'vazia', 'arquivos' (tem conteudo), 'worker' (tem o exe de um Worker sem servico)
              ou 'instalado' (algum servico do Windows roda um exe desta pasta).
    -Services: lista de Get-WorkerInstalledService -All (evita consultar o Windows a cada pasta).
    #>
    param([Parameter(Mandatory)][string]$Folder, [object[]]$Services)
    if ($null -eq $Services) { $Services = @(Get-WorkerInstalledService -All) }
    $full = [IO.Path]::GetFullPath($Folder).TrimEnd('\')
    $svc = @($Services | Where-Object { $_.Folder -and $_.Folder.TrimEnd('\') -ieq $full }) | Select-Object -First 1
    if ($svc) { return [pscustomobject]@{ State = 'instalado'; Text = "Instalado: $($svc.DisplayName)"; Service = $svc } }
    if (-not (Test-Path -LiteralPath $full -PathType Container)) { return [pscustomobject]@{ State = 'nova'; Text = 'Pasta nova'; Service = $null } }
    foreach ($v in '23', '25') {
        if (Test-Path -LiteralPath (Join-Path $full $script:Settings.Versions[$v].ExeName) -PathType Leaf) {
            return [pscustomobject]@{ State = 'worker'; Text = "Worker $v sem serviço"; Service = $null }
        }
    }
    $any = Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($any) { return [pscustomobject]@{ State = 'arquivos'; Text = 'Contém arquivos'; Service = $null } }
    return [pscustomobject]@{ State = 'vazia'; Text = 'Vazia'; Service = $null }
}

function Test-WorkerInsideRoot {
    <# $true se -Folder esta dentro de -Root (nunca a propria raiz) e nenhum segmento do caminho e link/junction. #>
    param([string]$Folder, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Folder) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $r = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        $f = [IO.Path]::GetFullPath($Folder).TrimEnd('\')
        if ($r.Length -le 3) { return $false }
        if (-not $f.StartsWith($r + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
        $current = $r
        $segments = @($f.Substring($r.Length + 1).Split('\'))
        foreach ($s in @('') + $segments) {
            if ($s) {
                if ($s -in @('.', '..')) { return $false }
                $current = Join-Path $current $s
            }
            if (Test-Path -LiteralPath $current) {
                if (([IO.File]::GetAttributes($current) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
            }
        }
        return $true
    } catch { return $false }
}

# ---------------------------------------------------------------------------
# Parametros da instalacao
# ---------------------------------------------------------------------------
function Get-WorkerDefaultParameters {
    <#
    Hashtable com todos os campos alteraveis da versao, com os padroes dos instaladores oficiais.
    Comuns: Servidor (Benner Server), Sistema, Nome (identificacao curta; no 23 vira NomeServico),
        DisplayName (nome de exibicao no Windows; vazio = padrao do instalador), Fila.
    23: Usuario, NumeroDeProviders (0 = automatico), UseCOMFree, PoolDinamica, LoggingServerActive,
        LoggingServerAddress, HorarioIniciarWorker, HorarioFinalizarWorker.
    25: UserHandle, ServerPort, MaxPoolItem (Core), MaxLegacyPoolItem (Win32), PoolType, LegacyPoolType,
        DelayRelease, LegacyDelayRelease, DelayAfterProcess, LegacyDelayAfterProcess,
        LogServerHost, LogServerUser, LogServerPassword (SecureString), LogLevel.
    #>
    param([Parameter(Mandatory)][ValidateSet('23', '25')][string]$Version)
    $info = $script:Settings.Versions[$Version]
    $p = @{ Version = $Version; Servidor = ''; Sistema = ''; Nome = ''; DisplayName = ''; Fila = $info.DefaultFila }
    if ($Version -eq '23') {
        $p.Usuario = $script:Settings.DefaultUser
        $p.NumeroDeProviders = 0
        $p.UseCOMFree = $false
        $p.PoolDinamica = $false
        $p.LoggingServerActive = $false
        $p.LoggingServerAddress = ''
        $p.HorarioIniciarWorker = ''
        $p.HorarioFinalizarWorker = ''
    } else {
        $p.UserHandle = ''
        $p.ServerPort = ''
        $p.MaxPoolItem = 4; $p.MaxLegacyPoolItem = 4
        $p.PoolType = 'DelayedRelease'; $p.LegacyPoolType = 'DelayedRelease'
        $p.DelayRelease = 300; $p.LegacyDelayRelease = 300
        $p.DelayAfterProcess = 30; $p.LegacyDelayAfterProcess = 30
        $p.LogServerHost = ''; $p.LogServerUser = ''; $p.LogServerPassword = $null
        $p.LogLevel = 4
    }
    return $p
}

function Get-WorkerDisplayName {
    <# Nome de exibicao no Windows, no padrao dos instaladores: "Benner Tasks Worker [Sistema-Nome]" / "Benner Core Worker [Sistema-Nome]". #>
    param([Parameter(Mandatory)][ValidateSet('23', '25')][string]$Version, [string]$Sistema, [string]$Nome, [string]$Fila)
    $info = $script:Settings.Versions[$Version]
    $suffix = $(if ([string]::IsNullOrWhiteSpace($Nome)) { $Fila } else { (Get-WorkerSafeName $Nome) })
    return ('{0} [{1}-{2}]' -f $info.Display, ([string]$Sistema).Trim(), ([string]$suffix).Trim())
}

function Resolve-WorkerDisplayName {
    <# DisplayName informado ou, se vazio, o padrao do instalador. #>
    param([Parameter(Mandatory)][hashtable]$Parameters)
    $dn = ([string]$Parameters.DisplayName).Trim()
    if ($dn) { return $dn }
    return (Get-WorkerDisplayName -Version $Parameters.Version -Sistema $Parameters.Sistema -Nome $Parameters.Nome -Fila $Parameters.Fila)
}

function Set-WorkerDisplayName {
    <# Ajusta o nome de exibicao de um servico ja criado (o Topshelf do 23 sempre cria no padrao dele). #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$DisplayName, [string]$LogFile)
    $current = (Get-HubServiceInfo -Name $Name).DisplayName
    if ([string]$current -ceq $DisplayName) { return }
    Set-Service -Name $Name -DisplayName $DisplayName -ErrorAction Stop
    Write-HubLog -Path $LogFile -Message "NOME DE EXIBICAO | $Name | $current -> $DisplayName"
}

function Get-WorkerSafeName {
    <# Espacos viram _ (como o Instalar.exe faz com o nome do servico). #>
    param([string]$Name)
    return ([string]$Name).Trim().Replace(' ', '_')
}

function Test-WorkerParameters {
    <# Lista de problemas (vazio = parametros validos). -Label identifica a linha nas mensagens. #>
    param([Parameter(Mandatory)][hashtable]$Parameters, [string]$Label = '')
    $p = $Parameters
    $pre = $(if ($Label) { "${Label}: " } else { '' })
    $problems = New-Object 'System.Collections.Generic.List[string]'
    $plain = '^[^\s"''<>|&;]+$'
    foreach ($k in 'Servidor', 'Sistema', 'Fila') {
        $v = ([string]$p[$k]).Trim()
        if (-not $v) { $problems.Add("${pre}$k obrigatorio."); continue }
        if ($v -notmatch $plain) { $problems.Add("${pre}$k invalido (sem espacos, aspas ou < > | & ;): $v") }
    }
    $nome = Get-WorkerSafeName $p.Nome
    if ($nome -and $nome -notmatch $plain) { $problems.Add("${pre}Nome invalido (sem aspas ou < > | & ;): $nome") }
    $dn = ([string]$p.DisplayName).Trim()
    if ($dn -and ($dn.Length -gt 256 -or $dn -match '["\\/]')) { $problems.Add("${pre}Nome de exibicao invalido (max. 256, sem aspas, \ ou /): $dn") }
    if ($p.Version -eq '23') {
        $u = ([string]$p.Usuario).Trim()
        if (-not $u) { $problems.Add("${pre}Usuario obrigatorio.") } elseif ($u -notmatch $plain) { $problems.Add("${pre}Usuario invalido: $u") }
        $n = 0
        if (-not [int]::TryParse([string]$p.NumeroDeProviders, [ref]$n) -or $n -lt 0 -or $n -gt 256) { $problems.Add("${pre}Numero de providers invalido (0 = automatico).") }
        $addr = ([string]$p.LoggingServerAddress).Trim()
        if ($p.LoggingServerActive -and -not $addr) { $problems.Add("${pre}Informe o endereco do servidor de log.") }
        if ($addr -and $addr -notmatch $plain) { $problems.Add("${pre}Endereco do servidor de log invalido: $addr") }
        foreach ($k in 'HorarioIniciarWorker', 'HorarioFinalizarWorker') {
            $h = ([string]$p[$k]).Trim()
            if ($h -and $h -notmatch '^([01]?[0-9]|2[0-3]):[0-5][0-9](:[0-5][0-9])?$') { $problems.Add("${pre}$k invalido (hh:mm): $h") }
        }
    } else {
        $uh = ([string]$p.UserHandle).Trim()
        if ($uh -and $uh -notmatch '^\d+$') { $problems.Add("${pre}UserHandle deve ser numerico: $uh") }
        $port = ([string]$p.ServerPort).Trim()
        if ($port -and ($port -notmatch '^\d+$' -or [int]$port -gt 65535)) { $problems.Add("${pre}Porta do Benner Server invalida: $port") }
        foreach ($k in 'MaxPoolItem', 'MaxLegacyPoolItem', 'DelayRelease', 'LegacyDelayRelease', 'DelayAfterProcess', 'LegacyDelayAfterProcess') {
            $n = 0
            if (-not [int]::TryParse([string]$p[$k], [ref]$n) -or $n -lt 0) { $problems.Add("${pre}$k deve ser numero inteiro >= 0.") }
        }
        if ([int]$p.MaxPoolItem -eq 0 -and [int]$p.MaxLegacyPoolItem -eq 0) { $problems.Add("${pre}Ao menos 1 provider (Core ou Win32).") }
        $lvl = 0
        if (-not [int]::TryParse([string]$p.LogLevel, [ref]$lvl) -or $lvl -lt 0 -or $lvl -gt 5) { $problems.Add("${pre}Nivel de log deve ser de 0 a 5.") }
        if (([string]$p.LogServerHost).Trim()) {
            if (-not ([string]$p.LogServerUser).Trim()) { $problems.Add("${pre}Informe o usuario do servidor de log.") }
            if ($null -eq $p.LogServerPassword -or $p.LogServerPassword.Length -eq 0) { $problems.Add("${pre}Informe a senha do servidor de log.") }
        }
    }
    return , $problems.ToArray()
}

# ---------------------------------------------------------------------------
# Etapa 1: copia dos arquivos (Lib\ do pacote -> pasta) + desbloqueio
# ---------------------------------------------------------------------------
$script:CopyChildCode = @'
$lib=$args[0]; $dst=$args[1]; $log=$args[2]
$ErrorActionPreference='Continue'
$robo=Join-Path $env:WINDIR 'System32\robocopy.exe'
& $robo $lib $dst /E /IS /IT /XJ /R:2 /W:2 /NP /NJH /XF 'Instalar.*' ("/UNILOG+:"+$log) | Out-Null
$code=$LASTEXITCODE
if($code -ge 8){exit $code}
$failed=0
try {
    foreach($f in @(Get-ChildItem -LiteralPath $dst -Recurse -File -Force -ErrorAction Stop)) {
        try {
            if(Get-Item -LiteralPath $f.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue){ Unblock-File -LiteralPath $f.FullName -ErrorAction Stop }
        } catch { $failed++ }
    }
} catch { $failed++ }
if($failed -gt 0){ Add-Content -LiteralPath $log -Value ("Desbloqueio: {0} falha(s)" -f $failed); exit 20 }
exit $code
'@

function Start-WorkerFileCopy {
    <#
    Copia Lib\ do pacote para -Folder (robocopy /E /IS /IT /XJ, nada e apagado no destino) e remove o
    Zone.Identifier dos arquivos copiados. Processo filho oculto; devolve o Process.
    Codigo de saida: < 8 sucesso; >= 8 falha do robocopy; 20 = copiou, mas houve falha no desbloqueio.
    #>
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$CopyLog)
    if (-not (Test-Path -LiteralPath $Package.Lib -PathType Container)) { throw "Pasta Lib do pacote nao encontrada: $($Package.Lib)" }
    New-Item -ItemType Directory -Path $Folder -Force -ErrorAction Stop | Out-Null
    return Start-HubPowerShellProcess -Code $script:CopyChildCode -Arguments @($Package.Lib, $Folder, $CopyLog) -WorkingDirectory $env:SystemRoot
}

function Test-WorkerCopyExitCode { param([int]$ExitCode) return ($ExitCode -lt 8) }

# ---------------------------------------------------------------------------
# Etapa 2: configuracao a partir do modelo
# ---------------------------------------------------------------------------
function Backup-WorkerFile {
    param([Parameter(Mandatory)][string]$Path, [string]$LogFile)
    $backup = '{0}.backup_{1}' -f $Path, (Get-Date -Format 'yyyyMMdd_HHmmss')
    Copy-Item -LiteralPath $Path -Destination $backup -Force -ErrorAction Stop
    Write-HubLog -Path $LogFile -Message "BACKUP | $backup"
    return $backup
}

function Set-Worker23Config {
    <#
    Worker 23: gera <exe>.config a partir do .config.modelo (se ainda nao existir; se existir, faz backup)
    e grava no appSettings as chaves que o Instalar.exe/Topshelf usam. O resto do arquivo e preservado.
    Devolve 'gerado' ou 'atualizado'.
    #>
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][hashtable]$Parameters, [string]$LogFile)
    $info = $script:Settings.Versions['23']
    $config = Join-Path $Folder ($info.ExeName + '.config')
    $model = Join-Path $Folder $info.Model
    $result = 'atualizado'
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) {
        if (-not (Test-Path -LiteralPath $model -PathType Leaf)) { throw "Nem .config nem .config.modelo encontrados em $Folder" }
        Copy-Item -LiteralPath $model -Destination $config -ErrorAction Stop
        $result = 'gerado'
    } else {
        [void](Backup-WorkerFile -Path $config -LogFile $LogFile)
    }
    $p = $Parameters
    $values = [ordered]@{
        Servidor = ([string]$p.Servidor).Trim(); Sistema = ([string]$p.Sistema).Trim(); Usuario = ([string]$p.Usuario).Trim()
        NomeServico = (Get-WorkerSafeName $p.Nome); Fila = ([string]$p.Fila).Trim()
        UseCOMFree = [string][bool]$p.UseCOMFree; PoolDinamica = [string][bool]$p.PoolDinamica
        LoggingServerActive = [string][bool]$p.LoggingServerActive; LoggingServerAddress = ([string]$p.LoggingServerAddress).Trim()
        NumeroDeProviders = $(if ([int]$p.NumeroDeProviders -gt 0) { [string][int]$p.NumeroDeProviders } else { $null })
        HorarioIniciarWorker = $(if (([string]$p.HorarioIniciarWorker).Trim()) { ([string]$p.HorarioIniciarWorker).Trim() } else { $null })
        HorarioFinalizarWorker = $(if (([string]$p.HorarioFinalizarWorker).Trim()) { ([string]$p.HorarioFinalizarWorker).Trim() } else { $null })
    }
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($config)
    $root = $xml.DocumentElement
    if ($null -eq $root -or $root.Name -ne 'configuration') { throw "XML invalido (sem <configuration>): $config" }
    $app = $root.SelectSingleNode('appSettings')
    if ($null -eq $app) { $app = $xml.CreateElement('appSettings'); [void]$root.AppendChild($app) }
    foreach ($key in $values.Keys) {
        $node = $app.SelectSingleNode("add[@key='$key']")
        $value = $values[$key]
        if ($null -eq $value) { if ($node) { [void]$app.RemoveChild($node) }; continue }
        if ($null -eq $node) {
            $node = $xml.CreateElement('add')
            [void]$node.SetAttribute('key', $key)
            [void]$app.AppendChild($node)
        }
        [void]$node.SetAttribute('value', $value)
    }
    $tmp = $config + '.tmp'
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Encoding = New-Object System.Text.UTF8Encoding($true)
    $writer = [System.Xml.XmlWriter]::Create($tmp, $settings)
    try { $xml.Save($writer) } finally { $writer.Dispose() }
    $check = New-Object System.Xml.XmlDocument
    $check.Load($tmp)
    Move-Item -LiteralPath $tmp -Destination $config -Force -ErrorAction Stop
    Write-HubLog -Path $LogFile -Message ("CONFIG {0} | {1} | Servidor={2} Sistema={3} Usuario={4} Fila={5} NomeServico={6}" -f $result.ToUpper(), $config, $values.Servidor, $values.Sistema, $values.Usuario, $values.Fila, $values.NomeServico)
    return $result
}

function Set-JsonProperty {
    param($Object, [string]$Name, $Value)
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-JsonChild {
    <# Devolve o objeto filho -Name, criando-o vazio se faltar. #>
    param($Object, [string]$Name)
    if (-not $Object.PSObject.Properties[$Name] -or $null -eq $Object.$Name) { Set-JsonProperty $Object $Name ([pscustomobject]@{}) }
    return $Object.$Name
}

function Set-Worker25Config {
    <#
    Worker 25: grava <Pasta>\backgroundtasksconfig.json a partir do modelo do pacote (Lib\backgroundtasksconfig.json),
    como o Benner.Core.Worker.Installer: ServiceName, SystemSettings, fila, pools, providers, log e
    Host/SystemName nas filas (BrokerSettings). Se o arquivo ja existir, faz backup antes.
    A senha do servidor de log vai so para o JSON (como no instalador oficial), nunca para o log.
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [string]$LogFile
    )
    $p = $Parameters
    $target = Join-Path $Folder 'backgroundtasksconfig.json'
    $result = 'gerado'
    if (Test-Path -LiteralPath $target -PathType Leaf) { [void](Backup-WorkerFile -Path $target -LogFile $LogFile); $result = 'atualizado' }
    $cfg = [IO.File]::ReadAllText($Package.Model, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($null -eq $cfg) { throw "Modelo vazio ou invalido: $($Package.Model)" }
    $server = ([string]$p.Servidor).Trim(); $system = ([string]$p.Sistema).Trim()

    Set-JsonProperty $cfg 'ServiceName' $ServiceName
    $sys = Get-JsonChild $cfg 'SystemSettings'
    Set-JsonProperty $sys 'SuperServerHost' $server
    Set-JsonProperty $sys 'SuperServerSystemName' $system
    if (([string]$p.ServerPort).Trim()) { Set-JsonProperty $sys 'SuperServerPort' ([string]$p.ServerPort).Trim() }
    Set-JsonProperty (Get-JsonChild $cfg 'ConsumerSettings') 'Name' ([string]$p.Fila).Trim()
    if (([string]$p.UserHandle).Trim()) { Set-JsonProperty (Get-JsonChild $cfg 'UserContext') 'UserHandle' ([string]$p.UserHandle).Trim() }

    foreach ($pair in @(@('CoreSettings', 'provider', 'MaxPoolItem', 'PoolType', 'DelayRelease', 'DelayAfterProcess'),
            @('LegacySettings', 'providerX86', 'MaxLegacyPoolItem', 'LegacyPoolType', 'LegacyDelayRelease', 'LegacyDelayAfterProcess'))) {
        $section = Get-JsonChild $cfg $pair[0]
        Set-JsonProperty $section 'ProviderPath' (Join-Path $Folder $pair[1])
        $pool = Get-JsonChild $section 'PoolSettings'
        Set-JsonProperty $pool 'MaxPoolItemsAllowed' ([string][int]$p[$pair[2]])
        Set-JsonProperty $pool 'PoolType' ([string]$p[$pair[3]])
        Set-JsonProperty $pool 'DelayRelease' ([string][int]$p[$pair[4]])
        Set-JsonProperty $pool 'DelayAfterProcess' ([string][int]$p[$pair[5]])
    }

    $logging = Get-JsonChild $cfg 'Logging'
    Set-JsonProperty $logging 'LogLevel' ([string][int]$p.LogLevel)
    if (([string]$p.LogServerHost).Trim()) {
        Set-JsonProperty $logging 'LogServerHost' ([string]$p.LogServerHost).Trim()
        Set-JsonProperty $logging 'LogServerUser' ([string]$p.LogServerUser).Trim()
        $ptr = [IntPtr]::Zero
        try {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($p.LogServerPassword)
            Set-JsonProperty $logging 'LogServerPassword' ([Runtime.InteropServices.Marshal]::PtrToStringUni($ptr))
        } finally { if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) } }
    }

    # Como o instalador oficial: Host/SystemName das filas acompanham o SystemSettings.
    $brokers = $null
    if ($cfg.PSObject.Properties['BackgroundTaskConfig'] -and $cfg.BackgroundTaskConfig) { $brokers = $cfg.BackgroundTaskConfig.BrokerSettings }
    foreach ($b in @($brokers)) {
        if ($null -eq $b -or $null -eq $b.Properties) { continue }
        if ($b.Properties.PSObject.Properties['Host']) { $b.Properties.Host = $server }
        if ($b.Properties.PSObject.Properties['SystemName']) { $b.Properties.SystemName = $system }
    }
    $queues = @(@($brokers) | Where-Object { $_ } | ForEach-Object { [string]$_.Name })
    if ($queues.Count -gt 0 -and -not ($queues -contains ([string]$p.Fila).Trim())) {
        Write-HubLog -Path $LogFile -Message ("AVISO | fila '{0}' nao existe em BrokerSettings do modelo ({1})" -f $p.Fila, ($queues -join ', '))
    }

    $json = $cfg | ConvertTo-Json -Depth 32
    [void]($json | ConvertFrom-Json)
    $tmp = $target + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $target -Force -ErrorAction Stop
    $logInfo = $(if (([string]$p.LogServerHost).Trim()) { "LogServerHost=$(([string]$p.LogServerHost).Trim()) senha omitida" } else { 'sem servidor de log' })
    Write-HubLog -Path $LogFile -Message ("CONFIG {0} | {1} | Servico={2} Servidor={3} Sistema={4} Fila={5} Core={6} Win32={7} | {8}" -f $result.ToUpper(), $target, $ServiceName, $server, $system, $p.Fila, $p.MaxPoolItem, $p.MaxLegacyPoolItem, $logInfo)
    return $result
}

# ---------------------------------------------------------------------------
# Etapa 3: criacao do servico
# ---------------------------------------------------------------------------
function New-WorkerServiceName {
    <# Nome interno no padrao dos instaladores oficiais: BennerTasksWorker_<GUID> / BennerCoreWorker_<GUID>. #>
    param([Parameter(Mandatory)][ValidateSet('23', '25')][string]$Version)
    return $script:Settings.Versions[$Version].NamePrefix + [guid]::NewGuid().ToString('N')
}

function Get-Worker23InstallArguments {
    <# Argumentos do "Benner.Tecnologia.Tasks.Worker.exe install", na mesma ordem e formato do Instalar.exe. #>
    param([Parameter(Mandatory)][hashtable]$Parameters)
    $p = $Parameters
    $list = New-Object 'System.Collections.Generic.List[string]'
    $list.Add('install')
    $list.Add('-Sistema:' + ([string]$p.Sistema).Trim())
    $list.Add('-Servidor:' + ([string]$p.Servidor).Trim())
    if ([int]$p.NumeroDeProviders -gt 0) { $list.Add('-NumeroDeProviders:' + [int]$p.NumeroDeProviders) }
    $list.Add('-Usuario:' + ([string]$p.Usuario).Trim())
    $list.Add('-Fila:' + ([string]$p.Fila).Trim())
    $list.Add('-UseCOMFree:' + [bool]$p.UseCOMFree)
    $list.Add('-LoggingServerActive:' + [bool]$p.LoggingServerActive)
    $list.Add('-LoggingServerAddress:' + ([string]$p.LoggingServerAddress).Trim())
    $list.Add('-NomeServico:' + (Get-WorkerSafeName $p.Nome))
    $list.Add('-PoolDinamica:' + [bool]$p.PoolDinamica)
    if (([string]$p.HorarioIniciarWorker).Trim()) { $list.Add('-HorarioIniciarWorker:' + ([string]$p.HorarioIniciarWorker).Trim()) }
    if (([string]$p.HorarioFinalizarWorker).Trim()) { $list.Add('-HorarioFinalizarWorker:' + ([string]$p.HorarioFinalizarWorker).Trim()) }
    return , $list.ToArray()
}

function Get-WorkerInstallPreview {
    <# Texto de previa (uma linha por etapa) para uma instancia. #>
    param([Parameter(Mandatory)]$Package, [Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][hashtable]$Parameters)
    $p = $Parameters
    $pp = $p.Clone(); $pp.Version = $Package.Version
    $display = Resolve-WorkerDisplayName -Parameters $pp
    $lines = @("# $display", "robocopy `"$($Package.Lib)`" `"$Folder`" /E /IS /IT /XJ /XF Instalar.*")
    if ($Package.Version -eq '23') {
        $lines += "config: $($Package.ExeName).config (do .modelo) Servidor=$($p.Servidor) Sistema=$($p.Sistema) Usuario=$($p.Usuario) Fila=$($p.Fila)"
        $lines += ('"{0}" {1}' -f (Join-Path $Folder $Package.ExeName), ((Get-Worker23InstallArguments -Parameters $p) -join ' '))
        $lines += "nome de exibicao: $display"
    } else {
        $lines += "config: backgroundtasksconfig.json (do modelo) Servidor=$($p.Servidor) Sistema=$($p.Sistema) Fila=$($p.Fila) Core=$($p.MaxPoolItem) Win32=$($p.MaxLegacyPoolItem)"
        $lines += ("New-Service BennerCoreWorker_<GUID> -DisplayName `"{0}`" -BinaryPathName `"{1}`" -StartupType Automatic" -f $display, (Join-Path $Folder $Package.ExeName))
    }
    return ($lines -join [Environment]::NewLine)
}

$script:Install23ChildCode = @'
$exe=$args[0]; $argLine=$args[1]; $log=$args[2]
$ErrorActionPreference='Stop'
try {
    $out=$log+'.out'; $err=$log+'.err'
    $p=Start-Process -FilePath $exe -ArgumentList $argLine -WorkingDirectory (Split-Path $exe -Parent) -NoNewWindow -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err
    foreach($f in $out,$err){ if(Test-Path -LiteralPath $f){ Get-Content -LiteralPath $f | Add-Content -LiteralPath $log; Remove-Item -LiteralPath $f -Force } }
    exit ([int]$p.ExitCode)
} catch {
    $_ | Out-String | Add-Content -LiteralPath $log
    exit 1
}
'@

function Start-Worker23ServiceInstall {
    <#
    Worker 23: executa "<exe> install -Sistema:... -Servidor:..." (Topshelf) em processo filho oculto e
    devolve o Process. Codigo 0 = instalado; 3 = ja instalado (aceito pelo Instalar.exe).
    O servico criado e localizado depois pela pasta (Find-WorkerServiceByFolder).
    #>
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][hashtable]$Parameters, [Parameter(Mandatory)][string]$DetailLog)
    $exe = Join-Path $Folder $script:Settings.Versions['23'].ExeName
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Executavel nao encontrado: $exe" }
    $argLine = (Get-Worker23InstallArguments -Parameters $Parameters) -join ' '
    Write-HubLog -Path $DetailLog -Message ('COMANDO | "{0}" {1}' -f $exe, $argLine)
    return Start-HubPowerShellProcess -Code $script:Install23ChildCode -Arguments @($exe, $argLine, $DetailLog) -WorkingDirectory $Folder
}

function Test-Worker23InstallExitCode { param([int]$ExitCode) return ($ExitCode -eq 0 -or $ExitCode -eq 3) }

function New-Worker25Service {
    <# Worker 25: cria o servico (automatico, LocalSystem) apontando para <Pasta>\Benner.Core.Worker.exe. #>
    param([Parameter(Mandatory)][string]$Folder, [Parameter(Mandatory)][string]$ServiceName, [Parameter(Mandatory)][string]$DisplayName, [string]$LogFile)
    $exe = Join-Path $Folder $script:Settings.Versions['25'].ExeName
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Executavel nao encontrado: $exe" }
    New-Service -Name $ServiceName -DisplayName $DisplayName -BinaryPathName ('"{0}"' -f $exe) -StartupType Automatic -ErrorAction Stop | Out-Null
    Write-HubLog -Path $LogFile -Message "SERVICO CRIADO | $ServiceName | $DisplayName | $exe"
}

function Find-WorkerServiceByFolder {
    <# Servico do Windows cujo executavel esta exatamente em -Folder (ou $null). #>
    param([Parameter(Mandatory)][string]$Folder)
    $full = [IO.Path]::GetFullPath($Folder).TrimEnd('\')
    return @(Get-WorkerInstalledService -All | Where-Object { $_.Folder -and $_.Folder.TrimEnd('\') -ieq $full }) | Select-Object -First 1
}

function Get-WorkerExistingDisplayNames {
    <# Nomes de exibicao de todos os servicos (o Windows nao aceita dois iguais). #>
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    Add-Type -AssemblyName System.ServiceProcess
    foreach ($svc in [System.ServiceProcess.ServiceController]::GetServices()) { [void]$set.Add($svc.DisplayName) }
    return , $set
}

# ---------------------------------------------------------------------------
# Etapa 4: partida do servico
# ---------------------------------------------------------------------------
function Start-WorkerService {
    <# Pede a partida sem esperar (ServiceController.Start). Acompanhe com Get-WorkerServiceState. #>
    param([Parameter(Mandatory)][string]$Name, [string]$LogFile)
    Add-Type -AssemblyName System.ServiceProcess
    $sc = New-Object System.ServiceProcess.ServiceController($Name)
    try { $sc.Start() } finally { $sc.Dispose() }
    Write-HubLog -Path $LogFile -Message "START SOLICITADO | $Name"
}

function Get-WorkerServiceState {
    param([Parameter(Mandatory)][string]$Name)
    Add-Type -AssemblyName System.ServiceProcess
    $sc = New-Object System.ServiceProcess.ServiceController($Name)
    try { $sc.Refresh(); return [string]$sc.Status } catch { return 'NotFound' } finally { $sc.Dispose() }
}

# ---------------------------------------------------------------------------
# Instalacao completa (sincrona, para scripts)
# ---------------------------------------------------------------------------
function Install-WorkerInstance {
    <#
    Copia, configura, cria e (sem -NoStart) inicia um Worker em -Folder, esperando cada etapa.
    -Folder pode nao existir (e criado). Lanca excecao em qualquer falha.
    #>
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][hashtable]$Parameters,
        [Parameter(Mandatory)][string]$LogFile,
        [switch]$NoStart,
        [int]$StartTimeoutSeconds = 90
    )
    $p = $Parameters.Clone(); $p.Version = $Package.Version
    $problems = Test-WorkerParameters -Parameters $p -Label $Folder
    if ($problems.Count -gt 0) { throw ($problems -join [Environment]::NewLine) }
    $state = Get-WorkerFolderState -Folder $Folder
    if ($state.State -eq 'instalado') { throw "Ja existe servico nesta pasta: $($state.Text)" }
    $display = Resolve-WorkerDisplayName -Parameters $p
    if ((Get-WorkerExistingDisplayNames).Contains($display)) { throw "Ja existe um servico com o nome de exibicao: $display" }
    Write-HubLog -Path $LogFile -Message "INICIO | Worker $($Package.Version) | $Folder | $display"

    $copyLog = [IO.Path]::ChangeExtension($LogFile, $null).TrimEnd('.') + '_robocopy.log'
    $proc = Start-WorkerFileCopy -Package $Package -Folder $Folder -CopyLog $copyLog
    try { $proc.WaitForExit(); $code = $proc.ExitCode } finally { $proc.Dispose() }
    Write-HubLog -Path $LogFile -Message "COPIA | codigo=$code | $copyLog"
    if (-not (Test-WorkerCopyExitCode $code)) { throw "Falha na copia (robocopy $code). Veja $copyLog" }

    if ($Package.Version -eq '23') {
        [void](Set-Worker23Config -Folder $Folder -Parameters $p -LogFile $LogFile)
        $detail = [IO.Path]::ChangeExtension($LogFile, $null).TrimEnd('.') + '_install.log'
        $proc = Start-Worker23ServiceInstall -Folder $Folder -Parameters $p -DetailLog $detail
        try { $proc.WaitForExit(); $code = $proc.ExitCode } finally { $proc.Dispose() }
        Write-HubLog -Path $LogFile -Message "INSTALL TOPSHELF | codigo=$code | $detail"
        if (-not (Test-Worker23InstallExitCode $code)) { throw "Falha na instalacao do servico (codigo $code). Veja $detail" }
        $svc = Find-WorkerServiceByFolder -Folder $Folder
        if ($null -eq $svc) { throw "O instalador terminou, mas nenhum servico aponta para $Folder. Veja $detail" }
        $name = $svc.Name
        Set-WorkerDisplayName -Name $name -DisplayName $display -LogFile $LogFile
    } else {
        $name = New-WorkerServiceName -Version '25'
        [void](Set-Worker25Config -Folder $Folder -Package $Package -ServiceName $name -Parameters $p -LogFile $LogFile)
        New-Worker25Service -Folder $Folder -ServiceName $name -DisplayName $display -LogFile $LogFile
    }
    $status = 'Stopped'
    if (-not $NoStart) {
        Start-WorkerService -Name $name -LogFile $LogFile
        $deadline = (Get-Date).AddSeconds($StartTimeoutSeconds)
        do { Start-Sleep -Milliseconds 500; $status = Get-WorkerServiceState -Name $name } while ($status -eq 'StartPending' -and (Get-Date) -lt $deadline)
        Write-HubLog -Path $LogFile -Message "START | $name | $status"
    }
    return [pscustomobject]@{ Name = $name; DisplayName = $display; Folder = $Folder; Version = $Package.Version; Status = $status }
}

# ---------------------------------------------------------------------------
# Servicos instalados, remocao e login
# ---------------------------------------------------------------------------
function Get-WorkerVersionFromExe {
    param([string]$Exe)
    if (-not $Exe) { return '' }
    $leaf = Split-Path $Exe -Leaf
    foreach ($v in '23', '25') { if ($leaf -ieq $script:Settings.Versions[$v].ExeName) { return $v } }
    return ''
}

function Test-WorkerServiceMatch {
    param($Service)
    $n = [string]$Service.Name; $d = [string]$Service.DisplayName
    return ($n -like 'BennerTasksWorker_*' -or $n -like 'BennerCoreWorker_*' -or $n -like 'Benner.Tecnologia.Tasks.Worker_*' -or
        $d -like 'Benner Tasks Worker*' -or $d -like 'Benner Core Worker*')
}

function Get-WorkerInstalledService {
    <#
    Servicos Benner Worker (23 e 25) pelo nome interno ou exibido.
    -All devolve todos os servicos do Windows com Exe/Folder (usado para checar pastas ocupadas).
    #>
    param([switch]$All)
    foreach ($svc in @(Get-CimInstance Win32_Service -ErrorAction Stop | Sort-Object DisplayName)) {
        if (-not $All -and -not (Test-WorkerServiceMatch $svc)) { continue }
        $exe = Get-HubServiceExePath -BinaryPath ([string]$svc.PathName)
        [pscustomobject]@{
            Name        = [string]$svc.Name
            DisplayName = [string]$svc.DisplayName
            State       = [string]$svc.State
            StartName   = [string]$svc.StartName
            Exe         = $exe
            Folder      = $(if ($exe) { [IO.Path]::GetDirectoryName($exe) } else { '' })
            Version     = (Get-WorkerVersionFromExe $exe)
        }
    }
}

function Get-WorkerRemovalIssues {
    <# Recebe objetos com Name, Exe e Folder. Devolve os motivos que bloqueiam a remocao (vazio = pode remover). #>
    param([Parameter(Mandatory)][object[]]$Services, [Parameter(Mandatory)][string]$Root, [bool]$DeleteFolder = $true)
    $all = @(Get-CimInstance Win32_Service -ErrorAction Stop)
    $issues = New-Object 'System.Collections.Generic.List[string]'
    foreach ($item in $Services) {
        $current = @($all | Where-Object { $_.Name -eq $item.Name }) | Select-Object -First 1
        if (-not $current -or -not (Test-WorkerServiceMatch $current)) { $issues.Add("Servico mudou desde a leitura: $($item.Name)"); continue }
        if (-not $DeleteFolder) { continue }
        if (-not (Get-WorkerVersionFromExe $item.Exe)) { $issues.Add("Executavel nao e de um Worker: $($item.Name) -> $($item.Exe)"); continue }
        if (-not (Test-WorkerInsideRoot -Folder $item.Folder -Root $Root)) { $issues.Add("Pasta fora da raiz de instalacao ou com link/junction: $($item.Name) -> $($item.Folder)"); continue }
        $shared = @($all | Where-Object { $_.Name -ne $item.Name -and [string]::Equals((Get-HubServiceExePath -BinaryPath ([string]$_.PathName)), $item.Exe, [StringComparison]::OrdinalIgnoreCase) })
        if ($shared.Count -gt 0) { $issues.Add("Executavel compartilhado por outro servico: $($item.Name)") }
        $f = [IO.Path]::GetFullPath($item.Folder).TrimEnd('\')
        $nested = @($all | Where-Object { $_.Name -ne $item.Name } | ForEach-Object { Get-HubServiceExePath -BinaryPath ([string]$_.PathName) } |
                Where-Object { $_ -and $_.StartsWith($f + '\', [StringComparison]::OrdinalIgnoreCase) })
        if ($nested.Count -gt 0) { $issues.Add("Outro servico usa arquivos dentro da pasta: $($item.Name) -> $($nested[0])") }
    }
    return , $issues.ToArray()
}

function Test-WorkerTreeHasLinks {
    param([Parameter(Mandatory)][string]$Folder)
    $linked = Get-ChildItem -LiteralPath $Folder -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } | Select-Object -First 1
    return [bool]$linked
}

function Remove-WorkerService {
    <#
    Para o servico, executa sc delete, confirma que sumiu do SCM e so entao (com -DeleteFolder) apaga a pasta,
    revalidando a seguranca do caminho logo antes. -OnWait e chamado durante as esperas.
    Lanca excecao se algo falhar; a pasta e preservada.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string]$Root,
        [bool]$DeleteFolder = $true,
        [string]$LogFile,
        [scriptblock]$OnWait
    )
    try {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -ne $service -and $service.Status -ne 'Stopped') {
            Stop-Service -Name $Name -Force -ErrorAction Stop
            $deadline = (Get-Date).AddSeconds(60)
            while ((Get-WorkerServiceState -Name $Name) -notin @('Stopped', 'NotFound') -and (Get-Date) -lt $deadline) {
                if ($OnWait) { & $OnWait }
                Start-Sleep -Milliseconds 300
            }
            if ((Get-WorkerServiceState -Name $Name) -notin @('Stopped', 'NotFound')) { throw 'O servico nao parou em 60 segundos.' }
        }
        if ($null -ne $service) {
            $out = & "$env:WINDIR\System32\sc.exe" delete $Name 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "sc delete falhou: $out" }
        }
        $gone = $false
        for ($n = 0; $n -lt 30; $n++) {
            if ($OnWait) { & $OnWait }
            if (-not (Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''")) -ErrorAction SilentlyContinue)) { $gone = $true; break }
            Start-Sleep -Milliseconds 500
        }
        if (-not $gone) { throw 'Servico ainda listado pelo Windows (possivelmente marcado para exclusao). Pasta preservada.' }
        Write-HubLog -Path $LogFile -Message "SERVICO REMOVIDO | $Name"
        if (-not $DeleteFolder) { return }
        if (-not (Test-WorkerInsideRoot -Folder $Folder -Root $Root)) { throw 'Pasta nao passou na verificacao de seguranca final. Pasta preservada.' }
        if (-not [string]::Equals([IO.Path]::GetFullPath((Join-Path $Folder (Split-Path $Exe -Leaf))), [IO.Path]::GetFullPath($Exe), [StringComparison]::OrdinalIgnoreCase)) { throw 'Executavel fora da pasta informada. Pasta preservada.' }
        if (-not (Test-Path -LiteralPath $Folder -PathType Container)) { Write-HubLog -Path $LogFile -Message "PASTA JA NAO EXISTIA | $Folder"; return }
        if (Test-WorkerTreeHasLinks -Folder $Folder) { throw 'A pasta contem links/junctions. Pasta preservada.' }
        $f = [IO.Path]::GetFullPath($Folder).TrimEnd('\')
        $stillUsing = @(Get-CimInstance Win32_Service -ErrorAction Stop | ForEach-Object { Get-HubServiceExePath -BinaryPath ([string]$_.PathName) } |
                Where-Object { $_ -and ([IO.Path]::GetDirectoryName($_).TrimEnd('\') -ieq $f -or $_.StartsWith($f + '\', [StringComparison]::OrdinalIgnoreCase)) })
        if ($stillUsing.Count) { throw 'Outro servico ainda usa arquivos desta pasta. Pasta preservada.' }
        Remove-Item -LiteralPath $Folder -Recurse -Force -ErrorAction Stop
        Write-HubLog -Path $LogFile -Message "PASTA APAGADA | $Folder"
    } catch {
        Write-HubLog -Path $LogFile -Message "FALHA ${Name}: $($_.Exception.Message)"
        throw
    }
}

function Test-WorkerLogonInput {
    <# Texto do problema ou $null. Contas gMSA (terminadas em $) vao sem senha. #>
    param([string]$Account, [System.Security.SecureString]$Password)
    if (-not (Test-HubServiceAccountFormat -Account $Account)) { return 'Informe a conta no formato DOMINIO\usuario (ou .\usuario).' }
    if (-not $Account.EndsWith('$') -and ($null -eq $Password -or $Password.Length -eq 0)) { return 'Informe a senha (vazia apenas para contas gMSA terminadas em $).' }
    return $null
}

function Set-WorkerServiceLogon {
    <# Troca a conta de um Worker (ChangeServiceConfig, relendo e conferindo o SID). A senha nunca vai para o log. #>
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Account, [System.Security.SecureString]$Password, [string]$LogFile)
    try {
        $before = Get-HubServiceInfo -Name $Name
        if (-not (Test-WorkerServiceMatch $before)) { throw 'O servico nao corresponde mais ao filtro Benner Worker.' }
        $secret = $(if ($Account.EndsWith('$')) { $null } else { $Password })
        $after = Set-HubServiceLogon -Name $Name -Account $Account -Password $secret
        Write-HubLog -Path $LogFile -Message "LOGIN ALTERADO $Name $($after.StartName); estado=$($after.State); senha omitida"
        return $after
    } catch {
        Write-HubLog -Path $LogFile -Message "FALHA $Name - $($_.Exception.Message)"
        throw
    }
}

function Grant-WorkerLogonRight {
    <# Tenta conceder SeServiceLogonRight. Devolve $null ou a mensagem de erro (nao interrompe). #>
    param([Parameter(Mandatory)][string]$Account, [string]$LogFile)
    if ($Account.EndsWith('$') -or $Account -match '^(NT AUTHORITY|NT SERVICE)\\') { return $null }
    try {
        Grant-HubServiceLogonRight -Account $Account
        Write-HubLog -Path $LogFile -Message "DIREITO SeServiceLogonRight OK $Account"
        return $null
    } catch {
        Write-HubLog -Path $LogFile -Message "DIREITO SeServiceLogonRight FALHOU $Account - $($_.Exception.Message)"
        return $_.Exception.Message
    }
}

function Test-WorkerServiceStart {
    <# Reinicia o servico para validar a credencial. Devolve $true se iniciou. #>
    param([Parameter(Mandatory)][string]$Name, [string]$LogFile)
    try {
        Restart-HubService -Name $Name -TimeoutSeconds 90
        Write-HubLog -Path $LogFile -Message "START OK $Name"
        return $true
    } catch {
        Write-HubLog -Path $LogFile -Message "START FALHOU $Name - $($_.Exception.Message)"
        return $false
    }
}

Export-ModuleMember -Function *-Worker*
