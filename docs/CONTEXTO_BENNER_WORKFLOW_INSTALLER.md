# Contexto do Projeto — Benner Workflow Installer

**Data da exportação:** 26/10/2026  
**Projeto:** Instalador e gerenciador de serviços Benner Workflow  
**Tecnologia:** Windows PowerShell 5.1 + Windows Forms (`System.Windows.Forms`, `System.Drawing`)  
**Plataforma:** Windows Server, execução elevada/administrativa  
**Situação:** Pacotes ZIP foram disponibilizados em etapas anteriores; as funcionalidades foram descritas como implementadas, mas sua execução real em Windows não foi validada nesta conversa. A versão mais recente disponibilizada antes desta exportação foi `BennerWorkflowInstaller_config_inicial.zip`.

> **Nota de publicação:** nomes de servidores, ambientes e sistemas internos foram substituídos por exemplos genéricos (`SERVIDOR-APL01`, `AMBIENTE`, `SISTEMA_PRJ`, `SISTEMA_HML`). Nenhuma senha ou segredo de `.config` faz parte deste documento.

## 1. Objetivo

Construir um aplicativo com interface gráfica (Dark Mode) para localizar, configurar, instalar e gerenciar em lote serviços **Benner Workflow** instalados como serviços do Windows, reduzindo operações manuais e registrando resultados por serviço.

## 2. Descoberta dos diretórios e instalação

