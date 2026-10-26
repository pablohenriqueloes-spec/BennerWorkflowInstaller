#requires -Version 5.1
<#+
Benner Workflow - Instalador de Servicos
Execute via Iniciar-Instalador.cmd, em Windows com PowerShell 5.1 e .NET Framework 4.x.
Instalacoes sao feitas em lote, sequencialmente, para evitar concorrencia do InstallUtil.
+#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ExeName = 'Benner.Tecnologia.Workflow.Runtime.Application.exe'
$script:InstallUtil = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\InstallUtil.exe'
$script:LogDirectory = Join-Path $env:ProgramData 'Benner\WorkflowInstaller\Logs'
$script:Scanning = $false
$script:Installing = $false
$script:Unlocking = $false
$script:ChangingLogin = $false
$script:EditingConfig = $false
$script:Results = New-Object System.Collections.ArrayList
$script:Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:Bold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:TitleFont = New-Object System.Drawing.Font('Segoe UI Semibold', 15, [System.Drawing.FontStyle]::Bold)
$script:Back = [System.Drawing.Color]::FromArgb(13,17,25)
$script:White = [System.Drawing.Color]::FromArgb(24,30,42)
$script:Bright = [System.Drawing.Color]::FromArgb(245,247,252)
$script:Ink = [System.Drawing.Color]::FromArgb(232,237,245)
$script:Muted = [System.Drawing.Color]::FromArgb(151,163,183)
$script:Accent = [System.Drawing.Color]::FromArgb(226,35,77)
$script:Border = [System.Drawing.Color]::FromArgb(55,65,83)


