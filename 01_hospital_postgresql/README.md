# 🏥 Projeto 1 — Sistema de Gestão Hospitalar

## 🩺 O Problema (A Dor do Cliente)

Hospitais e clínicas de médio porte no Brasil ainda gerenciam prontuários em papel
ou em sistemas legados desconectados. As dores mais frequentes:

- **Double-booking**: dois pacientes marcados para o mesmo médico/horário
- **Prontuários sem rastreabilidade**: quem alterou, quando e o quê? (LGPD exige)
- **Prescrições conflitantes**: mesmo paciente, dois médicos, sem visibilidade cruzada
- **Readmissões não monitoradas**: paciente reinternado em < 30 dias sem alerta
- **Relatórios gerenciais no Excel**: taxa de ocupação de leitos calculada manualmente

**Valor do projeto para o cliente**: R$ 8.000–25.000 (implantação) + manutenção mensal

---

## 🏗️ Arquitetura

```
┌────────────────────────────────────────────────────────────────┐
│  Schema: hospital (PostgreSQL 16)                              │
│                                                                │
│  especialidades ──► medicos ──► horarios_medico               │
│                        │                                      │
│  cid10 ──► prontuarios ┤  (PARTICIONADO por ano)              │
│                 │      │                                      │
│           prescricoes  agendamentos ◄── pacientes             │
│                        │               │                      │
│          leitos ──► internacoes ───────┘                      │
│                        │                                      │
│                      exames                                   │
│                                                               │
│  audit_log  ← trigger em prontuarios, prescricoes             │
└────────────────────────────────────────────────────────────────┘
```

---

## 📋 Entidades e Volume Estimado

| Tabela | Linhas Estimadas | Descrição |
|--------|-----------------|-----------|
| `pacientes` | 10k–500k | Cadastro completo com dados pessoais e plano |
| `medicos` | 20–500 | CRM, especialidade, grade de horários |
| `especialidades` | 50–200 | Lookup de especialidades médicas |
| `horarios_medico` | 100–2k | Grade semanal por médico |
| `agendamentos` | 100k–10M | Com constraint EXCLUDE anti-double-booking |
| `prontuarios` | 200k–50M | **PARTICIONADO por ano** |
| `prescricoes` | 500k–100M | Medicamentos vinculados ao prontuário |
| `leitos` | 10–500 | Cadastro físico (ala, tipo) |
| `internacoes` | 10k–1M | Entrada/saída com CID10 |
| `exames` | 50k–10M | Resultados em TEXT ou JSONB estruturado |
| `audit_log` | ilimitado | Registro imutável de mutações sensíveis |

---

## 🔑 Recursos Técnicos Demonstrados

| Recurso | Onde | Por quê é necessário |
|---------|------|---------------------|
| `EXCLUDE USING GIST` | agendamentos | Impede double-booking no nível do banco |
| `PARTITION BY RANGE` | prontuarios | Performance em tabelas com anos de histórico |
| `JSONB` | exames, audit_log | Resultados semi-estruturados (hemograma, etc.) |
| `uuid_generate_v4()` | PKs sensíveis | Evita enumeração de IDs na API |
| `pg_trgm` | pacientes.nome | LIKE '%nome%' com índice GIN |
| `btree_gist` | agendamentos | Habilita EXCLUDE com UUID (não-geométrico) |
| Row Level Security | pacientes, prontuarios | Cada role vê apenas seus dados |
| Trigger de audit | prontuarios, prescricoes | Rastreabilidade LGPD |
| `tstzrange` | agendamentos | Range type nativo para sobreposição de tempo |
| Array `CHAR(7)[]` | prontuarios | CIDs secundários sem tabela de junção extra |

---

## ⚙️ Setup

### Windows (DBeaver + PostgreSQL 16)

```powershell
# 1. Instalar PostgreSQL 16 em https://www.postgresql.org/download/windows/
# 2. No psql ou DBeaver:
psql -U postgres -c "CREATE DATABASE hospital_db;"
psql -U postgres -d hospital_db -f 01_schema.sql
psql -U postgres -d hospital_db -f 02_sample_data.sql
```

### Linux (Ubuntu 22.04)

```bash
sudo apt install postgresql-16 postgresql-contrib-16
sudo -u postgres psql -c "CREATE DATABASE hospital_db;"
sudo -u postgres psql -d hospital_db -f 01_schema.sql
sudo -u postgres psql -d hospital_db -f 02_sample_data.sql
```

---

## 📊 Estimativa de Recursos para o Cliente

| Volume | CPU | RAM | Disco | Backup |
|--------|-----|-----|-------|--------|
| Clínica < 5k pacientes/ano | 2 vCPU | 4 GB | 50 GB SSD | Diário |
| Hospital médio 50k/ano | 8 vCPU | 32 GB | 500 GB NVMe | WAL contínuo |
| Rede hospitalar 500k/ano | 32 vCPU | 128 GB | 2 TB NVMe | Streaming + PITR |
