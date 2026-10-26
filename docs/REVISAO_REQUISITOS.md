# Revisão rápida: requisitos x código

Revisão de leitura do `src/BennerWorkflowInstaller.ps1` importado do pacote `BennerWorkflowInstaller_config_inicial.zip` (a pasta interna do ZIP se chama `BennerWorkflowInstaller_reorganizado`, mas o conteúdo já inclui os botões **Abrir Configurar (inicial)** e **Editar .config selecionados**).

**Isto não substitui teste em Windows Server.** Nada foi executado em Windows.

## O que foi verificado fora do Windows

Em Linux, com PowerShell 7.4 (não é o 5.1 do servidor):

- O script inteiro é analisado pelo parser do PowerShell sem erros de sintaxe.
- O bloco C# nativo (`ChangeServiceConfig` e LSA/`SeServiceLogonRight`) compila com `Add-Type`.
- A função `Set-WorkflowConfig` foi executada isoladamente contra um `.exe.config` de exemplo: alterou só as quatro chaves, preservou `passEncrypted` e o comentário, criou um backup e gravou o log; com chave duplicada, recusou a alteração sem criar backup.

A interface Windows Forms, o InstallUtil, `Unblock-File`, o SCM e a remoção de pastas **não** foram exercitados.

## Cobertura dos requisitos

| Requisito | Situação no código |
|---|---|
| Raiz editável (padrão `E:\Benner\WFL`), descoberta `VAR1\VAR2` com o `.exe` do runtime | Coberto (`Scan-Directories`) |
| Nome `VAR1_VAR2`, checkbox para só `VAR2`, editável por linha | Coberto; a checkbox é "Incluir VARIAVEL1" (marcada por padrão) e edições manuais são preservadas |
| Instalação em lote via `InstallUtil.exe /sys=<nome> <exe>`, sequencial, status/log por linha | Coberto (fila com timer, um processo filho por instalação, log por item e log da sessão) |
| Checagem de duplicados | Coberto: duplicado na seleção e serviço já existente no Windows (pelo nome interno) |
| Desbloquear marcados, recursivo, botão branco com texto escuro | Coberto; não segue junctions/symlinks e só age em arquivos com `Zone.Identifier` |
| Editar `.config`: só as 4 chaves, preservar o resto, backup, validar XML | Coberto; exige cada chave exatamente uma vez e restaura o backup se o `Save` falhar |
| Botão "Editar .config selecionados" sem instalar | Coberto; se faltar algum `.config`, bloqueia o lote inteiro antes de tocar em arquivos |
| "Instalar selecionados" edita o XML antes | Coberto, mas **diverge levemente**: a linha sem `.config` é recusada (não instala), enquanto o requisito fala em editar "quando o arquivo existir" |
| Abrir Configurar (inicial), sem inventar CLI | Coberto; procura `Configurar.exe` na pasta do Workflow, na pasta pai ou ao lado do script e abre sem argumentos. Automação do primeiro salvamento continua pendente |
| Ordem do layout (configuração, grade, prévia/logs/botões, serviços instalados por último) | Coberto (`Resize-Layout` ancora a grade de serviços no fim) |
| Grade de serviços com "Workflow Service" no nome ou display name | Coberto (`Win32_Service`) |
| Remoção: parar, `sc delete`, confirmar no SCM, só então apagar pasta | Coberto; aguarda até ~15 s o serviço sumir, senão preserva a pasta |
| Proteções da remoção (raiz WFL, outro serviço, reparse points, confirmação) | Coberto; revalida tudo logo antes do `Remove-Item` |
| Alterar login via `ChangeServiceConfig`, `SeServiceLogonRight`, reler conta, teste opcional, limpar senha | Coberto; compara o SID da conta relida e limpa o campo senha no `finally` |
| Logs em `C:\ProgramData\Benner\WorkflowInstaller\Logs`, sem senhas | Coberto; nenhum log grava senha nem `passEncrypted` |

## Pontos de atenção encontrados

1. **Tamanho mínimo da janela (1100 x 1050).** Em telas 1366x768 ou 1920x1080 com escala acima de 100% (comum via RDP), a janela não cabe e o formulário não tem rolagem, então a grade de serviços instalados pode ficar fora da tela. É o risco mais provável no primeiro teste.
2. **Mesma checkbox para login e remoção.** Na grade de serviços, a coluna "Selecionar" serve tanto para "Alterar login" quanto para "Remover selecionados". Há confirmação explícita antes de remover, mas é fácil marcar para login e clicar no botão errado.
3. **Falha ao conceder `SeServiceLogonRight` derruba todas as linhas.** Se a chamada LSA falhar (por exemplo, por GPO), nenhuma conta é alterada, mesmo que a conta já tenha o direito.
4. **Benner Server só aceita letras, números, `_`, `.` e `-`.** Um host com porta (`host:porta`) ou IPv6 é recusado; confirmar se isso basta.
5. **Conta do login só no formato `DOMINIO\usuario` ou `.\usuario`.** UPN (`usuario@dominio`) é recusado. Contas gMSA (`DOMINIO\conta$`) passam pela validação, mas exigem senha vazia, que o formulário recusa.

## Alterações feitas ao importar

- Os exemplos de nome no formulário (`OCI140-GLOBO_JURIDICO_PRJ` / `JURIDICO_PRJ`) foram trocados por `AMBIENTE_SISTEMA_PRJ` / `SISTEMA_PRJ`, porque o repositório é público.
- O logo passou a ser procurado também em `..\assets\benner-logo.png`, para funcionar com a estrutura do repositório. O comportamento do pacote original (logo ao lado do script) não mudou.
- O `LEIA-ME.txt` do pacote foi movido para `docs/LEIA-ME.txt` sem alterações.