# Native SCM API: the password is passed directly to Windows, never on a command line.
# LSA grants SeServiceLogonRight to the account on this computer if required.
$nativeCode = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;
public static class WorkflowServiceCredentials {
    const uint SC_MANAGER_CONNECT = 0x0001;
    const uint SERVICE_CHANGE_CONFIG = 0x0002;
    const uint SERVICE_NO_CHANGE = 0xFFFFFFFF;
    const uint POLICY_LOOKUP_NAMES = 0x00000800;
    const uint POLICY_CREATE_ACCOUNT = 0x00000010;
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_UNICODE_STRING {
        public ushort Length;
        public ushort MaximumLength;
        public IntPtr Buffer;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct LSA_OBJECT_ATTRIBUTES {
        public uint Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQualityOfService;
    }
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr OpenSCManager(string machine, string database, uint access);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr OpenService(IntPtr manager, string name, uint access);
    [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool ChangeServiceConfig(IntPtr service, uint serviceType, uint startType, uint errorControl,
        string binaryPath, string loadOrderGroup, IntPtr tagId, string dependencies,
        string account, string password, string displayName);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern bool CloseServiceHandle(IntPtr handle);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint LsaOpenPolicy(IntPtr systemName, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")]
    static extern uint LsaAddAccountRights(IntPtr handle, byte[] sid, LSA_UNICODE_STRING[] rights, uint count);
    [DllImport("advapi32.dll")]
    static extern uint LsaNtStatusToWinError(uint status);
    [DllImport("advapi32.dll")]
    static extern uint LsaClose(IntPtr handle);
    static void CheckLsa(uint status) { if(status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status)); }
    public static void AllowServiceLogon(string account) {
        SecurityIdentifier sid = (SecurityIdentifier)(new NTAccount(account).Translate(typeof(SecurityIdentifier)));
        byte[] sidBytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(sidBytes, 0);
        LSA_OBJECT_ATTRIBUTES attrs = new LSA_OBJECT_ATTRIBUTES();
        attrs.Length = (uint)Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr policy = IntPtr.Zero;
        CheckLsa(LsaOpenPolicy(IntPtr.Zero, ref attrs, POLICY_LOOKUP_NAMES|POLICY_CREATE_ACCOUNT, out policy));
        IntPtr ptr = IntPtr.Zero;
        try {
            string right = "SeServiceLogonRight";
            ptr = Marshal.StringToHGlobalUni(right);
            LSA_UNICODE_STRING item = new LSA_UNICODE_STRING();
            item.Buffer = ptr; item.Length = (ushort)(right.Length * 2);
            item.MaximumLength = (ushort)((right.Length+1) * 2);
            CheckLsa(LsaAddAccountRights(policy, sidBytes, new LSA_UNICODE_STRING[] {item}, 1));
        } finally { if(ptr != IntPtr.Zero) Marshal.FreeHGlobal(ptr); if(policy != IntPtr.Zero) LsaClose(policy); }
    }
    public static void SetLogon(string serviceName, string account, string password) {
        IntPtr manager = OpenSCManager(null, null, SC_MANAGER_CONNECT);
        if(manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try {
            IntPtr service = OpenService(manager, serviceName, SERVICE_CHANGE_CONFIG);
            if(service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                bool ok = ChangeServiceConfig(service, SERVICE_NO_CHANGE, SERVICE_NO_CHANGE,
                    SERVICE_NO_CHANGE, null, null, IntPtr.Zero, null, account, password, null);
                if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
            } finally { CloseServiceHandle(service); }
        } finally { CloseServiceHandle(manager); }
    }
}
'@
Add-Type -TypeDefinition $nativeCode -ErrorAction Stop

function Normalize-ServiceAccount([string]$account) {
    $account=$account.Trim()
    if($account.StartsWith('.\')) { return ($env:COMPUTERNAME + '\' + $account.Substring(2)) }
    return $account
}
function Read-ServiceLogon([string]$name) {
    $q="Name='{0}'" -f $name.Replace("'","''")
    return Get-CimInstance Win32_Service -Filter $q -ErrorAction Stop
}

function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, [bool]$bold=$false) {
    $c = New-Object System.Windows.Forms.Label
    $c.Text = $text; $c.SetBounds($x,$y,$w,$h)
    $c.ForeColor = $script:Ink; $c.BackColor = [System.Drawing.Color]::Transparent
    $c.Font = $(if ($bold) { $script:Bold } else { $script:Font })
    return $c
}
function New-Button([string]$text,[int]$x,[int]$y,[int]$w,[int]$h,[bool]$primary=$false) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text=$text; $b.SetBounds($x,$y,$w,$h)
    $b.FlatStyle='Flat'; $b.FlatAppearance.BorderSize = $(if ($primary){0}else{1})
    $b.FlatAppearance.BorderColor = $script:Border
    $b.BackColor = $(if ($primary){$script:Accent}else{$script:White})
    $b.ForeColor = $(if ($primary){$script:Bright}else{$script:Ink})
    $b.Font = $script:Bold; $b.Cursor='Hand'; $b.UseVisualStyleBackColor=$false
    return $b
}
function New-Panel([int]$x,[int]$y,[int]$w,[int]$h) {
    $p=New-Object System.Windows.Forms.Panel
    $p.SetBounds($x,$y,$w,$h); $p.BackColor=$script:White
    $p.BorderStyle='FixedSingle'; return $p
}
function Safe-Name([string]$name) {
    return (-not [string]::IsNullOrWhiteSpace($name)) -and $name.Length -le 230 -and ($name -match '^[a-zA-Z0-9_.-]+$')
}
function Default-Name([string]$first,[string]$second) {
    if($checkboxPrefix.Checked){ return ('{0}_{1}' -f $first,$second) }
    return $second
}
function Update-Selection {
    $count=0
    foreach($row in $grid.Rows){ if($row.Cells['Install'].Value -eq $true){ $count++ } }
    $selectedCount.Text = "$count selecionado(s)"
    $summary.Text = "$count servico(s) selecionado(s) para instalacao"
    $installButton.Enabled = ($count -gt 0 -and -not $script:Installing -and -not $script:Unlocking -and -not $script:EditingConfig)
    if($null -ne $editConfigButton){$editConfigButton.Enabled=($count -gt 0 -and -not $script:Installing -and -not $script:Unlocking -and -not $script:EditingConfig)}
    if($null -ne $initialConfigButton){$initialConfigButton.Enabled=($count -gt 0 -and -not $script:Installing -and -not $script:Unlocking -and -not $script:EditingConfig)}
    if($null -ne $unlockButton){
        $unlockButton.Enabled = ((@($grid.Rows | Where-Object { $_.Cells['Unlock'].Value -eq $true }).Count -gt 0) -and -not $script:Installing -and -not $script:Unlocking)
    }
    Update-Preview
}
function Update-Preview {
    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach($row in $grid.Rows) {
        if($row.Cells['Install'].Value -ne $true){continue}
        $name=[string]$row.Cells['ServiceName'].Value
        $exe=[string]$row.Tag.Exe
        $parts.Add(('"{0}" /sys={1} "{2}"' -f $script:InstallUtil,$name,$exe))
    }
    $preview.Text = ($parts -join [Environment]::NewLine)
}
function Set-Busy([bool]$busy) {
    $script:Installing=$busy
    $browseButton.Enabled= -not $busy
    $scanButton.Enabled= -not $busy
    $unlockButton.Enabled= -not $busy -and -not $script:Unlocking
    $markAll.Enabled= -not $busy
    $unmarkAll.Enabled= -not $busy
    $checkboxPrefix.Enabled= -not $busy
    $pathBox.Enabled= -not $busy
    $grid.ReadOnly=$busy
    if($null -ne $editConfigButton){$editConfigButton.Enabled= -not $busy}
    if($null -ne $initialConfigButton){$initialConfigButton.Enabled= -not $busy}
    $refreshServices.Enabled= -not $busy
    Update-RemoveButton
    Update-Selection
}
function Scan-Directories {
    if($script:Installing){return}
    $base=$pathBox.Text.Trim().TrimEnd('\')
    if(-not (Test-Path -LiteralPath $base -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show('Diretorio base nao encontrado. Confira o caminho.','Diretorio invalido','OK','Warning') | Out-Null
        return
    }
    $grid.Rows.Clear()
    $errors=New-Object 'System.Collections.Generic.List[string]'
    try {
        foreach($parent in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction Stop | Sort-Object Name)) {
            try {
                foreach($child in @(Get-ChildItem -LiteralPath $parent.FullName -Directory -ErrorAction Stop | Sort-Object Name)) {
                    $exe=Join-Path $child.FullName $script:ExeName
                    if(-not (Test-Path -LiteralPath $exe -PathType Leaf)){continue}
                    $name=Default-Name $parent.Name $child.Name
                    $idx=$grid.Rows.Add($false,$false,$parent.Name,$child.Name,$name,'',$child.Name,'SYSDBA','SYSDBA','Pronto para instalar','Nao executado')
                    $row=$grid.Rows[$idx]
                    $row.Tag=[pscustomobject]@{First=$parent.Name;Second=$child.Name;Exe=$exe;AutoName=$true}
                }
            } catch { $errors.Add("$($parent.FullName): $($_.Exception.Message)") }
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Erro ao buscar pastas','OK','Error') | Out-Null
        return
    }
    $foundLabel.Text="$($grid.Rows.Count) servico(s) encontrado(s)"
    $progressBar.Value=0
    $progressLabel.Text='Busca concluida'
    Update-Selection
    if($errors.Count -gt 0) {
        [System.Windows.Forms.MessageBox]::Show(('Algumas pastas nao puderam ser consultadas:'+[Environment]::NewLine+($errors -join [Environment]::NewLine)),'Busca parcial','OK','Warning') | Out-Null
    }
}
# Estado do .config de uma linha: 'config' (ja existe), 'modelo' (sera gerado do .config.modelo) ou 'ausente'.
function Get-ConfigState([string]$exe) {
    if(Test-Path -LiteralPath ($exe+'.config') -PathType Leaf){return 'config'}
    if(Test-Path -LiteralPath ($exe+'.config.modelo') -PathType Leaf){return 'modelo'}
    return 'ausente'
}
# Sem .config, reproduz o primeiro salvamento do Configurar.exe (verificado no assembly):
# o Configurar renomeia o .config.modelo para .config, grava os campos da tela, define
# passwordAuth=false e remove a chave 'pass'. O passEncrypted do modelo fica intacto e
# o servico so o le quando passwordAuth=true. Aqui o modelo e copiado (nao movido) e o
# .config so e gravado depois de todo o XML validado.
function Set-WorkflowConfig([string]$exe,[string]$hostName,[string]$systemName,[string]$userName,[string]$notifyUser,[string]$logFile) {
    $cfg = $exe + '.config'
    $model = $cfg + '.modelo'
    $fromModel = -not (Test-Path -LiteralPath $cfg -PathType Leaf)
    if($fromModel -and -not (Test-Path -LiteralPath $model -PathType Leaf)) { throw "Arquivo de configuracao nao encontrado: $cfg (nem modelo: $model)" }
    $source = $(if($fromModel){$model}else{$cfg})
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.Load($source)
    $node = $doc.SelectSingleNode('/configuration/appSettings')
    if($null -eq $node){ throw "Secao appSettings nao encontrada: $source" }
    $values = [ordered]@{ superServerHost=$hostName; systemName=$systemName; user=$userName; notifySenderUser=$notifyUser }
    if($fromModel){ $values['passwordAuth']='false' }
    # Faz a atualizacao de maneira estrita: exige que cada chave exista uma unica vez.
    foreach($key in $values.Keys) {
        $matches = @($node.SelectNodes('add') | Where-Object { $_.GetAttribute('key') -ceq $key })
        if($matches.Count -ne 1){ throw "Chave '$key' ausente ou duplicada em $source" }
        $matches[0].SetAttribute('value',[string]$values[$key])
    }
    if($fromModel){
        foreach($old in @($node.SelectNodes('add') | Where-Object { $_.GetAttribute('key') -ceq 'pass' })){ [void]$node.RemoveChild($old) }
        try {
            $doc.Save($cfg)
        } catch {
            Remove-Item -LiteralPath $cfg -Force -ErrorAction SilentlyContinue
            throw
        }
        Write-OutputLog $logFile ("CONFIG GERADO DO MODELO | Arquivo: {0} | Modelo: {1} | superServerHost={2} | systemName={3} | user={4} | notifySenderUser={5} | passwordAuth=false" -f $cfg,$model,$hostName,$systemName,$userName,$notifyUser)
        return 'gerado'
    }
    $backup = $cfg + '.backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
    Copy-Item -LiteralPath $cfg -Destination $backup -ErrorAction Stop
    try {
        $doc.Save($cfg)
    } catch {
        Copy-Item -LiteralPath $backup -Destination $cfg -Force -ErrorAction SilentlyContinue
        throw
    }
    Write-OutputLog $logFile ("CONFIG OK | Arquivo: {0} | Backup: {1} | superServerHost={2} | systemName={3} | user={4} | notifySenderUser={5}" -f $cfg,$backup,$hostName,$systemName,$userName,$notifyUser)
    return 'atualizado'
}

function Write-OutputLog([string]$file,[string]$content) {
    [System.IO.File]::AppendAllText($file,$content+[Environment]::NewLine,[System.Text.Encoding]::UTF8)
}

$form=New-Object System.Windows.Forms.Form
$form.Text='Benner Workflow - Instalador de Servicos'
$form.StartPosition='CenterScreen'
# Ajusta a janela a area util da tela; o conteudo rola quando nao couber (RDP, escala > 100%).
$workArea=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Size=New-Object System.Drawing.Size([Math]::Min(1160,$workArea.Width),[Math]::Min(1120,$workArea.Height))
$form.MinimumSize=New-Object System.Drawing.Size(800,560)
$form.BackColor=$script:Back; $form.Font=$script:Font
$form.AutoScaleMode='Dpi'; $form.KeyPreview=$true
# Todos os blocos ficam em $canvas, dentro de um painel com rolagem.
$script:CanvasMinWidth=1082
$script:CanvasMinHeight=1000
$scrollHost=New-Object System.Windows.Forms.Panel
$scrollHost.Dock='Fill'; $scrollHost.AutoScroll=$true; $scrollHost.BackColor=$script:Back
$canvas=New-Object System.Windows.Forms.Panel
$canvas.Location=New-Object System.Drawing.Point(0,0); $canvas.BackColor=$script:Back
$scrollHost.Controls.Add($canvas); $form.Controls.Add($scrollHost)

$header=New-Panel 18 15 1046 65
$header.BackColor=[System.Drawing.Color]::FromArgb(20,25,36)
$logoPath=Join-Path $PSScriptRoot 'benner-logo.png'
# No repositorio o logo fica em assets/; no pacote, ao lado do script.
if(-not (Test-Path -LiteralPath $logoPath -PathType Leaf)){$logoPath=Join-Path (Split-Path $PSScriptRoot -Parent) 'assets\benner-logo.png'}
$logoBox=New-Object System.Windows.Forms.PictureBox
$logoBox.SetBounds(16,8,173,48)
$logoBox.SizeMode='Zoom'
$logoBox.BackColor=[System.Drawing.Color]::Transparent
if(Test-Path -LiteralPath $logoPath -PathType Leaf) {
    try {
        $raw=[System.IO.File]::ReadAllBytes($logoPath)
        $stream=New-Object System.IO.MemoryStream(,$raw)
        $logoBox.Image=[System.Drawing.Image]::FromStream($stream)
        $script:LogoStream=$stream
    } catch {
        $logoBox.Image=$null
    }
}
if($null -eq $logoBox.Image) {
    $logoBox.Visible=$false
    $brand=New-Label 'benner' 19 6 175 48 $true
    $brand.Font=New-Object System.Drawing.Font('Segoe UI',26,[System.Drawing.FontStyle]::Bold)
    $brand.ForeColor=$script:Accent
    $header.Controls.Add($brand)
}
$headTitle=New-Label 'Workflow | Instalador de Servicos' 211 9 675 27 $true
$headTitle.Font=$script:TitleFont
$headSub=New-Label 'Instalacao em lote  |  Windows Services  |  Tema escuro' 213 38 700 18
$headSub.ForeColor=$script:Muted
$header.Controls.AddRange(@($logoBox,$headTitle,$headSub));$canvas.Controls.Add($header)

$settings=New-Panel 18 92 1046 132
$settings.Controls.Add((New-Label 'Diretorio base dos Workflows' 15 12 340 23 $true))
$pathBox=New-Object System.Windows.Forms.TextBox
$pathBox.Text='E:\Benner\WFL'; $pathBox.SetBounds(15,39,748,28)
$pathBox.Anchor='Top,Left,Right'
$pathBox.BackColor=[System.Drawing.Color]::FromArgb(35,43,57)
$pathBox.ForeColor=$script:Ink
$pathBox.BorderStyle='FixedSingle'
$browseButton=New-Button 'Procurar...' 777 38 112 29
$scanButton=New-Button 'Buscar pastas' 899 38 128 29 $true
$settings.Controls.AddRange(@($pathBox,$browseButton,$scanButton))
$checkboxPrefix=New-Object System.Windows.Forms.CheckBox
$checkboxPrefix.Text='Incluir VARIAVEL1 no nome do servico'; $checkboxPrefix.Checked=$true
$checkboxPrefix.SetBounds(15,83,390,24)
$checkboxPrefix.ForeColor=$script:Ink
$checkboxPrefix.BackColor=$script:White
$sample=New-Label 'Exemplo: AMBIENTE_SISTEMA_PRJ' 420 85 590 24
$sample.ForeColor=$script:Muted
$settings.Controls.AddRange(@($checkboxPrefix,$sample));$canvas.Controls.Add($settings)

$listPanel=New-Panel 18 235 1046 332
$listTitle=New-Label 'Servicos encontrados' 15 12 300 23 $true
$foundLabel=New-Label '0 servico(s) encontrado(s)' 300 12 245 23
$foundLabel.ForeColor=$script:Muted
$markAll=New-Button 'Marcar todos' 704 7 148 30
$unmarkAll=New-Button 'Desmarcar todos' 865 7 164 30
$grid=New-Object System.Windows.Forms.DataGridView
$grid.SetBounds(15,48,1014,266)
$grid.Anchor='Top,Bottom,Left,Right'
$grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false
$grid.AllowUserToResizeRows=$false; $grid.RowHeadersVisible=$false
$grid.SelectionMode='FullRowSelect'; $grid.MultiSelect=$true
$grid.AutoSizeColumnsMode='Fill'; $grid.RowTemplate.Height=32
$grid.BackgroundColor=$script:White; $grid.BorderStyle='None'
$grid.EnableHeadersVisualStyles=$false
$grid.ColumnHeadersHeight=34; $grid.ColumnHeadersHeightSizeMode='DisableResizing'
$grid.ColumnHeadersDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(38,46,62)
$grid.ColumnHeadersDefaultCellStyle.ForeColor=$script:Ink
$grid.ColumnHeadersDefaultCellStyle.Font=$script:Bold
$grid.DefaultCellStyle.Font=$script:Font
$grid.DefaultCellStyle.BackColor=$script:White
$grid.DefaultCellStyle.ForeColor=$script:Ink
$grid.DefaultCellStyle.NullValue=''
$grid.GridColor=$script:Border
$grid.RowHeadersDefaultCellStyle.BackColor=$script:White
$grid.ColumnHeadersDefaultCellStyle.SelectionBackColor=[System.Drawing.Color]::FromArgb(38,46,62)
$grid.ColumnHeadersDefaultCellStyle.SelectionForeColor=$script:Ink
$grid.DefaultCellStyle.SelectionBackColor=[System.Drawing.Color]::FromArgb(60,70,94)
$grid.DefaultCellStyle.SelectionForeColor=$script:Ink
$grid.AlternatingRowsDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(29,36,50)
$colCheck=New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colCheck.Name='Install';$colCheck.HeaderText='Instalar';$colCheck.FillWeight=9
$colUnlock=New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colUnlock.Name='Unlock';$colUnlock.HeaderText='Desbloquear';$colUnlock.FillWeight=14
$colFirst=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFirst.Name='First';$colFirst.HeaderText='VARIAVEL1';$colFirst.FillWeight=17;$colFirst.ReadOnly=$true
$colSecond=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colSecond.Name='Second';$colSecond.HeaderText='VARIAVEL2';$colSecond.FillWeight=17;$colSecond.ReadOnly=$true
$colName=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colName.Name='ServiceName';$colName.HeaderText='Nome do servico (editavel)';$colName.FillWeight=28
$colHost=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colHost.Name='SuperServerHost';$colHost.HeaderText='Benner Server (host)';$colHost.FillWeight=24
$colSystem=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colSystem.Name='SystemName';$colSystem.HeaderText='SYSTEMNAME';$colSystem.FillWeight=22
$colUser=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colUser.Name='WorkflowUser';$colUser.HeaderText='Usuario';$colUser.FillWeight=19
$colNotify=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colNotify.Name='NotifySenderUser';$colNotify.HeaderText='Usuario notificacao';$colNotify.FillWeight=24
$colStatus=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colStatus.Name='Status';$colStatus.HeaderText='Resultado';$colStatus.FillWeight=15;$colStatus.ReadOnly=$true
$colUnlockStatus=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colUnlockStatus.Name='UnlockStatus';$colUnlockStatus.HeaderText='Desbloqueio';$colUnlockStatus.FillWeight=18;$colUnlockStatus.ReadOnly=$true
[void]$grid.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($colCheck,$colUnlock,$colFirst,$colSecond,$colName,$colHost,$colSystem,$colUser,$colNotify,$colStatus,$colUnlockStatus))
$listPanel.Controls.AddRange(@($listTitle,$foundLabel,$markAll,$unmarkAll,$grid));$canvas.Controls.Add($listPanel)


# Grade independente para gerenciar Workflow Services instalados.
$installedPanel=New-Panel 18 837 1046 239
$installedTitle=New-Label 'Workflow Services instalados no Windows' 15 9 480 24 $true
$refreshServices=New-Button 'Atualizar lista' 628 7 128 29
$removeServices=New-Button 'Remover selecionados' 766 7 264 29 $true
$removeServices.Enabled=$false
$removeServices.BackColor=[System.Drawing.Color]::FromArgb(166,38,55)
$installedGrid=New-Object System.Windows.Forms.DataGridView
$installedGrid.SetBounds(15,87,1014,138)
$installedGrid.Anchor='Top,Bottom,Left,Right'
$installedGrid.AllowUserToAddRows=$false;$installedGrid.AllowUserToDeleteRows=$false
$installedGrid.RowHeadersVisible=$false;$installedGrid.AllowUserToResizeRows=$false
$installedGrid.SelectionMode='FullRowSelect';$installedGrid.AutoSizeColumnsMode='Fill'
$installedGrid.RowTemplate.Height=29;$installedGrid.BackgroundColor=$script:White
$installedGrid.BorderStyle='None';$installedGrid.EnableHeadersVisualStyles=$false
$installedGrid.ColumnHeadersHeight=32
$installedGrid.ColumnHeadersDefaultCellStyle.BackColor=[System.Drawing.Color]::FromArgb(38,46,62)
$installedGrid.ColumnHeadersDefaultCellStyle.ForeColor=$script:Ink
$installedGrid.ColumnHeadersDefaultCellStyle.SelectionBackColor=[System.Drawing.Color]::FromArgb(38,46,62)
$installedGrid.DefaultCellStyle.BackColor=$script:White
$installedGrid.DefaultCellStyle.ForeColor=$script:Ink
$installedGrid.DefaultCellStyle.SelectionBackColor=[System.Drawing.Color]::FromArgb(60,70,94)
$installedGrid.DefaultCellStyle.SelectionForeColor=$script:Ink
$installedGrid.GridColor=$script:Border
$ic1=New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$icLogin=New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$icLogin.Name='LoginSel';$icLogin.HeaderText='Login';$icLogin.FillWeight=9
$ic1.Name='Remove';$ic1.HeaderText='Remover';$ic1.FillWeight=10
$ic2=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ic2.Name='WinName';$ic2.HeaderText='Nome interno';$ic2.FillWeight=29;$ic2.ReadOnly=$true
$ic3=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ic3.Name='Display';$ic3.HeaderText='Nome exibido';$ic3.FillWeight=31;$ic3.ReadOnly=$true
$ic4=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ic4.Name='WinStatus';$ic4.HeaderText='Status';$ic4.FillWeight=13;$ic4.ReadOnly=$true
$ic5=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ic5.Name='ExeFolder';$ic5.HeaderText='Pasta do executavel';$ic5.FillWeight=55;$ic5.ReadOnly=$true
$ic6=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ic6.Name='RemoveResult';$ic6.HeaderText='Resultado';$ic6.FillWeight=24;$ic6.ReadOnly=$true
[void]$installedGrid.Columns.AddRange([System.Windows.Forms.DataGridViewColumn[]]@($icLogin,$ic1,$ic2,$ic3,$ic4,$ic5,$ic6))
$accountLabel=New-Label 'Usuario do Windows' 15 43 135 24
$accountBox=New-Object System.Windows.Forms.TextBox
$accountBox.SetBounds(151,41,243,28);$accountBox.BackColor=[System.Drawing.Color]::FromArgb(35,43,57)
$accountBox.ForeColor=$script:Ink;$accountBox.BorderStyle='FixedSingle'
$accountBox.Text='DOMINIO\usuario'
$passwordLabel=New-Label 'Senha' 405 43 48 24
$passwordBox=New-Object System.Windows.Forms.TextBox
$passwordBox.SetBounds(458,41,255,28);$passwordBox.BackColor=[System.Drawing.Color]::FromArgb(35,43,57)
$passwordBox.ForeColor=$script:Ink;$passwordBox.UseSystemPasswordChar=$true
$passwordBox.BorderStyle='FixedSingle'
$changeLogin=New-Button 'Alterar login selecionados' 723 40 307 30 $true
$changeLogin.Enabled=$false
$changeLogin.BackColor=[System.Drawing.Color]::FromArgb(43,112,199)
$installedPanel.Controls.AddRange(@($installedTitle,$refreshServices,$removeServices,$accountLabel,$accountBox,$passwordLabel,$passwordBox,$changeLogin,$installedGrid))
$canvas.Controls.Add($installedPanel)

function Get-WinExePath([string]$binaryPath) {
    if([string]::IsNullOrWhiteSpace($binaryPath)){return $null}
    $m=[regex]::Match($binaryPath,'^\s*"([^"]+?\.exe)"', 'IgnoreCase')
    if(-not $m.Success){$m=[regex]::Match($binaryPath,'^\s*(.+?\.exe)(?=\s|$)','IgnoreCase')}
    if(-not $m.Success){return $null}
    return $m.Groups[1].Value.Trim()
}
function Refresh-Installed {
    if($script:Installing -or $script:Unlocking -or $script:Removing -or $script:ChangingLogin){return}
    $installedGrid.Rows.Clear()
    try {
        $items=@(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object {
            $_.Name -like '*Workflow Service*' -or $_.DisplayName -like '*Workflow Service*'
        } | Sort-Object DisplayName)
        foreach($svc in $items) {
            $exe=Get-WinExePath ([string]$svc.PathName)
            $folder=if($exe){[IO.Path]::GetDirectoryName($exe)}else{''}
            $ix=$installedGrid.Rows.Add($false,$false,[string]$svc.Name,[string]$svc.DisplayName,[string]$svc.State,$folder,'')
            $installedGrid.Rows[$ix].Tag=[pscustomobject]@{ Name=[string]$svc.Name; Display=[string]$svc.DisplayName; Exe=$exe; Folder=$folder }
        }
        $installedTitle.Text="Workflow Services instalados no Windows ($($items.Count))"
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Falha consultando servicos','OK','Error') | Out-Null
    }
    $removeServices.Enabled=$false
    $changeLogin.Enabled=$false
}
function Is-SafeRemovalFolder([string]$folder,[string]$exe,[string]$root) {
    if([string]::IsNullOrWhiteSpace($folder) -or [string]::IsNullOrWhiteSpace($root)){return $false}
    try {
        $r=[IO.Path]::GetFullPath($root).TrimEnd('\')
        $f=[IO.Path]::GetFullPath($folder).TrimEnd('\')
        $expected=[IO.Path]::GetFullPath((Join-Path $f $script:ExeName))
        if(-not $f.StartsWith($r+'\',[StringComparison]::OrdinalIgnoreCase)){return $false}
        $relative=$f.Substring($r.Length+1).Split('\')
        if($relative.Count -ne 2 -or @($relative | Where-Object { -not $_ -or $_ -in @('.','..') }).Count -gt 0){return $false}
        if(-not [string]::Equals($expected,[IO.Path]::GetFullPath($exe),[StringComparison]::OrdinalIgnoreCase)){return $false}
        if(-not (Test-Path -LiteralPath $expected -PathType Leaf)){return $false}
        # Nao acompanhar junctions/symlinks ou reparse points na arvore alvo.
        foreach($segment in @($r,(Join-Path $r $relative[0]),$f)) {
            if(([IO.File]::GetAttributes($segment) -band [IO.FileAttributes]::ReparsePoint) -ne 0){return $false}
        }
        $linked=Get-ChildItem -LiteralPath $f -Force -Recurse -ErrorAction Stop | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } | Select-Object -First 1
        if($linked){return $false}
        return $true
    } catch {return $false}
}
function Update-RemoveButton {
    $changeLogin.Enabled=(-not $script:Installing -and -not $script:Unlocking -and -not $script:Removing -and -not $script:ChangingLogin -and @($installedGrid.Rows | Where-Object { $_.Cells['LoginSel'].Value -eq $true }).Count -gt 0)
    $removeServices.Enabled=(-not $script:Installing -and -not $script:Unlocking -and -not $script:Removing -and -not $script:ChangingLogin -and @($installedGrid.Rows | Where-Object { $_.Cells['Remove'].Value -eq $true }).Count -gt 0)
}
$installedGrid.Add_CurrentCellDirtyStateChanged({if($installedGrid.IsCurrentCellDirty){$installedGrid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null}})
$installedGrid.Add_CellValueChanged({Update-RemoveButton})
$refreshServices.Add_Click({Refresh-Installed})
$removeServices.Add_Click({
    $installedGrid.EndEdit() | Out-Null
    $targets=@($installedGrid.Rows | Where-Object {$_.Cells['Remove'].Value -eq $true})
    if($targets.Count -eq 0){return}
    $root=$pathBox.Text.Trim()
    $allSvcs=@(Get-CimInstance Win32_Service -ErrorAction Stop)
    $issues=New-Object 'System.Collections.Generic.List[string]'
    foreach($row in $targets) {
        $item=$row.Tag
        if(-not (Is-SafeRemovalFolder $item.Folder $item.Exe $root)){$issues.Add("Caminho fora do padrao WFL ou inseguro: $($item.Name) -> $($item.Folder)");continue}
        $duplicates=@($allSvcs | Where-Object { $_.Name -ne $item.Name -and [string]::Equals((Get-WinExePath ([string]$_.PathName)),$item.Exe,[StringComparison]::OrdinalIgnoreCase) })
        if($duplicates.Count -gt 0){$issues.Add("Executavel compartilhado por outro servico: $($item.Name)")}
        if(-not @($allSvcs | Where-Object { $_.Name -eq $item.Name -and ($_.Name -like '*Workflow Service*' -or $_.DisplayName -like '*Workflow Service*') }).Count){$issues.Add("Servico mudou desde a leitura: $($item.Name)")}
    }
    if($issues.Count -gt 0){[System.Windows.Forms.MessageBox]::Show(($issues -join "`r`n"),'Remocao bloqueada','OK','Warning') | Out-Null;return}
    $detail=($targets | ForEach-Object {"$($_.Tag.Name)  ->  $($_.Tag.Folder)"}) -join "`r`n"
    $msg="ATENCAO: remocao PERMANENTE de $($targets.Count) servico(s) E suas pastas:`r`n`r`n$detail`r`n`r`nIsso nao pode ser desfeito. Continuar?"
    if([System.Windows.Forms.MessageBox]::Show($msg,'Confirmar exclusao de servicos e arquivos','YesNo','Warning',[System.Windows.Forms.MessageBoxDefaultButton]::Button2) -ne 'Yes'){return}
    $script:Removing=$true
    $changeLogin.Enabled=$false
    $removeServices.Enabled=$false;$refreshServices.Enabled=$false;$installedGrid.ReadOnly=$true
    $browseButton.Enabled=$false;$scanButton.Enabled=$false;$installButton.Enabled=$false;$unlockButton.Enabled=$false
    New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null
    $removeLog=Join-Path $script:LogDirectory ('Workflow_Remocao_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    try {
        foreach($row in $targets){
            $item=$row.Tag
            $row.Cells['RemoveResult'].Value='Removendo...'
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $service=Get-Service -Name $item.Name -ErrorAction Stop
                if($service.Status -ne 'Stopped'){
                    Stop-Service -InputObject $service -ErrorAction Stop
                    $service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30))
                }
                $out=& "$env:WINDIR\System32\sc.exe" delete $item.Name 2>&1 | Out-String
                if($LASTEXITCODE -ne 0){throw "sc delete falhou: $out"}
                $gone=$false
                for($n=0;$n -lt 30;$n++){
                    [System.Windows.Forms.Application]::DoEvents()
                    if(-not (Get-CimInstance Win32_Service -Filter ("Name='{0}'" -f $item.Name.Replace("'","''")) -ErrorAction SilentlyContinue)){$gone=$true;break}
                    Start-Sleep -Milliseconds 500
                }
                if(-not $gone){throw 'Servico ainda listado pelo Windows (possivelmente marcado para exclusao). Pasta preservada.'}
                # Revalidar antes de apagar: a remocao pode ter mudado a arvore.
                if(-not (Is-SafeRemovalFolder $item.Folder $item.Exe $root)){throw 'Pasta nao passou na verificacao de seguranca final.'}
                $stillUsing=@(Get-CimInstance Win32_Service -ErrorAction Stop | Where-Object { [string]::Equals((Get-WinExePath ([string]$_.PathName)),$item.Exe,[StringComparison]::OrdinalIgnoreCase) })
                if($stillUsing.Count){throw 'Outro servico ainda referencia o executavel. Pasta preservada.'}
                Remove-Item -LiteralPath $item.Folder -Recurse -Force -ErrorAction Stop
                $row.Cells['RemoveResult'].Value='Removido + pasta'
                Add-Content -LiteralPath $removeLog -Value "$(Get-Date -Format o) OK $($item.Name) $($item.Folder)" -Encoding UTF8
            } catch {
                $row.Cells['RemoveResult'].Value='Falha / verificar log'
                Add-Content -LiteralPath $removeLog -Value "$(Get-Date -Format o) FALHA $($item.Name): $($_.Exception.Message)" -Encoding UTF8
            }
        }
    } finally {
        $script:Removing=$false
        $refreshServices.Enabled=$true;$installedGrid.ReadOnly=$false
        $browseButton.Enabled=$true;$scanButton.Enabled=$true
        Update-Selection
        Update-RemoveButton
    }
    [System.Windows.Forms.MessageBox]::Show("Remocao concluida. Consulte os resultados na grade e o log:`r`n$removeLog",'Resultado da remocao','OK','Information') | Out-Null
})


# Login usa a coluna 'Login'; a remocao usa a coluna 'Remover' (selecoes independentes).
$changeLogin.Add_Click({
    [void]$installedGrid.EndEdit()
    $targets=@($installedGrid.Rows | Where-Object { $_.Cells['LoginSel'].Value -eq $true })
    if($targets.Count -eq 0){return}
    $account=Normalize-ServiceAccount $accountBox.Text
    if([string]::IsNullOrWhiteSpace($account) -or $account -eq 'DOMINIO\usuario' -or $account -notmatch '^[^\\]+\\[^\\]+$' -or $account -match '\s'){
        [System.Windows.Forms.MessageBox]::Show('Informe DOMINIO\usuario ou .\usuario (conta local).','Usuario invalido','OK','Warning') | Out-Null;return
    }
    # gMSA (conta terminada em $) nao usa senha: o Windows exige senha nula.
    $isManaged=$account.EndsWith('$')
    if($isManaged -and -not [string]::IsNullOrEmpty($passwordBox.Text)){
        [System.Windows.Forms.MessageBox]::Show('Contas gMSA (terminadas em $) nao usam senha. Deixe o campo Senha vazio.','Senha nao permitida','OK','Warning') | Out-Null;return
    }
    if(-not $isManaged -and [string]::IsNullOrEmpty($passwordBox.Text)){
        [System.Windows.Forms.MessageBox]::Show('Informe a senha da conta. A senha nao sera salva nos logs.','Senha necessaria','OK','Warning') | Out-Null;return
    }
    $names=($targets | ForEach-Object { $_.Tag.Name }) -join "`r`n"
    $question="Alterar a conta de logon de $($targets.Count) servico(s) para $account ?`r`n`r`n$names`r`n`r`nOs servicos em execucao precisam ser reiniciados para utilizar a nova conta."
    if([System.Windows.Forms.MessageBox]::Show($question,'Confirmar alteracao de login','YesNo','Question',[System.Windows.Forms.MessageBoxDefaultButton]::Button2) -ne 'Yes'){return}
    $script:ChangingLogin=$true
    $changeLogin.Enabled=$false;$removeServices.Enabled=$false;$refreshServices.Enabled=$false
    $installedGrid.ReadOnly=$true;$accountBox.Enabled=$false;$passwordBox.Enabled=$false
    $browseButton.Enabled=$false;$scanButton.Enabled=$false;$installButton.Enabled=$false;$unlockButton.Enabled=$false
    $log=Join-Path $script:LogDirectory ('Workflow_Logon_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    $changed=New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $grantError=$null
    try {
        New-Item -ItemType Directory -Path $script:LogDirectory -Force -ErrorAction Stop | Out-Null
        # Uma falha aqui (ex.: GPO) nao impede a alteracao: o direito pode ja existir.
        # O teste de partida opcional confirma se a conta consegue iniciar o servico.
        try { [WorkflowServiceCredentials]::AllowServiceLogon($account) }
        catch {
            $grantError=$_.Exception.Message
            Add-Content -LiteralPath $log -Encoding UTF8 -Value "$(Get-Date -Format o) AVISO nao foi possivel conceder Log on as a service a ${account}: $grantError"
        }
        foreach($row in $targets) {
            $name=[string]$row.Tag.Name
            $row.Cells['RemoveResult'].Value='Alterando login...'
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $before=Read-ServiceLogon $name
                if(-not ($before.Name -like '*Workflow Service*' -or $before.DisplayName -like '*Workflow Service*')){throw 'O servico nao corresponde mais ao filtro Workflow Service.'}
                # gMSA: senha nula ([NullString]), nunca string vazia.
                if($isManaged){[WorkflowServiceCredentials]::SetLogon($name,$account,[NullString]::Value)}
                else{[WorkflowServiceCredentials]::SetLogon($name,$account,$passwordBox.Text)}
                $after=Read-ServiceLogon $name
                $expected=(New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                $actual=(New-Object System.Security.Principal.NTAccount($after.StartName)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                if($expected -ne $actual){throw "Conta do servico nao confere. Atual: $($after.StartName)"}
                $row.Cells['RemoveResult'].Value=$(if($grantError){'Login alterado (sem direito confirmado)'}else{'Login alterado (nao testado)'})
                [void]$changed.Add($name)
                Add-Content -LiteralPath $log -Encoding UTF8 -Value "$(Get-Date -Format o) LOGIN ALTERADO $name $($after.StartName); estado=$($after.State); senha omitida"
            } catch {
                $row.Cells['RemoveResult'].Value='Falha no login / ver log'
                Add-Content -LiteralPath $log -Encoding UTF8 -Value "$(Get-Date -Format o) FALHA $name - $($_.Exception.Message)"
            }
        }
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Erro na operacao','OK','Error') | Out-Null }
    finally {
        $passwordBox.Clear()  # never retain the password after applying it
        $script:ChangingLogin=$false
        $refreshServices.Enabled=$true;$installedGrid.ReadOnly=$false
        $accountBox.Enabled=$true;$passwordBox.Enabled=$true
        $browseButton.Enabled=$true;$scanButton.Enabled=$true
        Update-Selection;Update-RemoveButton
    }
    if($changed.Count -eq 0){
        [System.Windows.Forms.MessageBox]::Show("Nenhum servico foi alterado. Consulte o log:`r`n$log",'Alteracao de login','OK','Warning') | Out-Null
        return
    }
    $grantNote=$(if($grantError){"`r`n`r`nATENCAO: nao foi possivel conceder 'Log on as a service' ($grantError). Se a conta ainda nao tiver esse direito, o servico nao vai iniciar."}else{''})
    $answer=[System.Windows.Forms.MessageBox]::Show("Alteracao registrada.$grantNote`r`n`r`nPara VALIDAR a senha, voce pode reiniciar os servicos selecionados (havera interrupcao).`r`n`r`nReiniciar agora?",'Validacao das credenciais','YesNo','Question',[System.Windows.Forms.MessageBoxDefaultButton]::Button2)
    if($answer -eq 'Yes'){
        foreach($row in $targets){
            $name=[string]$row.Tag.Name
            if(-not $changed.Contains($name)){continue}
            try {
                $svc=Get-Service -Name $name -ErrorAction Stop
                if($svc.Status -ne 'Stopped') { Stop-Service -Name $name -ErrorAction Stop; $svc.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(60)) }
                Start-Service -Name $name -ErrorAction Stop
                $svc=Get-Service -Name $name -ErrorAction Stop
                $svc.WaitForStatus('Running',[TimeSpan]::FromSeconds(60))
                $row.Cells['RemoveResult'].Value='Login OK (servico iniciou)'
                Add-Content -LiteralPath $log -Encoding UTF8 -Value "$(Get-Date -Format o) START OK $name"
            } catch {
                $row.Cells['RemoveResult'].Value='Inicio falhou / ver log'
                Add-Content -LiteralPath $log -Encoding UTF8 -Value "$(Get-Date -Format o) START FALHOU $name - $($_.Exception.Message)"
            }
        }
    }
    [System.Windows.Forms.MessageBox]::Show("Consulte os resultados por servico e o log:`r`n$log",'Alteracao de login','OK','Information') | Out-Null
})

$previewPanel=New-Panel 18 585 1046 100
$previewTitle=New-Label 'Previa dos comandos selecionados' 15 9 530 23 $true
$selectedCount=New-Label '0 selecionado(s)' 778 10 220 21
$selectedCount.TextAlign='MiddleRight'
$preview=New-Object System.Windows.Forms.TextBox
$preview.Multiline=$true;$preview.ReadOnly=$true;$preview.ScrollBars='Vertical'
$preview.Font=New-Object System.Drawing.Font('Consolas',8.4)
$preview.BackColor=[System.Drawing.Color]::FromArgb(16,22,33)
$preview.ForeColor=[System.Drawing.Color]::FromArgb(184,209,236)
$preview.BorderStyle='FixedSingle'
$preview.SetBounds(15,36,1014,69);$preview.Anchor='Top,Bottom,Left,Right'
$previewPanel.Controls.AddRange(@($previewTitle,$selectedCount,$preview));$canvas.Controls.Add($previewPanel)

$footer=New-Panel 18 697 1046 120
$summary=New-Label '0 servico(s) selecionado(s) para instalacao' 15 8 650 21 $true
$progressLabel=New-Label 'Pronto' 15 31 640 19
$progressLabel.ForeColor=$script:Muted
$progressBar=New-Object System.Windows.Forms.ProgressBar
$progressBar.SetBounds(15,91,765,17);$progressBar.Minimum=0;$progressBar.Maximum=100
$logsButton=New-Button 'Abrir logs' 648 12 105 32
$initialConfigButton=New-Button 'Abrir Configurar (inicial)' 15 54 213 31
$editConfigButton=New-Button 'Editar .config selecionados' 237 54 220 31
$initialConfigButton.Enabled=$false
$editConfigButton.Enabled=$false
$unlockButton=New-Button 'Desbloquear marcados' 759 12 143 50
$unlockButton.BackColor=[System.Drawing.Color]::White
$unlockButton.ForeColor=[System.Drawing.Color]::FromArgb(24,30,42)
$unlockButton.Enabled=$false
$installButton=New-Button 'Instalar selecionados' 908 12 122 50 $true
$installButton.Enabled=$false
$footer.Controls.AddRange(@($summary,$progressLabel,$progressBar,$logsButton,$unlockButton,$installButton,$initialConfigButton,$editConfigButton));$canvas.Controls.Add($footer)

function Resize-Layout {
    # Calcula o tamanho do canvas descontando as barras de rolagem que ele mesmo vai exigir.
    $hostW=$scrollHost.Width; $hostH=$scrollHost.Height
    $needV=$hostH -lt $script:CanvasMinHeight
    if($needV){$hostW-=[System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth}
    $needH=$hostW -lt $script:CanvasMinWidth
    if($needH){$hostH-=[System.Windows.Forms.SystemInformation]::HorizontalScrollBarHeight}
    if($needH -and -not $needV -and $hostH -lt $script:CanvasMinHeight){$hostW-=[System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth}
    $canvasW=[Math]::Max($hostW,$script:CanvasMinWidth)
    $canvasH=[Math]::Max($hostH,$script:CanvasMinHeight)
    $canvas.Size=New-Object System.Drawing.Size($canvasW,$canvasH)
    $w=$canvasW-36
    $header.Width=$w; $settings.Width=$w; $listPanel.Width=$w
    $previewPanel.Width=$w;$footer.Width=$w;$installedPanel.Width=$w
    $pathBox.Width=$w-298
    $browseButton.Left=$w-269;$scanButton.Left=$w-143
    $markAll.Left=$w-342;$unmarkAll.Left=$w-180
    $grid.Width=$w-30;$preview.Width=$w-30;$installedGrid.Width=$w-30
    $refreshServices.Left=$w-418;$removeServices.Left=$w-280
    $changeLogin.Left=$w-322
    $selectedCount.Left=$w-253
    $installButton.Left=$w-138;$unlockButton.Left=$w-287;$logsButton.Left=$w-398
    $progressBar.Width=$w-420
    # Ordem visual: instalacao (grade, comandos, botoes) e, por ultimo,
    # gerenciamento de servicos instalados (login e remocao).
    $installedPanel.Top=$canvasH-$installedPanel.Height-18
    $footer.Top=$installedPanel.Top-$footer.Height-12
    $previewPanel.Top=$footer.Top-$previewPanel.Height-12
    $listPanel.Top=235
    $listPanel.Height=[Math]::Max(250,$previewPanel.Top-$listPanel.Top-12)
    $grid.Height=$listPanel.Height-66
}
$scrollHost.Add_Resize({ Resize-Layout })
$browseButton.Add_Click({
    $dialog=New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description='Selecione o diretorio base de Workflow (WFL)'
    if(Test-Path -LiteralPath $pathBox.Text -PathType Container){$dialog.SelectedPath=$pathBox.Text}
    if($dialog.ShowDialog($form) -eq 'OK'){$pathBox.Text=$dialog.SelectedPath;Scan-Directories}
    $dialog.Dispose()
})
$scanButton.Add_Click({Scan-Directories})
$checkboxPrefix.Add_CheckedChanged({
    foreach($row in $grid.Rows){
        if($row.Tag.AutoName){$row.Cells['ServiceName'].Value=Default-Name $row.Tag.First $row.Tag.Second}
    }
    $sample.Text=$(if($checkboxPrefix.Checked){'Exemplo: AMBIENTE_SISTEMA_PRJ'}else{'Exemplo: SISTEMA_PRJ'})
    Update-Preview
})
$grid.Add_CurrentCellDirtyStateChanged({if($grid.IsCurrentCellDirty){$grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit) | Out-Null}})
$grid.Add_CellValueChanged({param($sender,$e)
    if($e.RowIndex -lt 0){return}
    if($e.ColumnIndex -eq $grid.Columns['ServiceName'].Index){
        $row=$grid.Rows[$e.RowIndex]
        if($row.Tag){
            $expected=Default-Name $row.Tag.First $row.Tag.Second
            $row.Tag.AutoName=([string]$row.Cells['ServiceName'].Value -ceq $expected)
        }
    }
    Update-Selection
})
$markAll.Add_Click({foreach($row in $grid.Rows){$row.Cells['Install'].Value=$true};Update-Selection})
$unmarkAll.Add_Click({foreach($row in $grid.Rows){$row.Cells['Install'].Value=$false};Update-Selection})
$logsButton.Add_Click({
    if(-not (Test-Path $script:LogDirectory)){New-Item -ItemType Directory -Path $script:LogDirectory -Force | Out-Null}
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:LogDirectory)
})

# Desbloqueio de arquivos por linha: somente remove Zone.Identifier (Mark of the Web).
# Nao altera ACLs e nao libera locks de processos. Recursao nao segue junctions/reparse points.
$unlockButton.Add_Click({
    if($script:Installing -or $script:Unlocking -or $script:EditingConfig){return}
    [void]$grid.EndEdit()
    $jobs=New-Object 'System.Collections.Generic.List[object]'
    foreach($row in $grid.Rows){
        if($row.Cells['Unlock'].Value -eq $true){
            $folder=[IO.Path]::GetDirectoryName([string]$row.Tag.Exe)
            if(-not (Test-Path -LiteralPath $folder -PathType Container)){
                [System.Windows.Forms.MessageBox]::Show("Pasta nao encontrada: $folder",'Erro','OK','Error') | Out-Null
                return
            }
            $jobs.Add([pscustomobject]@{ Index=$row.Index; Folder=$folder; Name=[string]$row.Cells['ServiceName'].Value })
        }
    }
    if($jobs.Count -eq 0){return}
    $msg="Desbloquear arquivos de $($jobs.Count) pasta(s) Workflow (incluindo subpastas)?`r`n`r`nIsto remove o marcador de origem da Internet (Zone.Identifier) dos arquivos encontrados. Nao remove bloqueios de processos ou permissoes NTFS.`r`n`r`nContinuar?"
    if([System.Windows.Forms.MessageBox]::Show($msg,'Confirmar desbloqueio','YesNo','Warning') -ne 'Yes'){return}
    try {New-Item -ItemType Directory -Path $script:LogDirectory -Force -ErrorAction Stop | Out-Null} catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Erro criando logs','OK','Error') | Out-Null;return
    }
    $script:Unlocking=$true
    $script:UnlockQueue=$jobs.ToArray();$script:UnlockPosition=0
    $script:UnlockProcess=$null
    $script:UnlockLog=Join-Path $script:LogDirectory ('Workflow_Desbloqueio_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    $grid.ReadOnly=$true;$unlockButton.Enabled=$false;$installButton.Enabled=$false
    $browseButton.Enabled=$false;$scanButton.Enabled=$false
    $markAll.Enabled=$false;$unmarkAll.Enabled=$false;$checkboxPrefix.Enabled=$false
    $pathBox.Enabled=$false
    foreach($job in $jobs){$grid.Rows[$job.Index].Cells['UnlockStatus'].Value='Na fila'}
    Start-NextUnlock
    if($script:Unlocking){$unlockTimer.Start()}
})
$unlockTimer=New-Object System.Windows.Forms.Timer
$unlockTimer.Interval=350
function Finish-UnlockBatch {
    $unlockTimer.Stop()
    $script:Unlocking=$false
    $grid.ReadOnly=$false
    $browseButton.Enabled=$true;$scanButton.Enabled=$true
    $markAll.Enabled=$true;$unmarkAll.Enabled=$true;$checkboxPrefix.Enabled=$true
    $pathBox.Enabled=$true
    $progressBar.Value=100
    $progressLabel.Text='Desbloqueio finalizado. Consulte a coluna Desbloqueio e o log.'
    Update-Selection
    [System.Windows.Forms.MessageBox]::Show("Desbloqueio finalizado.`r`nConfira os resultados por linha.`r`nLog: $script:UnlockLog",'Desbloqueio concluido','OK','Information') | Out-Null
}
function Start-NextUnlock {
    if($script:UnlockPosition -ge $script:UnlockQueue.Count){Finish-UnlockBatch;return}
    $job=$script:UnlockQueue[$script:UnlockPosition]
    $script:CurrentUnlockJob=$job
    $n=$script:UnlockPosition+1
    $grid.Rows[$job.Index].Cells['UnlockStatus'].Value='Desbloqueando...'
    $progressLabel.Text="Desbloqueando $n/$($script:UnlockQueue.Count): $($job.Name)"
    $progressBar.Value=[int](($script:UnlockPosition*100)/$script:UnlockQueue.Count)
    $childCode=@'
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
    $quotes=@($job.Folder,$script:UnlockLog) | ForEach-Object {"'" + ($_.Replace("'","''")) + "'"}
    $launch='& { '+$childCode+' } '+($quotes -join ' ')
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
    try {
        $psi=New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName=(Join-Path $PSHOME 'powershell.exe')
        $psi.Arguments="-NoProfile -NonInteractive -EncodedCommand $encoded"
        $psi.WorkingDirectory=$job.Folder
        $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
        $p=New-Object System.Diagnostics.Process;$p.StartInfo=$psi
        [void]$p.Start();$script:UnlockProcess=$p
    } catch {
        $grid.Rows[$job.Index].Cells['UnlockStatus'].Value='Falha ao iniciar'
        Write-OutputLog $script:UnlockLog ("FALHA INICIANDO {0}: {1}" -f $job.Folder,$_.Exception.Message)
        $script:UnlockPosition++
        Start-NextUnlock
    }
}
$unlockTimer.Add_Tick({
    if($null -eq $script:UnlockProcess){return}
    if(-not $script:UnlockProcess.HasExited){return}
    $code=$script:UnlockProcess.ExitCode
    $job=$script:CurrentUnlockJob
    $grid.Rows[$job.Index].Cells['UnlockStatus'].Value=$(if($code -eq 0){'Concluido'}else{'Falha (ver log)'})
    $grid.Rows[$job.Index].Cells['UnlockStatus'].Style.ForeColor=$(if($code -eq 0){[Drawing.Color]::FromArgb(103,225,158)}else{[Drawing.Color]::FromArgb(255,121,138)})
    $script:UnlockProcess.Dispose();$script:UnlockProcess=$null
    $script:UnlockPosition++
    Start-NextUnlock
})

# Timer na thread da interface: monitora cada InstallUtil sem bloquear a janela.
# Cada instalacao roda em processo separado com log redirecionado para arquivo.
$script:Queue=@()
$script:QueuePosition=0
$script:CurrentProcess=$null
$script:CurrentTask=$null
$script:CurrentLog=$null
$script:SessionLog=$null
$timer=New-Object System.Windows.Forms.Timer
$timer.Interval=350
function Start-NextInstallation {
    if($script:QueuePosition -ge $script:Queue.Count) {
        $timer.Stop()
        $script:CurrentProcess=$null
        Set-Busy $false
        $ok=0;$failed=0
        foreach($row in $grid.Rows){
            if([string]$row.Cells['Status'].Value -like 'Sucesso*'){$ok++}
            elseif([string]$row.Cells['Status'].Value -like 'Falha*'){$failed++}
        }
        $progressBar.Value=100
        $progressLabel.Text="Lote concluido: $ok sucesso(s), $failed falha(s)."
        [System.Windows.Forms.MessageBox]::Show("Instalacao finalizada.`r`n`r`nSucesso: $ok`r`nFalha: $failed`r`n`r`nLogs: $script:LogDirectory",'Resultado da instalacao','OK','Information') | Out-Null
        return
    }
    $task=$script:Queue[$script:QueuePosition]
    $script:CurrentTask=$task
    $configError=$null
    $task | Add-Member -NotePropertyName ConfigResult -NotePropertyValue '' -Force
    if((Get-ConfigState $task.Exe) -ne 'ausente'){
        try {
            $grid.Rows[$task.Index].Cells['Status'].Value='Configurando...'
            $task.ConfigResult=Set-WorkflowConfig $task.Exe $task.Host $task.System $task.User $task.NotifyUser $script:SessionLog
        } catch {
            $configError=$_.Exception.Message
        }
    } else {
        # Sem .config e sem .config.modelo: instala sem editar, conforme confirmado.
        Write-OutputLog $script:SessionLog ("CONFIG IGNORADO | $($task.Name) | arquivo ausente: $($task.Exe).config (sem .config.modelo)")
    }
    if($null -ne $configError) {
        $grid.Rows[$task.Index].Cells['Status'].Value='Falha (config)'
        $grid.Rows[$task.Index].Cells['Status'].Style.ForeColor=[Drawing.Color]::FromArgb(255,121,138)
        Write-OutputLog $script:SessionLog ("CONFIG FALHA | $($task.Name) | $configError")
        $script:QueuePosition++
        Start-NextInstallation
        return
    }
    $n=$script:QueuePosition+1
    $grid.Rows[$task.Index].Cells['Status'].Value='Instalando...'
    $progressLabel.Text="Instalando $n/$($script:Queue.Count): $($task.Name)"
    $progressBar.Value=[int](($script:QueuePosition*100)/$script:Queue.Count)
    $script:CurrentLog=Join-Path $script:LogDirectory ("{0:D3}_{1}.log" -f $n,(Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    # Codificacao evita problemas com espacos e acentos no caminho do executavel.
    # /sys continua sendo passado ao InstallUtil como argumento independente.
    $psCode=@'
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
    # Embed os parametros como valores literais no script do processo filho.
    $quotes=@($script:InstallUtil,$task.Name,$task.Exe,$script:CurrentLog) | ForEach-Object { "'" + ($_.Replace("'","''")) + "'" }
    $launch='& { '+$psCode+' } '+($quotes -join ' ')
    $encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
    try {
        $psi=New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName=(Join-Path $PSHOME 'powershell.exe')
        $psi.Arguments="-NoProfile -NonInteractive -EncodedCommand $encoded"
        $psi.WorkingDirectory=[IO.Path]::GetDirectoryName($task.Exe)
        $psi.UseShellExecute=$false
        $psi.CreateNoWindow=$true
        $p=New-Object System.Diagnostics.Process
        $p.StartInfo=$psi
        [void]$p.Start()
        $script:CurrentProcess=$p
    } catch {
        $grid.Rows[$task.Index].Cells['Status'].Value='Falha (inicializacao)'
        Write-OutputLog $script:SessionLog "FALHA INICIANDO $($task.Name): $($_.Exception.Message)"
        $script:QueuePosition++
        Start-NextInstallation
    }
}
$timer.Add_Tick({
    if($null -eq $script:CurrentProcess){return}
    if(-not $script:CurrentProcess.HasExited){return}
    $exit=$script:CurrentProcess.ExitCode
    $task=$script:CurrentTask
    $success=($exit -eq 0)
    $state=$(if($success){'SUCESSO'}else{'FALHA'})
    $grid.Rows[$task.Index].Cells['Status'].Value=$(if(-not $success){"Falha (codigo $exit)"}elseif($task.ConfigResult -eq 'gerado'){'Sucesso (.config gerado)'}elseif($task.ConfigResult){'Sucesso'}else{'Sucesso (sem .config)'})
    $grid.Rows[$task.Index].Cells['Status'].Style.ForeColor=$(if($success){[Drawing.Color]::FromArgb(103,225,158)}else{[Drawing.Color]::FromArgb(255,121,138)})
    $detail=''
    if(Test-Path -LiteralPath $script:CurrentLog){try{$detail=[IO.File]::ReadAllText($script:CurrentLog)}catch{}}
    $entry=(@(
        ('='*80),"Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        "Servico: $($task.Name)", "Executavel: $($task.Exe)",
        ('Comando: "{0}" /sys={1} "{2}"' -f $script:InstallUtil,$task.Name,$task.Exe),
        "Resultado: $state | Codigo: $exit | Log detalhado: $script:CurrentLog",$detail
    ) -join [Environment]::NewLine)
    try {Write-OutputLog $script:SessionLog $entry}catch{}
    $script:CurrentProcess.Dispose();$script:CurrentProcess=$null
    $script:QueuePosition++
    Start-NextInstallation
})

# Configuracao sem instalacao: usa exclusivamente os quatro campos editaveis.
function Get-SelectedConfigTasks {
    [void]$grid.EndEdit()
    $tasks=New-Object 'System.Collections.Generic.List[object]'
    $errors=New-Object 'System.Collections.Generic.List[string]'
    foreach($row in $grid.Rows){
        if($row.Cells['Install'].Value -ne $true){continue}
        $exe=[string]$row.Tag.Exe
        $hostValue=([string]$row.Cells['SuperServerHost'].Value).Trim()
        $systemValue=([string]$row.Cells['SystemName'].Value).Trim()
        $userValue=([string]$row.Cells['WorkflowUser'].Value).Trim()
        $notifyValue=([string]$row.Cells['NotifySenderUser'].Value).Trim()
        if([string]::IsNullOrWhiteSpace($hostValue) -or $hostValue -notmatch '^[a-zA-Z0-9_.-]+(:[0-9]{1,5})?$'){$errors.Add("Benner Server invalido: $exe");continue}
        if([string]::IsNullOrWhiteSpace($systemValue) -or [string]::IsNullOrWhiteSpace($userValue) -or [string]::IsNullOrWhiteSpace($notifyValue)){$errors.Add("SYSTEMNAME/Usuario/Notificacao obrigatorios: $exe");continue}
        $tasks.Add([pscustomobject]@{Index=$row.Index;Exe=$exe;Host=$hostValue;System=$systemValue;User=$userValue;NotifyUser=$notifyValue})
    }
    if($errors.Count -gt 0){throw ($errors -join [Environment]::NewLine)}
    return $tasks.ToArray()
}
$initialConfigButton.Add_Click({
    if($script:Installing -or $script:Unlocking -or $script:EditingConfig){return}
    [void]$grid.EndEdit()
    $selected=@($grid.Rows | Where-Object {$_.Cells['Install'].Value -eq $true})
    if($selected.Count -ne 1){
        [System.Windows.Forms.MessageBox]::Show('Para abrir o Configurar, marque apenas uma linha por vez.','Configuracao inicial','OK','Information') | Out-Null;return
    }
    $exe=[string]$selected[0].Tag.Exe
    $folder=[System.IO.Path]::GetDirectoryName($exe)
    $cfg=$exe+'.config'
    if(Test-Path -LiteralPath $cfg -PathType Leaf){
        if([System.Windows.Forms.MessageBox]::Show('Este servico ja possui .config. Deseja abrir o configurador mesmo assim?','Configuracao existente','YesNo','Warning') -ne 'Yes'){return}
    }
    $candidates=@((Join-Path $folder 'Configurar.exe'), (Join-Path (Split-Path $folder -Parent) 'Configurar.exe'), (Join-Path $PSScriptRoot 'Configurar.exe'))
    $configurator=@($candidates | Where-Object {Test-Path -LiteralPath $_ -PathType Leaf} | Select-Object -First 1)
    if($configurator.Count -eq 0){
        [System.Windows.Forms.MessageBox]::Show("Configurar.exe nao encontrado. Coloque o configurador e suas dependencias na pasta do Workflow:`r`n$folder`r`n`r`nOu coloque-o junto do instalador.",'Configurar nao localizado','OK','Warning') | Out-Null;return
    }
    try {
        Start-Process -FilePath $configurator[0] -WorkingDirectory (Split-Path $configurator[0] -Parent) -ErrorAction Stop | Out-Null
        [System.Windows.Forms.MessageBox]::Show("Configurador aberto:`r`n$($configurator[0])`r`n`r`nO Configurar so e necessario para ajustes extras (email, log centralizado etc.); os quatro campos da grade sao gravados por 'Editar .config selecionados' ou 'Instalar selecionados', inclusive gerando o .config a partir do .config.modelo. Arquivo:`r`n$cfg",'Configuracao inicial','OK','Information') | Out-Null
    } catch {[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Falha ao iniciar Configurar','OK','Error') | Out-Null}
})
$editConfigButton.Add_Click({
    if($script:Installing -or $script:Unlocking -or $script:EditingConfig -or $script:Removing -or $script:ChangingLogin){return}
    try{$tasks=@(Get-SelectedConfigTasks)}catch{[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Campos invalidos','OK','Warning')|Out-Null;return}
    if($tasks.Count -eq 0){return}
    $missing=@($tasks | Where-Object {(Get-ConfigState $_.Exe) -eq 'ausente'})
    if($missing.Count -gt 0){
        $paths=($missing | ForEach-Object {$_.Exe+'.config'}) -join "`r`n"
        [System.Windows.Forms.MessageBox]::Show("Nao existe .config nem .config.modelo para as seguintes linhas:`r`n$paths`r`n`r`nCopie a pasta completa do Workflow Service, que inclui o arquivo .config.modelo. Nenhum arquivo foi criado nem modificado.",'Configuracao inicial necessaria','OK','Warning') | Out-Null;return
    }
    $fromModel=@($tasks | Where-Object {(Get-ConfigState $_.Exe) -eq 'modelo'})
    $modelNote=$(if($fromModel.Count -gt 0){"`r`n`r`n$($fromModel.Count) linha(s) ainda sem .config: o arquivo sera gerado a partir do .config.modelo, como o Configurar faz no primeiro salvamento."}else{''})
    if([System.Windows.Forms.MessageBox]::Show("Editar o .config de $($tasks.Count) linha(s) selecionada(s), sem instalar servicos? Sera criado backup de cada arquivo existente.$modelNote",'Confirmar edicao .config','YesNo','Question') -ne 'Yes'){return}
    try {New-Item -ItemType Directory -Path $script:LogDirectory -Force -ErrorAction Stop|Out-Null}
    catch {[System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Falha de log','OK','Error')|Out-Null;return}
    $log=Join-Path $script:LogDirectory ('Workflow_EdicaoConfig_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    $script:EditingConfig=$true; $grid.ReadOnly=$true; Update-Selection
    $ok=0;$failed=0
    try {
        foreach($task in $tasks){
            try {
                $result=Set-WorkflowConfig $task.Exe $task.Host $task.System $task.User $task.NotifyUser $log
                $grid.Rows[$task.Index].Cells['Status'].Value=$(if($result -eq 'gerado'){'Config gerado do modelo'}else{'Config atualizado'});$ok++
            } catch {
                $grid.Rows[$task.Index].Cells['Status'].Value='Falha (config)';$failed++
                Write-OutputLog $log ("CONFIG FALHA | {0} | {1}" -f $task.Exe,$_.Exception.Message)
            }
        }
    } finally {$script:EditingConfig=$false;$grid.ReadOnly=$false;Update-Selection}
    $progressLabel.Text="Config: $ok sucesso(s), $failed falha(s)"
    [System.Windows.Forms.MessageBox]::Show("Atualizacao concluida. Sucessos: $ok / Falhas: $failed.`r`nNenhum servico foi instalado.`r`nLog: $log",'Edicao .config','OK','Information')|Out-Null
})

$installButton.Add_Click({
    if($script:EditingConfig){return}
    $grid.EndEdit() | Out-Null
    $tasks=New-Object 'System.Collections.Generic.List[object]'
    $names=New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $problems=New-Object 'System.Collections.Generic.List[string]'
    foreach($row in $grid.Rows){
        if($row.Cells['Install'].Value -ne $true){continue}
        $name=([string]$row.Cells['ServiceName'].Value).Trim()
        if(-not (Safe-Name $name)){$problems.Add("Nome invalido: '$name'. Use apenas letras, numeros, _ . - (max. 230 caracteres).");continue}
        if(-not $names.Add($name)){$problems.Add("Nome duplicado na selecao: $name");continue}
        if(-not (Test-Path -LiteralPath $row.Tag.Exe -PathType Leaf)){$problems.Add("Executavel ausente: $($row.Tag.Exe)");continue}
        $hostValue=([string]$row.Cells['SuperServerHost'].Value).Trim()
        $sysValue=([string]$row.Cells['SystemName'].Value).Trim()
        if([string]::IsNullOrWhiteSpace($hostValue) -or $hostValue -notmatch '^[a-zA-Z0-9_.-]+(:[0-9]{1,5})?$'){$problems.Add("Benner Server invalido ou vazio para '$name'.");continue}
        if([string]::IsNullOrWhiteSpace($sysValue)){$problems.Add("SYSTEMNAME vazio para '$name'.");continue}
        $userValue=([string]$row.Cells['WorkflowUser'].Value).Trim()
        $notifyValue=([string]$row.Cells['NotifySenderUser'].Value).Trim()
        if([string]::IsNullOrWhiteSpace($userValue)){$problems.Add("Usuario vazio para '$name'.");continue}
        if([string]::IsNullOrWhiteSpace($notifyValue)){$problems.Add("Usuario de notificacao vazio para '$name'.");continue}
        $tasks.Add([pscustomobject]@{Index=$row.Index;Name=$name;Exe=$row.Tag.Exe;Host=$hostValue;System=$sysValue;User=$userValue;NotifyUser=$notifyValue})
    }
    if($problems.Count -gt 0){[System.Windows.Forms.MessageBox]::Show(($problems -join "`r`n"),'Corrija antes de instalar','OK','Warning') | Out-Null;return}
    if($tasks.Count -eq 0){return}
    if(-not (Test-Path -LiteralPath $script:InstallUtil -PathType Leaf)){
        [System.Windows.Forms.MessageBox]::Show("InstallUtil nao encontrado: $script:InstallUtil",'Dependencia ausente','OK','Error') | Out-Null;return
    }
    $existing=New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    try {foreach($svc in [System.ServiceProcess.ServiceController]::GetServices()){[void]$existing.Add($svc.ServiceName)}} catch {}
    foreach($task in $tasks){if($existing.Contains($task.Name)){$problems.Add("Ja existe um servico no Windows com nome: $($task.Name)")}}
    if($problems.Count -gt 0){[System.Windows.Forms.MessageBox]::Show(($problems -join "`r`n"),'Servico existente','OK','Warning') | Out-Null;return}
    $noConfig=@($tasks | Where-Object { (Get-ConfigState $_.Exe) -eq 'ausente' })
    $fromModel=@($tasks | Where-Object { (Get-ConfigState $_.Exe) -eq 'modelo' })
    $noConfigNote=''
    if($fromModel.Count -gt 0){
        $noConfigNote+="`r`n`r`n$($fromModel.Count) linha(s) ainda sem .config: o arquivo sera gerado a partir do .config.modelo, como o Configurar faz no primeiro salvamento:`r`n"+(($fromModel | ForEach-Object { $_.Name }) -join "`r`n")
    }
    if($noConfig.Count -gt 0){
        $noConfigNote+="`r`n`r`nATENCAO: $($noConfig.Count) linha(s) nao tem .config nem .config.modelo e serao instaladas SEM editar a configuracao:`r`n"+(($noConfig | ForEach-Object { $_.Name }) -join "`r`n")
    }
    $confirm="Instalar $($tasks.Count) servico(s) Workflow no Windows?`r`n`r`nAntes de instalar, o .config existente de cada servico sera atualizado e recebera um backup. Instalacoes sequenciais nao sao revertidas automaticamente em caso de falha.$noConfigNote`r`n`r`nDeseja continuar?"
    if([System.Windows.Forms.MessageBox]::Show($confirm,'Confirmar instalacao','YesNo','Question') -ne 'Yes'){return}
    try {New-Item -ItemType Directory -Path $script:LogDirectory -Force -ErrorAction Stop | Out-Null} catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'Falha criando pasta de logs','OK','Error') | Out-Null;return
    }
    $log=Join-Path $script:LogDirectory ('Workflow_Instalacao_{0}.log' -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
    foreach($task in $tasks){$grid.Rows[$task.Index].Cells['Status'].Value='Na fila'}
    $progressBar.Value=0;Set-Busy $true
    $script:Queue=$tasks.ToArray()
    $script:QueuePosition=0
    $script:SessionLog=$log
    Start-NextInstallation
    if($script:Installing){$timer.Start()}
})
$form.Add_FormClosing({param($sender,$e)
    if($script:Installing -or $script:Unlocking -or $script:Removing -or $script:EditingConfig){$e.Cancel=$true;[System.Windows.Forms.MessageBox]::Show('Aguarde o fim do lote antes de fechar.','Instalacao em andamento','OK','Information') | Out-Null}
})
Resize-Layout
Refresh-Installed
if(Test-Path -LiteralPath $pathBox.Text -PathType Container){Scan-Directories}
[void]$form.ShowDialog()
$form.Dispose()
