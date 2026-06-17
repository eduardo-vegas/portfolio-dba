#Requires -Version 5.1
# ==============================================================================
# 🏷️  TIPO       : PowerShell Script
# 🖥️  PLATAFORMA : Windows (PowerShell 5.1+ ou PowerShell 7+)
# ⚙️  EQUIVALENTE: hospital_backup.sh (Shell Script — Linux/macOS)
# 📋  DEPENDÊNCIAS: PostgreSQL client no PATH (pg_dump.exe, pg_restore.exe)
# 🕐  AGENDAMENTO: Agendador de Tarefas do Windows — diariamente às 02:00
# ==============================================================================
# ROTINA 1: Backup Automatizado com Rotação de Arquivos
# Sistema Hospitalar — PostgreSQL 16
#
# POLÍTICA DE RETENÇÃO:
#   ├── 7 backups diários  → últimos 7 dias
#   ├── 4 backups semanais → domingo de cada semana (últimas 4)
#   └── 3 backups mensais  → dia 1 de cada mês (últimos 3)
#
# FORMATO DO ARQUIVO: hospital_db_daily_2025-06-15.dump
#   pg_dump -Fc (formato customizado do PostgreSQL)
#   Restaurar: pg_restore -d hospital_db arquivo.dump
#
# SETUP INICIAL:
#   1. Garantir que pg_dump.exe está no PATH do sistema:
#      C:\Program Files\PostgreSQL\16\bin  →  Variáveis de Ambiente do Windows
#   2. Configurar senha via pgpass.conf (sem hardcode):
#      %APPDATA%\postgresql\pgpass.conf
#      Conteúdo: localhost:5432:hospital_db:postgres:SENHA
#   3. Liberar execução de scripts PowerShell (uma vez, como Administrador):
#      Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
#   4. Testar manualmente: .\hospital_backup.ps1
#   5. Criar tarefa no Agendador: ver seção AGENDADOR no final deste arquivo
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ==============================================================================
# CONFIG — editar conforme o ambiente
# ==============================================================================
$DB_HOST      = "localhost"
$DB_PORT      = "5432"
$DB_NAME      = "hospital_db"
$DB_USER      = "postgres"
$BACKUP_ROOT  = "C:\Backups\Hospital"
$LOG_FILE     = "C:\Logs\Hospital\hospital_backup.log"

$RETENCAO = @{
    Daily   = 7
    Weekly  = 4
    Monthly = 3
}

# pg_dump no PATH? Se não, usar caminho completo:
# $PG_DUMP = "C:\Program Files\PostgreSQL\16\bin\pg_dump.exe"
$PG_DUMP    = "pg_dump"
$PG_RESTORE = "pg_restore"

