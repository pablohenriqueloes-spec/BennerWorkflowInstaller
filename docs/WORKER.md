# Módulo Worker do HUB Benner

Instala em lote o Benner Worker nas pastas escolhidas, para as duas versões de pacote:

| Versão | Executável do serviço (em `Lib\`) | Configuração | Como o serviço é criado |
|---|---|---|---|
| 23 (Tasks Worker, .NET Framework) | `Benner.Tecnologia.Tasks.Worker.exe` | `<exe>.config` gerado do `.config.modelo` | `<exe> install -Chave:valor ...` (Topshelf), igual ao `Instalar.exe` |
| 25 (Core Worker, .NET 8) | `Benner.Core.Worker.exe` | `backgroundtasksconfig.json` gerado do modelo em `Lib\` | `New-Service` (`BennerCoreWorker_<GUID>`, automático), igual ao `Benner.Core.Worker.Installer.exe` |

O HUB não chama `Instalar.exe` (só tem tela) nem o `Benner.Core.Worker.Installer.exe` (sempre cria uma subpasta extra e devolve código 0 mesmo com erro). Ele faz os mesmos passos na **pasta exata** escolhida na grade:

1. copia o conteúdo de `Lib\` do pacote para a pasta (robocopy, sem `Instalar.*`) e tira o bloqueio de internet (`Zone.Identifier`);
2. gera a configuração a partir do modelo (se já existir, faz backup `.backup_<data>` antes);
3. cria o serviço (23: Topshelf, depois aplica o DisplayName da linha com `Set-Service`; 25: `New-Service`);
4. inicia o serviço, se "Iniciar o serviço após instalar" estiver marcado.

Logs: `C:\ProgramData\Benner\WorkerInstaller\Logs`. Senhas nunca vão para o log nem para linha de comando.

## Tela

- **Pacote e destino:** pasta dos pacotes (padrão `E:\Benner\Worker`, pode conter `worker23` e `worker25`) e raiz de instalação (padrão `E:\Benner\Ferramentas\Worker`). **Detectar** lista os pacotes encontrados; escolha um. Os valores padrão (servidor, fila, providers, usuário, Pool dinâmica e COMFree) preenchem as linhas novas e podem ser aplicados às marcadas.
- **Instalação:** grade de pastas e subpastas da raiz, como no Workflow (flechinha para abrir, "marcar todos", pesquisa, adicionar pasta). Campos por linha:

| Coluna | Worker 23 | Worker 25 |
|---|---|---|
| Servidor | `Servidor` | `SystemSettings.SuperServerHost` e `Host` das filas |
| Sistema | `Sistema` (padrão: nome da pasta) | `SuperServerSystemName` e `SystemName` das filas |
| DisplayName | nome de exibição do serviço | nome de exibição do serviço |
| Fila | `Fila` (padrão `Z_BTLREQUISICOES`) | `ConsumerSettings.Name` (padrão `FILA_PADRAO_AMBOS`) |
| Providers | `NumeroDeProviders` (0 = automático) | providers Core (`CoreSettings` pool) |
| Win32 | (oculta) | providers Win32 (`LegacySettings` pool) |
| Usuário | `Usuario` (padrão `SYSDBA`) | `UserContext.UserHandle` (número, opcional) |
| Pool dinâmica | `PoolDinamica` | (oculta) |
| COMFree | `UseCOMFree` | (oculta) |

  Os demais valores ficam no padrão do modelo. Antes de instalar, o HUB confere: pasta dentro da raiz, pasta ainda sem serviço, campos válidos, DisplayName único (na seleção e nos serviços existentes), nenhuma pasta marcada dentro de outra marcada e pré-requisitos (25 precisa do runtime .NET 8).
- **Instalados:** serviços Worker da máquina (23 e 25), remoção (com opção de apagar a pasta, só dentro da raiz) e troca da conta de logon.

## Chamar as etapas fora da tela

```powershell
Import-Module .\Modules\Worker\Worker.Core.psm1
$pkg = Get-WorkerPackage -Path 'E:\Benner\Worker\worker25'
$log = New-HubLogFile -Directory (Get-WorkerSettings).LogDirectory -Prefix 'Worker_Script'
$p = Get-WorkerDefaultParameters -Version $pkg.Version
$p.Servidor = 'servidor'; $p.Sistema = 'SISTEMA'; $p.Nome = 'SISTEMA_PRD'; $p.DisplayName = 'Benner Core Worker [SISTEMA_PRD]'
Test-WorkerParameters -Parameters $p          # vazio = ok
Install-WorkerInstance -Package $pkg -Folder 'E:\Benner\Ferramentas\Worker\SISTEMA_PRD' -Parameters $p -LogFile $log
Get-WorkerInstalledService
```

## Roteiro de teste em Windows

Faça num servidor de homologação, com uma raiz de teste (ex.: `E:\Teste\Worker`).

1. **Abertura:** o menu mostra Workflow e Worker. Abra o Worker.
2. **Pacotes:** aponte para a pasta com `worker23` e `worker25`, clique em Detectar e confira as duas opções. Troque entre elas: as colunas Win32, Pool dinâmica, COMFree e o rótulo de Usuário/UserHandle devem mudar.
3. **Grade:** clique em Listar pastas, abra uma subpasta, adicione `TESTE23` e `TESTE25`. Confira Sistema = nome da pasta, Usuário = SYSDBA (23) e o DisplayName sugerido. Edite os campos por linha.
4. **Validação:** deixe Servidor vazio numa linha, repita um DisplayName de um serviço existente, marque uma pasta e uma subpasta dela: cada caso deve bloquear com mensagem.
5. **Instalar 23:** confira a prévia, instale, veja as etapas (cópia, config, registro, início), o `.config` gerado na pasta, o serviço `BennerTasksWorker_*` com o DisplayName da linha e o log.
6. **Instalar 25:** idem, conferindo `backgroundtasksconfig.json` (servidor, sistema, fila, pools Core/Win32) e o serviço `BennerCoreWorker_*`. Sem .NET 8, deve aparecer o aviso de pré-requisito.
7. **Instalados:** os dois aparecem; troque a conta de logon de um (senha errada e depois certa); remova um com "Apagar também a pasta" e confira que a pasta só some depois do serviço sair do SCM.

Se algo falhar, mande o print, o `C:\ProgramData\Benner\Hub\BennerHub_erro.log` (se existir) e o log da operação em `C:\ProgramData\Benner\WorkerInstaller\Logs`.
