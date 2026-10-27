# HUB Benner (WPF)

Nova interface do instalador, em **WPF com XAML sobre Windows PowerShell 5.1**. Não precisa instalar nada no servidor: WPF faz parte do .NET Framework 4.x. A versão antiga em Windows Forms continua em `src/BennerWorkflowInstaller.ps1`, sem alterações, como alternativa.

O HUB é uma janela com menu lateral de **módulos de configuração**. O primeiro módulo é o **Workflow**, com todas as funções do instalador anterior (incluindo pesquisa, "marcar todos" nos cabeçalhos e o alerta com mais de 2 selecionados).

> **Situação:** nada foi executado em Windows ainda. O XAML foi validado como XML e o PowerShell foi revisado à mão (não havia PowerShell disponível no ambiente de desenvolvimento). Use o roteiro de teste no fim deste arquivo.

## Como abrir

1. Copie a pasta `src/hub` (no pacote ZIP, a pasta `BennerHub`) para o servidor.
2. Clique com o botão direito no ZIP > Propriedades > Desbloquear, antes de extrair.
3. Execute `Iniciar-BennerHub.cmd` e aceite o UAC. Ele abre `BennerHub.ps1` elevado, em STA, com `-ExecutionPolicy Bypass` só para esse processo, e com a janela de console oculta.
4. Se algo impedir a abertura, aparece uma mensagem e o erro fica em `C:\ProgramData\Benner\Hub\BennerHub_erro.log`.

## Estrutura

```text
src/hub/
  Iniciar-BennerHub.cmd        abre o HUB elevado
  BennerHub.ps1                janela, menu e carregamento dos módulos
  Core/
    BennerHub.Core.psm1        funções compartilhadas (logs, serviços, login seguro, utilitários de tela)
    Theme.xaml                 tema escuro grafite/vermelho para todas as telas
    HubShell.xaml              janela principal (menu lateral + área do módulo)
  Modules/
    Workflow/
      module.psd1              manifesto: nome, descrição, ícone, ordem e funções de tela
      Workflow.Core.psm1       cada etapa do Workflow como função, sem nenhuma tela
      Workflow.View.xaml       tela do módulo
      Workflow.View.psm1       liga a tela às funções de Workflow.Core.psm1
```

A regra é: **regra de negócio só nos arquivos `*.Core.psm1`**. As telas apenas chamam essas funções. Assim, qualquer etapa pode ser chamada de outro lugar (outro módulo, um script agendado, outra tela) sem retrabalho.

## Chamar as etapas do Workflow fora da tela

Todas as funções abaixo funcionam num PowerShell 5.1 elevado, sem abrir o HUB:

```powershell
Import-Module 'C:\BennerHub\Modules\Workflow\Workflow.Core.psm1'
$cfg = Get-WorkflowSettings
$log = New-HubLogFile -Directory $cfg.LogDirectory -Prefix 'Workflow_Script'

# 0. Criar/atualizar pasta (copiar e substituir; .config recebe backup, ou -KeepConfigs para manter os atuais)
Get-WorkflowCopyPlan -Source 'E:\Benner\WorkflowService' -Destination 'E:\Benner\Ferramentas\WFL\CLIENTE'   # Replaced = .config que seriam substituidos
Copy-WorkflowFolder -Source 'E:\Benner\WorkflowService' -Destination 'E:\Benner\Ferramentas\WFL\CLIENTE' -LogFile $log

# 1. Descoberta
$pastas = Find-WorkflowFolder -Root 'E:\Benner\WFL' -IncludeFirst $true

# 2. .config (só os 4 campos; backup automático; gera do .config.modelo se faltar)
Set-WorkflowConfig -Exe $pastas[0].Exe -SuperServerHost 'servidor' -SystemName $pastas[0].Second `
    -User 'SYSDBA' -NotifySenderUser 'SYSDBA' -LogFile $log

# 3. Instalação síncrona (edita o .config antes quando os 4 valores são informados)
Install-WorkflowService -Name $pastas[0].SuggestedName -Exe $pastas[0].Exe -LogFile $log `
    -SuperServerHost 'servidor' -SystemName $pastas[0].Second -User 'SYSDBA' -NotifySenderUser 'SYSDBA'

# 4. Desbloqueio (remove só o Zone.Identifier)
Unblock-WorkflowFolder -Folder $pastas[0].Folder -LogFile $log

# 5. Serviços instalados e remoção segura
$instalados = Get-WorkflowInstalledService
Get-WorkflowRemovalIssues -Services $instalados[0] -Root 'E:\Benner\WFL'   # vazio = pode remover
Remove-WorkflowService -Name $instalados[0].Name -Folder $instalados[0].Folder -Exe $instalados[0].Exe -Root 'E:\Benner\WFL' -LogFile $log

# 6. Conta de logon (senha como SecureString, nunca em linha de comando)
$senha = Read-Host 'Senha' -AsSecureString
Grant-WorkflowLogonRight -Account 'DOMINIO\svc_wfl' -LogFile $log
Set-WorkflowServiceLogon -Name $instalados[0].Name -Account 'DOMINIO\svc_wfl' -Password $senha -LogFile $log
Test-WorkflowServiceStart -Name $instalados[0].Name -LogFile $log
```

