# Benner Workflow Installer

Aplicativo em **Windows PowerShell 5.1 + Windows Forms** (Dark Mode grafite com detalhes vermelhos) para localizar, configurar, instalar e gerenciar em lote os serviços **Benner Workflow** em Windows Server.

> **Situação:** código importado do pacote `BennerWorkflowInstaller_config_inicial.zip`. **Nada foi executado em Windows até o momento.** Veja a cobertura dos requisitos e os pontos de atenção em [docs/REVISAO_REQUISITOS.md](docs/REVISAO_REQUISITOS.md).

## Funcionalidades previstas

- **Descoberta** em raiz editável (padrão `E:\Benner\WFL\VAR1\VAR2\`) das pastas que contêm `Benner.Tecnologia.Workflow.Runtime.Application.exe`. Nome sugerido `VAR1_VAR2`, com opção de usar só `VAR2`, editável por linha.
- **Instalação em lote** e sequencial via `InstallUtil.exe /sys=<nome> <exe>` (.NET Framework 4, 64 bits), com status e log por linha e checagem de duplicados.
- **Desbloquear marcados**: `Unblock-File` recursivo na pasta de cada Workflow.
- **Edição do `.exe.config`**: altera apenas `superServerHost`, `systemName`, `user` e `notifySenderUser`, preservando o restante (inclusive `passEncrypted`), com backup e validação de XML.
- **Primeiro salvamento automático**: sem `.exe.config`, o arquivo é gerado a partir do `.exe.config.modelo` da pasta, reproduzindo o que o `Configurar.exe` faz (comprovado por análise do assembly; detalhes em [docs/LEIA-ME.txt](docs/LEIA-ME.txt)). O botão **Abrir Configurar (inicial)** fica para ajustes extras.
- **Serviços instalados** (`Workflow Service` no nome ou display name):
  - remoção segura: parar, `sc delete`, confirmar no SCM e só então apagar a pasta, nunca fora da raiz WFL, de caminho de outro serviço ou com reparse points;
  - alteração de login via `ChangeServiceConfig` (sem senha em linha de comando), tentativa de `SeServiceLogonRight`, releitura da conta e teste opcional de partida.

## Requisitos

- Windows Server com Windows PowerShell 5.1
- .NET Framework 4.x (`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\InstallUtil.exe`)
- Execução elevada (administrador)

## Uso

1. Copie para o servidor a pasta `src/` (e, opcionalmente, `assets/benner-logo.png` para dentro dela ou para `assets/` ao lado de `src/`).
2. Execute `src\Iniciar-Instalador.cmd` e aceite o UAC. Ele abre `BennerWorkflowInstaller.ps1` elevado, em STA, com `-ExecutionPolicy Bypass` apenas para esse processo.
3. Informe o diretório base (padrão `E:\Benner\WFL`) e clique em **Buscar pastas**.

O passo a passo completo e as limitações de cada função estão em [docs/LEIA-ME.txt](docs/LEIA-ME.txt).

## Estrutura

```text
src/      BennerWorkflowInstaller.ps1 e Iniciar-Instalador.cmd
assets/   benner-logo.png (aproximação estilizada, não é o logo oficial)
docs/     contexto, LEIA-ME original do pacote e revisão de requisitos
```

Detalhes completos em [docs/CONTEXTO_BENNER_WORKFLOW_INSTALLER.md](docs/CONTEXTO_BENNER_WORKFLOW_INSTALLER.md).

## Logs

`C:\ProgramData\Benner\WorkflowInstaller\Logs`

## Segurança

- Nunca versionar `.exe.config` reais, logs, pacotes ZIP, executáveis de terceiros ou credenciais (veja `.gitignore`).
- Nunca registrar senhas ou segredos de `.config` em logs.
- Operações destrutivas exigem confirmação explícita; valide primeiro em homologação.
