#requires -Version 5.1
<#
Nucleo do HUB Benner: funcoes compartilhadas por todos os modulos.
Nada aqui conhece um modulo especifico (Workflow etc.). Tudo o que e
"Windows Service generico" (logon, processos filhos, logs) fica aqui para
ser reaproveitado por modulos futuros.
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml

# ---------------------------------------------------------------------------
# Tipos .NET compartilhados
#  - BennerHub.HubRow: linha observavel para grades WPF (Binding="{Binding [Chave]}").
#  - BennerHub.ServiceLogon: ChangeServiceConfig + SeServiceLogonRight. A senha chega
#    como ponteiro para memoria nao gerenciada (SecureString), nunca por linha de comando.
# ---------------------------------------------------------------------------
if (-not ('BennerHub.HubRow' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace BennerHub {
    public class HubValueChangedEventArgs : EventArgs {
        public string Key { get; private set; }
        public HubValueChangedEventArgs(string key) { Key = key; }
    }

    public class HubRow : INotifyPropertyChanged {
        readonly Dictionary<string, object> values = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
        public event PropertyChangedEventHandler PropertyChanged;
        public event EventHandler<HubValueChangedEventArgs> ValueChanged;
        public object this[string key] {
            get { object v; return values.TryGetValue(key, out v) ? v : null; }
            set {
                object old; values.TryGetValue(key, out old);
                if (Equals(old, value)) return;
                values[key] = value;
                PropertyChangedEventHandler h = PropertyChanged;
                if (h != null) h(this, new PropertyChangedEventArgs("Item[]"));
                EventHandler<HubValueChangedEventArgs> c = ValueChanged;
                if (c != null) c(this, new HubValueChangedEventArgs(key));
            }
        }
        public bool IsChecked(string key) { object v = this[key]; return v is bool && (bool)v; }
        public IEnumerable<string> Keys { get { return values.Keys; } }
    }

    public static class ServiceLogon {
        const uint SC_MANAGER_CONNECT = 0x0001;
        const uint SERVICE_CHANGE_CONFIG = 0x0002;
        const uint SERVICE_NO_CHANGE = 0xFFFFFFFF;
        const uint POLICY_LOOKUP_NAMES = 0x00000800;
        const uint POLICY_CREATE_ACCOUNT = 0x00000010;
        [StructLayout(LayoutKind.Sequential)]
        struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
        [StructLayout(LayoutKind.Sequential)]
        struct LSA_OBJECT_ATTRIBUTES {
            public uint Length; public IntPtr RootDirectory; public IntPtr ObjectName;
            public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
        }
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr OpenSCManager(string machine, string database, uint access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern IntPtr OpenService(IntPtr manager, string name, uint access);
        [DllImport("advapi32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        static extern bool ChangeServiceConfig(IntPtr service, uint serviceType, uint startType, uint errorControl,
            string binaryPath, string loadOrderGroup, IntPtr tagId, string dependencies,
            string account, IntPtr password, string displayName);
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
        static void CheckLsa(uint status) { if (status != 0) throw new Win32Exception((int)LsaNtStatusToWinError(status)); }

        public static void AllowServiceLogon(string account) {
            SecurityIdentifier sid = (SecurityIdentifier)(new NTAccount(account).Translate(typeof(SecurityIdentifier)));
            byte[] sidBytes = new byte[sid.BinaryLength]; sid.GetBinaryForm(sidBytes, 0);
            LSA_OBJECT_ATTRIBUTES attrs = new LSA_OBJECT_ATTRIBUTES();
            attrs.Length = (uint)Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
            IntPtr policy = IntPtr.Zero;
            CheckLsa(LsaOpenPolicy(IntPtr.Zero, ref attrs, POLICY_LOOKUP_NAMES | POLICY_CREATE_ACCOUNT, out policy));
            IntPtr ptr = IntPtr.Zero;
            try {
                string right = "SeServiceLogonRight";
                ptr = Marshal.StringToHGlobalUni(right);
                LSA_UNICODE_STRING item = new LSA_UNICODE_STRING();
                item.Buffer = ptr; item.Length = (ushort)(right.Length * 2);
                item.MaximumLength = (ushort)((right.Length + 1) * 2);
                CheckLsa(LsaAddAccountRights(policy, sidBytes, new LSA_UNICODE_STRING[] { item }, 1));
            } finally { if (ptr != IntPtr.Zero) Marshal.FreeHGlobal(ptr); if (policy != IntPtr.Zero) LsaClose(policy); }
        }

        // password = IntPtr.Zero grava senha nula (exigido para gMSA).
        public static void SetLogon(string serviceName, string account, IntPtr password) {
            IntPtr manager = OpenSCManager(null, null, SC_MANAGER_CONNECT);
            if (manager == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
            try {
                IntPtr service = OpenService(manager, serviceName, SERVICE_CHANGE_CONFIG);
                if (service == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
                try {
                    bool ok = ChangeServiceConfig(service, SERVICE_NO_CHANGE, SERVICE_NO_CHANGE,
                        SERVICE_NO_CHANGE, null, null, IntPtr.Zero, null, account, password, null);
                    if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
                } finally { CloseServiceHandle(service); }
            } finally { CloseServiceHandle(manager); }
        }
    }
}
'@ -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Logs
# ---------------------------------------------------------------------------
function New-HubLogFile {
    <# Cria (se preciso) a pasta e devolve o caminho de um log novo: <Pasta>\<Prefixo>_<data>.log #>
    param([Parameter(Mandatory)][string]$Directory, [Parameter(Mandatory)][string]$Prefix)
    New-Item -ItemType Directory -Path $Directory -Force -ErrorAction Stop | Out-Null
    return (Join-Path $Directory ('{0}_{1}.log' -f $Prefix, (Get-Date -Format 'yyyyMMdd_HHmmss_fff')))
}

function Write-HubLog {
    <# Acrescenta uma linha (UTF-8) ao log. Nunca passe senhas ou conteudo de .config aqui. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Message, [switch]$NoTimestamp)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $line = $(if ($NoTimestamp) { $Message } else { '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message })
    [System.IO.File]::AppendAllText($Path, $line + [Environment]::NewLine, [System.Text.Encoding]::UTF8)
}

# ---------------------------------------------------------------------------
# Ambiente
# ---------------------------------------------------------------------------
function Test-HubIsAdministrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function ConvertTo-HubSingleQuoted([string]$Value) {
    return "'" + $Value.Replace("'", "''") + "'"
}

function Start-HubPowerShellProcess {
    <#
    Executa um bloco de codigo PowerShell em processo filho oculto, com os argumentos
    embutidos como literais (via -EncodedCommand), e devolve o Process para acompanhamento.
    Usado para tarefas demoradas (InstallUtil, Unblock-File) sem travar a janela.
    #>
    param(
        [Parameter(Mandatory)][string]$Code,
        [string[]]$Arguments = @(),
        [string]$WorkingDirectory = $env:SystemRoot
    )
    $quoted = @($Arguments | ForEach-Object { ConvertTo-HubSingleQuoted ([string]$_) })
    $launch = '& { ' + $Code + ' } ' + ($quoted -join ' ')
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $PSHOME 'powershell.exe')
    $psi.Arguments = "-NoProfile -NonInteractive -EncodedCommand $encoded"
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    return $p
}

# ---------------------------------------------------------------------------
# Windows Services (genericos)
# ---------------------------------------------------------------------------
function Get-HubServiceExePath {
    <# Extrai o caminho do .exe de um PathName do SCM (com ou sem aspas). #>
    param([string]$BinaryPath)
    if ([string]::IsNullOrWhiteSpace($BinaryPath)) { return $null }
    $m = [regex]::Match($BinaryPath, '^\s*"([^"]+?\.exe)"', 'IgnoreCase')
    if (-not $m.Success) { $m = [regex]::Match($BinaryPath, '^\s*(.+?\.exe)(?=\s|$)', 'IgnoreCase') }
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value.Trim()
}

function Get-HubServiceInfo {
    param([Parameter(Mandatory)][string]$Name)
    $q = "Name='{0}'" -f $Name.Replace("'", "''")
    return Get-CimInstance Win32_Service -Filter $q -ErrorAction Stop
}

function ConvertTo-HubServiceAccount {
    <# .\usuario vira COMPUTADOR\usuario. #>
    param([string]$Account)
    $Account = ([string]$Account).Trim()
    if ($Account.StartsWith('.\')) { return ($env:COMPUTERNAME + '\' + $Account.Substring(2)) }
    return $Account
}

function Test-HubServiceAccountFormat {
    param([string]$Account)
    return (-not [string]::IsNullOrWhiteSpace($Account)) -and ($Account -match '^[^\\\s]+\\[^\\\s]+$')
}

function Grant-HubServiceLogonRight {
    <# Concede SeServiceLogonRight neste computador. Lanca excecao se a politica impedir. #>
    param([Parameter(Mandatory)][string]$Account)
    [BennerHub.ServiceLogon]::AllowServiceLogon($Account)
}

function Set-HubServiceLogon {
    <#
    Troca a conta de logon via ChangeServiceConfig, relendo e comparando o SID depois.
    -Password e SecureString; contas gMSA (terminadas em $) devem vir sem senha.
    A senha so existe em texto claro em memoria nao gerenciada, zerada logo apos o uso.
    #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Account,
        [System.Security.SecureString]$Password
    )
    $ptr = [IntPtr]::Zero
    try {
        if ($null -ne $Password -and $Password.Length -gt 0) {
            $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Password)
        }
        [BennerHub.ServiceLogon]::SetLogon($Name, $Account, $ptr)
    } finally {
        if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
    }
    $after = Get-HubServiceInfo -Name $Name
    $expected = (New-Object Security.Principal.NTAccount($Account)).Translate([Security.Principal.SecurityIdentifier]).Value
    $actual = (New-Object Security.Principal.NTAccount($after.StartName)).Translate([Security.Principal.SecurityIdentifier]).Value
    if ($expected -ne $actual) { throw "Conta do servico nao confere. Atual: $($after.StartName)" }
    return $after
}

function Restart-HubService {
    <# Para (se preciso) e inicia o servico, esperando cada estado. Usado como teste de credencial. #>
    param([Parameter(Mandatory)][string]$Name, [int]$TimeoutSeconds = 60)
    $svc = Get-Service -Name $Name -ErrorAction Stop
    if ($svc.Status -ne 'Stopped') {
        Stop-Service -Name $Name -ErrorAction Stop
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($TimeoutSeconds))
    }
    Start-Service -Name $Name -ErrorAction Stop
    $svc = Get-Service -Name $Name -ErrorAction Stop
    $svc.WaitForStatus('Running', [TimeSpan]::FromSeconds($TimeoutSeconds))
}

# ---------------------------------------------------------------------------
# Interface (WPF)
# ---------------------------------------------------------------------------
$script:HubWindow = $null

function Set-HubOwnerWindow { param($Window) $script:HubWindow = $Window }

function Import-HubXaml {
    <# Carrega um arquivo XAML (UTF-8) e devolve o objeto raiz. Estilos vem de Theme.xaml via Application. #>
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return [System.Windows.Markup.XamlReader]::Parse($text)
}

function Get-HubNamedElements {
    <# Devolve um hashtable Nome -> elemento para todos os x:Name do XAML informado. #>
    param([Parameter(Mandatory)]$Root, [Parameter(Mandatory)][string]$XamlPath)
    $map = @{}
    $text = [System.IO.File]::ReadAllText($XamlPath, [System.Text.Encoding]::UTF8)
    foreach ($m in [regex]::Matches($text, 'x:Name="([^"]+)"')) {
        $name = $m.Groups[1].Value
        $el = $Root.FindName($name)
        if ($null -ne $el) { $map[$name] = $el }
    }
    return $map
}

function Show-HubMessage {
    <# MessageBox com dono na janela do HUB. Kind: Info, Warning, Error, Question. Devolve 'Yes'/'No'/'OK'. #>
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Title = 'Benner HUB',
        [ValidateSet('Info', 'Warning', 'Error', 'Question')][string]$Kind = 'Info',
        [switch]$YesNo,
        [switch]$DefaultNo
    )
    $buttons = $(if ($YesNo) { [System.Windows.MessageBoxButton]::YesNo } else { [System.Windows.MessageBoxButton]::OK })
    $image = switch ($Kind) {
        'Warning' { [System.Windows.MessageBoxImage]::Warning }
        'Error' { [System.Windows.MessageBoxImage]::Error }
        'Question' { [System.Windows.MessageBoxImage]::Question }
        default { [System.Windows.MessageBoxImage]::Information }
    }
    $default = $(if ($YesNo -and $DefaultNo) { [System.Windows.MessageBoxResult]::No } elseif ($YesNo) { [System.Windows.MessageBoxResult]::Yes } else { [System.Windows.MessageBoxResult]::OK })
    if ($null -ne $script:HubWindow -and $script:HubWindow.IsVisible) {
        return [string][System.Windows.MessageBox]::Show($script:HubWindow, $Text, $Title, $buttons, $image, $default)
    }
    return [string][System.Windows.MessageBox]::Show($Text, $Title, $buttons, $image, $default)
}

function Invoke-HubSafe {
    <# Executa a acao de um botao; qualquer erro vira mensagem em vez de derrubar a janela. #>
    param([Parameter(Mandatory)][scriptblock]$Action, [string]$Title = 'Erro inesperado')
    try { & $Action }
    catch {
        $where = $_.InvocationInfo.PositionMessage
        Write-HubErrorLog -ErrorRecord $_
        Show-HubMessage -Text ("{0}`r`n`r`n{1}`r`n`r`nDetalhes em {2}" -f $_.Exception.Message, $where, (Get-HubErrorLogPath)) -Title $Title -Kind Error | Out-Null
    }
}

function Get-HubErrorLogPath { return (Join-Path $env:ProgramData 'Benner\Hub\BennerHub_erro.log') }

function Write-HubErrorLog {
    <# Registra erro com local e pilha de chamadas para diagnostico. #>
    param([Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord)
    try {
        $path = Get-HubErrorLogPath
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        $text = "{0} {1}`r`n{2}`r`n{3}`r`n" -f (Get-Date -Format o), $ErrorRecord.Exception.Message, $ErrorRecord.InvocationInfo.PositionMessage, $ErrorRecord.ScriptStackTrace
        [System.IO.File]::AppendAllText($path, $text, [System.Text.Encoding]::UTF8)
    } catch {}
}

function Invoke-HubDoEvents {
    <# Processa a fila da interface (equivalente ao DoEvents) durante lacos sincronos curtos. #>
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $callback = [System.Windows.Threading.DispatcherOperationCallback] { param($f) $f.Continue = $false; return $null }
    [void][System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, $callback, $frame)
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function New-HubTimer {
    <# DispatcherTimer na thread da interface. #>
    param([int]$IntervalMs = 350, [Parameter(Mandatory)][scriptblock]$OnTick)
    $t = New-Object System.Windows.Threading.DispatcherTimer
    $t.Interval = [TimeSpan]::FromMilliseconds($IntervalMs)
    $t.Add_Tick($OnTick)
    return $t
}

function Select-HubFolder {
    <# Dialogo de pasta (WinForms, o WPF do .NET Framework nao tem um). Devolve o caminho ou $null. #>
    param([string]$Description = 'Selecione a pasta', [string]$InitialPath)
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    try {
        $dialog.Description = $Description
        if ($InitialPath -and (Test-Path -LiteralPath $InitialPath -PathType Container)) { $dialog.SelectedPath = $InitialPath }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.SelectedPath }
        return $null
    } finally { $dialog.Dispose() }
}

# Pesquisa "like": trecho contido em qualquer chave informada, sem diferenciar maiusculas.
# % ou * no termo funcionam como curinga (ex.: OCI%PRJ).
function Test-HubRowMatch {
    param([Parameter(Mandatory)]$Row, [string]$Term, [string[]]$Keys)
    $Term = ([string]$Term).Trim()
    if ($Term.Length -eq 0) { return $true }
    $pattern = $null
    if ($Term -match '[%*]') {
        $pattern = '*' + ((($Term -split '[%*]') | ForEach-Object { [System.Management.Automation.WildcardPattern]::Escape($_) }) -join '*') + '*'
    }
    foreach ($k in $Keys) {
        $v = [string]$Row[$k]
        if ($null -ne $pattern) { if ($v -like $pattern) { return $true } }
        elseif ($v.IndexOf($Term, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $true }
    }
    return $false
}

Export-ModuleMember -Function *-Hub*