Funções de apoio: `Get-WorkflowCopyTarget`, `New-WorkflowTargetFolder`, `Test-WorkflowFolderName`, `Test-WorkflowCopyPaths`, `Get-WorkflowSourceConfigFiles`, `Backup-WorkflowConfigFiles`, `Start-WorkflowFolderCopy` (robocopy assíncrono), `Get-WorkflowServicesInFolder`, `Get-WorkflowServiceName`, `Test-WorkflowServiceName`, `Get-WorkflowConfigState`, `Test-WorkflowConfigValues`, `Get-WorkflowInstallCommand`, `Get-WorkflowExistingServiceNames`, `Start-WorkflowInstall` e `Start-WorkflowUnblock` (versões assíncronas que devolvem o processo), `Write-WorkflowInstallResult`, `Find-WorkflowConfigurator`, `Test-WorkflowRemovalFolder`, `Test-WorkflowLogonInput`, `Get-WorkflowLastError` (últimos erros do arquivo `errors`), `Get-WorkflowErrorFile`, `ConvertFrom-WorkflowErrorLog`.

O núcleo (`BennerHub.Core.psm1`) oferece o que não é específico do Workflow e pode servir a outros módulos: `New-HubLogFile`, `Write-HubLog`, `Start-HubPowerShellProcess`, `Get-HubServiceExePath`, `Get-HubServiceInfo`, `Set-HubServiceLogon`, `Grant-HubServiceLogonRight`, `Restart-HubService`, `Read-HubFileTail`, `Show-HubMessage`, `Invoke-HubSafe`, `New-HubTimer`, `Select-HubFolder`, `Test-HubRowMatch` e o tipo `BennerHub.HubRow` (linha observável para grades).

## Criar um módulo novo

1. Crie `Modules/<Nome>/` com um `module.psd1`:

   ```powershell
   @{
       Id           = 'Exemplo'           # identificador único
       Name         = 'Exemplo'           # nome no menu
       Description  = 'O que o módulo faz (aparece no cartão da tela Início).'
       Subtitle     = 'Linha abaixo do título quando o módulo está aberto'
       Order        = 20                  # posição no menu
       Glyph        = 'E713'              # ícone da fonte Segoe MDL2 Assets (hex)
       View         = 'Exemplo.View.psm1' # módulo PowerShell que monta a tela
       Factory      = 'New-ExemploView'   # função que devolve o UserControl
       BusyFunction = 'Test-ExemploBusy'  # opcional: $true impede fechar o HUB
   }
   ```

2. Coloque a lógica em `Exemplo.Core.psm1` (sem tela) e a tela em `Exemplo.View.xaml` + `Exemplo.View.psm1`.
3. A função `Factory` recebe `-Context` com `Window`, `HubRoot`, `ModuleRoot` e `Manifest`, e devolve o elemento raiz (normalmente um `UserControl` carregado com `Import-HubXaml`).
4. Use os estilos de `Core/Theme.xaml` (`Card`, `Chip`, `Btn.Primary`, `Btn.Light`, `Btn.Danger`, `Btn.Ghost`, `Btn.Info`, `Text.Eyebrow`, `Text.Section`, `Text.Muted` etc.) para manter o mesmo visual.

O HUB lista o módulo no menu na próxima abertura e só carrega o código quando ele é aberto pela primeira vez.

## Diferenças em relação à versão Windows Forms