- Diretório raiz padrão: `E:\Benner\WFL` (editável).
- Descoberta automática da estrutura `E:\Benner\WFL\VARIAVEL1\VARIAVEL2\`.
- Incluir somente diretórios com `Benner.Tecnologia.Workflow.Runtime.Application.exe`.
- Nome sugerido do serviço: `VARIAVEL1_VARIAVEL2`, com checkbox para omitir `VARIAVEL1` e manter apenas `VARIAVEL2`.
- Nome final do serviço editável, individualmente, na grade de instalação; seleção múltipla por checkbox e marcar/desmarcar todos.
- Executável de instalação: `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\InstallUtil.exe`.
- Comando de exemplo:

```powershell
& 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\InstallUtil.exe' /sys=AMBIENTE_SISTEMA_PRJ 'E:\Benner\WFL\AMBIENTE\SISTEMA_PRJ\Benner.Tecnologia.Workflow.Runtime.Application.exe'
```

- Substituir o valor de `/sys=` pelo nome editável de cada linha.
- Instalação sequencial em lote (um clique para vários serviços), progresso e status por linha, logs e verificação de nomes duplicados/serviços existentes.

## 3. Interface e organização

- Interface **PowerShell + Windows Forms**, visual escuro (grafite) com detalhes vermelhos da identidade Benner.
- Logotipo Benner: foi citada uma aproximação estilizada. Substituição opcional por imagem institucional `benner-logo.png`; não há confirmação de uso de arquivo de marca oficial.
- Botão **Desbloquear marcados** solicitado com fundo **branco** e texto escuro.
- Layout organizado em blocos completos, na seguinte ordem:
  1. Configuração e descoberta do diretório base.
  2. Grade de instalação e campos editáveis.
  3. Prévia, logs e botões de desbloqueio, configuração e instalação.
  4. **Por último:** grade de serviços Windows já instalados, com controles de login e remoção.
- A grade de remoção/login não deve ficar entre a grade de instalação e seus respectivos botões.

## 4. Desbloqueio de arquivos

- Checkbox independente por linha para selecionar serviços cujos arquivos devem ser desbloqueados.
- Botão **Desbloquear marcados** executa operação recursiva nos arquivos do diretório de cada Workflow usando `Unblock-File` (remove zona `Zone.Identifier` quando aplicável).
- Relatar resultado individual e logar erros.
- **Limite importante:** `Unblock-File` não libera arquivos travados por processos, nem modifica permissões NTFS.

## 5. Configuração XML dos Workflows

Arquivo-alvo, localizado ao lado do executável do serviço:

`Benner.Tecnologia.Workflow.Runtime.Application.exe.config`

Os quatro valores configuráveis foram definidos pelo usuário:

```xml
<add key="superServerHost" value="SERVIDOR-APL01"/>
<add key="systemName" value="SISTEMA_HML"/>
<add key="user" value="SYSDBA"/>
<add key="notifySenderUser" value="SYSDBA"/>
```

| Chave XML | Coluna na interface | Valor inicial/regra |
|---|---|---|
| `superServerHost` | **Benner Server** | Informado/editado por linha |
| `systemName` | **SYSTEMNAME** | Nome da pasta `VARIAVEL2`, mas editável |
| `user` | **Usuário** | `SYSDBA` por padrão, editável por linha |
| `notifySenderUser` | **Usuário notificação** | `SYSDBA` por padrão, editável por linha |

- Na edição do `.config`, manter os demais elementos e valores preexistentes, inclusive `passEncrypted`.
- Fazer backup antes de escrever, validar a estrutura XML e produzir log e status por serviço.
- Botão **Editar .config selecionados**: altera apenas os quatro parâmetros acima nas linhas marcadas **sem invocar o InstallUtil nem instalar serviços**.
- O processo de **Instalar selecionados** deve editar o XML antes da instalação, quando o arquivo existir e estiver válido.

### Particularidade do `Configurar.exe` (atenção)

O usuário informou que o `.exe.config` de aplicação **só passa a existir depois de salvar a configuração pelo aplicativo `Configurar.exe`**. O configurador gráfico foi fornecido/analisado anteriormente. A análise estática não confirmou interface de linha de comando ou parâmetros oficiais para preenchimento automático.

- A última solução disponibilizada inclui botão **Abrir Configurar (inicial)** para abrir o configurador correspondente a cada linha.
- **A geração inicial ainda requer preenchimento e salvamento manual no `Configurar.exe`** na versão relatada; não declarar automação integral como concluída.
- Depois da geração inicial, a atualização dos quatro campos no `.config` é automatizada.
- **Melhoria pendente:** investigar um método confiável e seguro para automatizar o primeiro salvamento do configurador, preservando formato, possíveis segredos criptografados e requisitos da aplicação. Evitar inventar parâmetros não verificados ou criar XML incompleto.

## 6. Serviços Windows já instalados: descoberta, remoção e limpeza

- Segunda grade ao final do formulário para encontrar serviços Windows cujo **nome interno ou display name** contenha `Workflow Service`.
- Exibir informações como nome do serviço, nome exibido, status, diretório e resultado da operação.
- Seleção múltipla de serviços com checkbox.
- Botão **Remover selecionados** com diálogo de confirmação informando os serviços e diretórios afetados.
- Fluxo pretendido: parar serviço, solicitar exclusão com Service Control Manager/`sc.exe delete`, aguardar confirmação da remoção e **só então** remover a pasta correspondente ao executável.
- Regras de proteção: nunca apagar pasta fora da raiz WFL configurada, nem caminho inesperado, vinculado a outro serviço, ou contendo links simbólicos/reparse points. Preservar pasta caso a remoção do serviço não tenha sido confirmada.
- Exclusão de diretório é **permanente**; recomendar backup e validação inicial em homologação.

## 7. Login/credenciais de serviços instalados

- Na grade de serviços já instalados, campos **Usuário Windows** e **Senha** (campo protegido).
- Botão **Alterar login selecionados** aplica a conta/senha aos serviços marcados e relata sucesso/falha individual.
- Exemplos de identidade: `DOMINIO\usuario` (o domínio e nome reais são definidos pelo operador).
- Rotina foi descrita como implementada usando API nativa do Windows Service Control Manager (`ChangeServiceConfig`) em vez de colocar senha na linha de comando do `sc.exe`.
- Tenta atribuir `SeServiceLogonRight` (*Log on as a service*) quando necessário; isso pode depender de política de domínio/GPO.
- Deve reler a conta configurada após alteração e oferecer teste opcional de reinicialização/inicialização do serviço para validar a autenticação de fato.
- **Importante:** conta gravada com sucesso não comprova senha válida; o teste real acontece ao iniciar o serviço. Evitar logar senhas ou expô-las nos argumentos de processo; limpar os campos sensíveis após o uso.

## 8. Logs e segurança

Diretório de logs informado nas versões anteriores:

`C:\ProgramData\Benner\WorkflowInstaller\Logs`

Requisitos:
- Logs individuais de instalação, desbloqueio, XML, login e remoção.
- Operações administrativas com elevação.
- Status de falha/sucesso por linha; falha em uma operação não deve impedir operações independentes nas outras linhas.
- Validar caminhos e nomes antes de operações destrutivas; confirmação explícita antes de apagar serviços/pastas.
- Nunca inserir senhas ou segredos de `.config` em repositórios ou logs.

## 9. Artefatos mencionados no histórico

Os nomes de pacotes gerados ao longo das iterações foram:

1. `BennerWorkflowInstaller.zip` — versão inicial, Dark Mode e desbloqueio em iterações posteriores.
2. `BennerWorkflowInstaller_atualizado.zip` — quatro parâmetros XML.
3. `BennerWorkflowInstaller_editavel.zip` — usuário e usuário de notificação editáveis.
4. `BennerWorkflowInstaller_gerenciar_servicos.zip` — grade de serviços instalados e remoção.
5. `BennerWorkflowInstaller_login_servicos.zip` — alteração da conta de logon.
6. `BennerWorkflowInstaller_reorganizado.zip` — segunda grade movida ao fim.
7. **`BennerWorkflowInstaller_config_inicial.zip`** — último pacote informado, com botão Abrir Configurar e botão Editar .config sem instalação.

Arquivos externos fornecidos pelo usuário no histórico: `Configurar.exe` e `Benner.Tecnologia.Workflow.Runtime.Application.exe.config`.

**Observação:** este documento resume o histórico das solicitações e das implementações relatadas, **não é uma auditoria técnica de código-fonte ou comprovação de que o último ZIP contém todas as alterações**. É necessário revisar o código real e fazer teste em Windows Server.

## 10. GitHub

O usuário pediu conexão do projeto ao GitHub. A integração GitHub foi encontrada e sugerida, mas **não há confirmação na conversa de que a conta foi conectada ou de que um repositório foi criado/publicado**.

Sugestão feita: repositório privado `BennerWorkflowInstaller`.

Estrutura recomendada de repositório (proposta; não representa necessariamente estrutura já existente):

```text
BennerWorkflowInstaller/
  src/
    BennerWorkflowInstaller.ps1
  assets/
    benner-logo.png
  docs/
    CONTEXTO_BENNER_WORKFLOW_INSTALLER.md
  README.md
  .gitignore
