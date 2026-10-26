# Benner Workflow Installer

Aplicativo em **Windows PowerShell 5.1 + Windows Forms** (Dark Mode grafite com detalhes vermelhos) para localizar, configurar, instalar e gerenciar em lote os serviços **Benner Workflow** em Windows Server.

> **Situação:** o código-fonte ainda não foi importado para este repositório. A fonte de verdade é o pacote `BennerWorkflowInstaller_config_inicial.zip`. Nenhuma funcionalidade foi testada em Windows até o momento.

## Funcionalidades previstas

- **Descoberta** em raiz editável (padrão `E:\Benner\WFL\VAR1\VAR2\`) das pastas que contêm `Benner.Tecnologia.Workflow.Runtime.Application.exe`. Nome sugerido `VAR1_VAR2`, com opção de usar só `VAR2`, editável por linha.
- **Instalação em lote** e sequencial via `InstallUtil.exe /sys=<nome> <exe>` (.NET Framework 4, 64 bits), com status e log por linha e checagem de duplicados.
- **Desbloquear marcados**: `Unblock-File` recursivo na pasta de cada Workflow.
- **Edição do `.exe.config`**: altera apenas `superServerHost`, `systemName`, `user` e `notifySenderUser`, preservando o restante (inclusive `passEncrypted`), com backup e validação de XML.
- **Abrir Configurar (inicial)**: o `.exe.config` só passa a existir após salvar no `Configurar.exe`; a automação desse primeiro salvamento é pendência.
- **Serviços instalados** (`Workflow Service` no nome ou display name):
  - remoção segura: parar, `sc delete`, confirmar no SCM e só então apagar a pasta, nunca fora da raiz WFL, de caminho de outro serviço ou com reparse points;
  - alteração de login via `ChangeServiceConfig` (sem senha em linha de comando), tentativa de `SeServiceLogonRight`, releitura da conta e teste opcional de partida.

## Requisitos

- Windows Server com Windows PowerShell 5.1
- .NET Framework 4.x (`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\InstallUtil.exe`)
- Execução elevada (administrador)

## Uso

Será documentado quando o script for importado para `src/`.

## Estrutura

```text
src/      código-fonte PowerShell (a importar do ZIP)
assets/   recursos visuais (ex.: benner-logo.png, opcional)
docs/     contexto e requisitos do projeto
```

Detalhes completos em [docs/CONTEXTO_BENNER_WORKFLOW_INSTALLER.md](docs/CONTEXTO_BENNER_WORKFLOW_INSTALLER.md).

## Logs

`C:\ProgramData\Benner\WorkflowInstaller\Logs`

## Segurança

- Nunca versionar `.exe.config` reais, logs, pacotes ZIP, executáveis de terceiros ou credenciais (veja `.gitignore`).
- Nunca registrar senhas ou segredos de `.config` em logs.
- Operações destrutivas exigem confirmação explícita; valide primeiro em homologação.