- Layout que se adapta à largura da janela e à escala do RDP, sem coordenadas fixas.
- Cartão novo **Criar/Atualizar pasta**, acima da Descoberta: copia uma origem (padrão `E:\Benner\WorkflowService`) para várias subpastas do destino (padrão `E:\Benner\Ferramentas\WFL`) de uma vez, no modelo copiar e substituir (robocopy `/E /IS /IT /XJ`; nada é apagado do destino). O botão **Adicionar** cria as pastas no disco na hora (vários nomes separados por `;` ou `,`): dentro de cada pasta marcada na grade, ou na pasta de destino quando nada está marcado; as criadas dentro de subpastas ficam marcadas como destino e a subpasta mãe é desmarcada (log `Workflow_Pastas_*.log`). A flechinha ▼ de cada subpasta mostra as pastas de dentro dela (um nível), que também podem ser marcadas como destino; o botão **Marcar pastas das subpastas** abre cada subpasta marcada, marca todas as pastas de dentro e desmarca a subpasta, para a cópia ir só para as pastas internas. Antes de copiar, a confirmação lista por destino os `.config` que seriam substituídos e os novos, e avisa sobre serviços em execução nessas pastas. Se algum `.config` existente for afetado, a caixa pergunta: **Sim** substitui também os `.config` (cada um recebe backup `.backup_<data>` antes), **Não** copia o resto e mantém os `.config` atuais, **Cancelar** não copia. O log (`Workflow_Copia_*.log` e `*_robocopy.log`) registra só caminhos e contagens, nunca o conteúdo dos `.config`.
- Status por linha em etiquetas coloridas (pronto, na fila, instalando, sucesso, falha).
- Coluna nova **.config** na grade de instalação: mostra se o arquivo existe, se será gerado do modelo ou se está ausente.
- Coluna nova **Conta de logon** na grade de serviços instalados.
- Coluna nova **Erro** na grade de serviços instalados: resume o último registro com `Categoria: Error` (pela Data/Hora) do arquivo `errors` da pasta do serviço. O botão de cada linha abre uma janela com os até 10 últimos registros de erro, do mais recente ao mais antigo, que pode ser arrastada, minimizada, maximizada e fechada; clicar de novo na mesma linha restaura a janela já aberta. Só o fim do arquivo é lido (1 MB, ampliando até 32 MB enquanto faltarem registros).
- O "marcar todos" no cabeçalho mostra estado parcial quando só parte das linhas visíveis está marcada.
- A senha do login vem de um `PasswordBox` e vai ao Windows por memória protegida (`SecureString`), sem passar por string comum no PowerShell.
- Ao fim de uma instalação, a lista de serviços instalados é atualizada sozinha.
- As mensagens de confirmação continuam sendo as caixas padrão do Windows.

## Roteiro de teste em Windows

Faça num servidor de homologação, com uma cópia de pastas Workflow de teste.

1. **Abertura:** o HUB abre com o menu (Início e Workflow) e já mostra o módulo Workflow. Teste também em RDP com escala de 150%.
2. **Criar/Atualizar pasta:** com uma origem de teste, liste as subpastas do destino, marque duas (uma com `.config`, outra sem) e, sem nada marcado, adicione uma pasta (deve aparecer no disco, na raiz de destino). Marque duas subpastas e adicione `TESTE1; TESTE2` (as quatro pastas são criadas, aparecem marcadas abaixo das mães e as mães ficam desmarcadas). Abra uma subpasta pela flechinha, marque uma pasta interna, recolha e veja a contagem "em subpasta recolhida". Marque duas subpastas e use **Marcar pastas das subpastas** (as internas ficam marcadas e as mães desmarcadas). Confira a confirmação (lista de `.config` substituídos), responda **Não** e veja que o `.config` ficou igual; repita com **Sim** e confira o backup `.backup_<data>` e a coluna Resultado. Teste também com um serviço em execução na pasta (deve avisar e, se arquivos estiverem em uso, mostrar Falha com o código do robocopy).
3. **Descoberta:** informe a raiz, clique em Buscar pastas, confira VAR1/VAR2, o nome sugerido e a coluna .config. Desmarque "Incluir VARIAVEL1" e veja os nomes mudarem (os editados à mão não mudam).
4. **Pesquisa e seleção:** digite um trecho na pesquisa, use `%` como curinga, Esc para limpar. Use o "marcar todos" do cabeçalho com e sem filtro. Marque 3 linhas e confira o alerta.
5. **Editar .config selecionados:** numa pasta com `.config` (confira o backup) e noutra só com `.config.modelo` (confira que o `.config` foi gerado).
6. **Instalar selecionados:** 2 linhas; confira as etiquetas, o progresso, o log da sessão e que os serviços aparecem na grade de baixo.
7. **Desbloquear marcados:** numa pasta copiada da internet; confira a coluna Desbloqueio e o log.
8. **Alterar login:** conta de teste com senha errada (o teste de partida deve falhar) e depois com a certa. Confira que o campo senha fica vazio e que o log não tem a senha.
9. **Coluna Erro:** confira o último erro de um serviço com arquivo `errors`; abra a janela, minimize, clique de novo na mesma linha (deve restaurar a mesma janela) e maximize.
10. **Remover:** um serviço de teste; confira que a pasta só some depois do serviço sair do SCM. Tente remover um serviço fora da raiz WFL (deve bloquear).
11. **Fechar durante um lote:** deve pedir para aguardar.

Se algo falhar, mande o print e o conteúdo de `C:\ProgramData\Benner\Hub\BennerHub_erro.log` (se existir) e do log da operação em `C:\ProgramData\Benner\WorkflowInstaller\Logs`.