```

Proteger quaisquer `.config` reais com credenciais, arquivos de log e artefatos internos com regras apropriadas de `.gitignore`.

## 11. Próximas etapas recomendadas

1. Revisar o conteúdo real do último ZIP e confirmar preservação de todas as funções e da ordem de interface.
2. Testar descoberta, edição de XML e instalação com um único serviço HML.
3. Testar a abertura do Configurar e documentar os passos necessários para o primeiro salvamento.
4. Validar API de alteração de logon, inclusive direito de logon como serviço, GPO e tentativa de partida.
5. Validar proteção de caminhos na exclusão e confirmação de remoção do Service Control Manager.
6. Fazer testes de regressão do Dark Mode, rolagem/redimensionamento da janela e botões agrupados.
7. Conectar o GitHub e publicar somente fontes e documentação sem credenciais.

## 12. Instrução para continuidade em outro chat ou agente

> Continue o projeto Benner Workflow Installer em PowerShell 5.1 + Windows Forms (Dark Mode). Use este documento como contexto dos requisitos e o último código-fonte ZIP fornecido como fonte de verdade sobre o estado efetivo do programa. Preserve as duas grades, com a grade de serviços instalados no final; instalação em lote; desbloqueio; edição XML; botão apenas editar .config; abertura inicial do Configurar; remoção segura; alteração de logon via API Windows e logs individuais. Nunca presuma que o Configurar.exe oferece argumentos CLI não comprovados nem que as rotinas foram testadas em Windows. Ao editar, entregue ZIP atualizado e descreva os testes que foi possível executar.