# ==============================================================================
# FUNÇÕES UTILITÁRIAS
# ==============================================================================
function Write-Log {
    param(
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO",
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $entrada   = "[$timestamp] [$Level] $Message"

    # Garantir que o diretório de log existe
    $logDir = Split-Path $LOG_FILE -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    Add-Content -Path $LOG_FILE -Value $entrada -Encoding UTF8

    # Console com cores por nível
    switch ($Level) {
        "INFO"  { Write-Host $entrada -ForegroundColor Cyan }
        "WARN"  { Write-Host $entrada -ForegroundColor Yellow }
        "ERROR" { Write-Host $entrada -ForegroundColor Red }
    }
}

function New-BackupDirectories {
    foreach ($tipo in @("daily", "weekly", "monthly")) {
        $path = Join-Path $BACKUP_ROOT $tipo
        if (-not (Test-Path $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
    Write-Log "INFO" "Diretórios de backup verificados em: $BACKUP_ROOT"
}

# ==============================================================================
# FUNÇÕES PRINCIPAIS
# ==============================================================================
function Invoke-Backup {
    param(
        [string]$Tipo,
        [string]$Sufixo
    )

    $nomeArquivo = "${DB_NAME}_${Tipo}_${Sufixo}.dump"
    $destino     = Join-Path $BACKUP_ROOT $Tipo $nomeArquivo

    Write-Log "INFO" "Iniciando backup [$Tipo] → $destino"

    # Credenciais via variáveis de ambiente (não hardcode no script)
    # A senha deve estar no pgpass.conf ou em $env:PGPASSWORD definido
    # externamente (ex: no Agendador de Tarefas como variável da tarefa)
    $env:PGHOST = $DB_HOST
    $env:PGPORT = $DB_PORT
    $env:PGUSER = $DB_USER

    $argumentos = @(
        "-Fc",           # Custom format — mais eficiente, suporta restore seletivo
        "--dbname=$DB_NAME",
        "--file=$destino"
    )

    $processo = Start-Process `
        -FilePath    $PG_DUMP `
        -ArgumentList $argumentos `
        -Wait         `
        -PassThru     `
        -NoNewWindow

    if ($processo.ExitCode -ne 0) {
        # Remove arquivo corrompido/incompleto antes de lançar o erro
        if (Test-Path $destino) { Remove-Item $destino -Force }
        throw "pg_dump encerrou com código $($processo.ExitCode) para backup [$Tipo]."
    }

    $tamanhoMB = [Math]::Round((Get-Item $destino).Length / 1MB, 2)
    Write-Log "INFO" "Backup [$Tipo] concluído: $nomeArquivo ($($tamanhoMB) MB)"
}

function Invoke-Rotation {
    param(
        [string]$Tipo,
        [int]$Max
    )
    $dir      = Join-Path $BACKUP_ROOT $Tipo
    $arquivos = Get-ChildItem -Path $dir -Filter "*.dump" |
                Sort-Object LastWriteTime -Descending

    if ($arquivos.Count -gt $Max) {
        # Seleciona os mais antigos (após o limite) para remoção
        $paraRemover = $arquivos | Select-Object -Skip $Max
        foreach ($arquivo in $paraRemover) {
            Write-Log "INFO" "Rotação [$Tipo]: removendo $($arquivo.Name)"
            Remove-Item $arquivo.FullName -Force
        }
    }
    else {
        Write-Log "INFO" "Rotação [$Tipo]: $($arquivos.Count)/$Max arquivos — sem remoção."
    }
}

function Test-BackupIntegrity {
    $dir    = Join-Path $BACKUP_ROOT "daily"
    $ultimo = Get-ChildItem -Path $dir -Filter "*.dump" |
              Sort-Object LastWriteTime -Descending |
              Select-Object -First 1

    if (-not $ultimo) {
        Write-Log "WARN" "Nenhum backup diário encontrado para verificação."
        return
    }

    Write-Log "INFO" "Verificando integridade: $($ultimo.Name)"

    # --list: lê apenas o catálogo do arquivo, sem restaurar dados
    $proc = Start-Process `
        -FilePath    $PG_RESTORE `
        -ArgumentList @("--list", $ultimo.FullName) `
        -Wait         `
        -PassThru     `
        -NoNewWindow  `
        -RedirectStandardOutput "NUL"

    if ($proc.ExitCode -eq 0) {
        Write-Log "INFO" "Integridade OK ✓"
    }
    else {
        Write-Log "WARN" "Possível problema de integridade: $($ultimo.Name)"
    }
}

function Write-ResumoDisco {
    Write-Log "INFO" "Uso de disco em $BACKUP_ROOT :"
    foreach ($tipo in @("daily", "weekly", "monthly")) {
        $dir = Join-Path $BACKUP_ROOT $tipo
        if (Test-Path $dir) {
            $tamanho = (Get-ChildItem $dir -Recurse | Measure-Object -Property Length -Sum).Sum
            $tamanhoMB = [Math]::Round($tamanho / 1MB, 2)
            Write-Log "INFO" "  $tipo : $tamanhoMB MB"
        }
    }
}

# ==============================================================================
# MAIN
# ==============================================================================
try {
    Write-Log "INFO" "================================================================"
    Write-Log "INFO" "INÍCIO DO BACKUP — $DB_NAME @ ${DB_HOST}:${DB_PORT}"
    Write-Log "INFO" "================================================================"

    New-BackupDirectories

    $hoje      = Get-Date -Format "yyyy-MM-dd"
    $diaSemana = [int](Get-Date).DayOfWeek   # 0=domingo, 6=sábado
    $diaMes    = (Get-Date).Day

    # ── Backup diário: sempre ─────────────────────────────────────────────────
    Invoke-Backup  -Tipo "daily"  -Sufixo $hoje
    Invoke-Rotation -Tipo "daily"  -Max $RETENCAO.Daily

    # ── Backup semanal: apenas no domingo (DayOfWeek = 0) ────────────────────
    if ($diaSemana -eq 0) {
        # Número da semana ISO 8601
        $numSemana = Get-Date -UFormat "%V"
        $sufixoSemana = "$(Get-Date -Format 'yyyy')-W$numSemana"
        Invoke-Backup  -Tipo "weekly" -Sufixo $sufixoSemana
        Invoke-Rotation -Tipo "weekly" -Max $RETENCAO.Weekly
        Write-Log "INFO" "Backup semanal gerado para: $sufixoSemana"
    }

    # ── Backup mensal: apenas no dia 1 ───────────────────────────────────────
    if ($diaMes -eq 1) {
        $sufixoMes = Get-Date -Format "yyyy-MM"
        Invoke-Backup  -Tipo "monthly" -Sufixo $sufixoMes
        Invoke-Rotation -Tipo "monthly" -Max $RETENCAO.Monthly
        Write-Log "INFO" "Backup mensal gerado para: $sufixoMes"
    }

    Test-BackupIntegrity
    Write-ResumoDisco

    Write-Log "INFO" "BACKUP CONCLUÍDO COM SUCESSO ✓"
    Write-Log "INFO" "================================================================"
    exit 0

}
catch {
    Write-Log "ERROR" "FALHA NO BACKUP: $_"

    # ── Ponto de extensão: alertas externos ───────────────────────────────────
    # Slack webhook (definir $env:SLACK_WEBHOOK no Agendador de Tarefas):
    # if ($env:SLACK_WEBHOOK) {
    #     $body = @{ text = "🚨 Backup Hospital falhou: $_" } | ConvertTo-Json
    #     Invoke-RestMethod -Uri $env:SLACK_WEBHOOK -Method Post -Body $body -ContentType "application/json"
    # }
    # ─────────────────────────────────────────────────────────────────────────
    exit 1
}

# ==============================================================================
# COMO AGENDAR NO WINDOWS (Agendador de Tarefas)
# Executar no PowerShell como Administrador:
# ==============================================================================
<#
$acao    = New-ScheduledTaskAction `
               -Execute "powershell.exe" `
               -Argument "-NonInteractive -ExecutionPolicy RemoteSigned -File `"C:\Scripts\hospital_backup.ps1`""

$gatilho = New-ScheduledTaskTrigger -Daily -At "02:00AM"

$config  = New-ScheduledTaskSettingsSet `
               -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
               -RestartCount 1 `
               -RestartInterval (New-TimeSpan -Minutes 30)

Register-ScheduledTask `
    -TaskName    "Hospital_PostgreSQL_Backup" `
    -TaskPath    "\Hospital\" `
    -Action      $acao `
    -Trigger     $gatilho `
    -Settings    $config `
    -RunLevel    Highest `
    -Description "Backup diário automatizado do banco hospital_db (PostgreSQL 16)"
#>
