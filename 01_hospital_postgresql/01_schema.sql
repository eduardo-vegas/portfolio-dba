-- =============================================================================
-- PROJETO 1: Sistema de Gestão Hospitalar
-- Banco: PostgreSQL 16
-- Recursos: UUID, EXCLUDE GIST, particionamento RANGE, JSONB, RLS, audit trigger
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";   -- uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS "pg_trgm";     -- índice trigram para busca por nome
CREATE EXTENSION IF NOT EXISTS "btree_gist";  -- EXCLUDE com colunas não-geométricas (UUID)

CREATE SCHEMA IF NOT EXISTS hospital;

-- ---------------------------------------------------------------------------
-- TABELAS DE LOOKUP
-- ---------------------------------------------------------------------------
CREATE TABLE hospital.especialidades (
    especialidade_id  SERIAL       PRIMARY KEY,
    nome              VARCHAR(100) NOT NULL UNIQUE,
    descricao         TEXT,
    ativo             BOOLEAN      DEFAULT TRUE
);

-- CID-10: referência para diagnósticos (importar tabela oficial DATASUS)
CREATE TABLE hospital.cid10 (
    codigo            CHAR(7)      PRIMARY KEY,   -- ex: A00.0, K35.2, I10
    descricao         VARCHAR(300) NOT NULL,
    categoria         VARCHAR(100),
    capitulo          VARCHAR(100)
);

-- ---------------------------------------------------------------------------
-- MÉDICOS E ESTRUTURA DE ATENDIMENTO
-- ---------------------------------------------------------------------------
CREATE TABLE hospital.medicos (
    medico_id         UUID         DEFAULT uuid_generate_v4() PRIMARY KEY,
    crm               VARCHAR(20)  NOT NULL UNIQUE,
    nome_completo     VARCHAR(200) NOT NULL,
    especialidade_id  INT          REFERENCES hospital.especialidades(especialidade_id),
    telefone          VARCHAR(20),
    email             VARCHAR(150) NOT NULL UNIQUE,
    ativo             BOOLEAN      DEFAULT TRUE,
    criado_em         TIMESTAMPTZ  DEFAULT NOW()
);

CREATE TABLE hospital.horarios_medico (
    horario_id        SERIAL       PRIMARY KEY,
    medico_id         UUID         NOT NULL REFERENCES hospital.medicos(medico_id),
    dia_semana        SMALLINT     NOT NULL CHECK (dia_semana BETWEEN 0 AND 6),  -- 0=Dom
    hora_inicio       TIME         NOT NULL,
    hora_fim          TIME         NOT NULL,
    duracao_slot_min  SMALLINT     DEFAULT 30 CHECK (duracao_slot_min IN (15,20,30,45,60)),
    ativo             BOOLEAN      DEFAULT TRUE,
    UNIQUE (medico_id, dia_semana, hora_inicio),
    CONSTRAINT chk_horario CHECK (hora_fim > hora_inicio)
);

-- ---------------------------------------------------------------------------
-- PACIENTES
-- ---------------------------------------------------------------------------
CREATE TABLE hospital.pacientes (
    paciente_id       UUID         DEFAULT uuid_generate_v4() PRIMARY KEY,
    cpf               CHAR(11)     NOT NULL UNIQUE,
    nome_completo     VARCHAR(200) NOT NULL,
    data_nascimento   DATE         NOT NULL,
    sexo              CHAR(1)      CHECK (sexo IN ('M','F','O')),
    tipo_sanguineo    VARCHAR(3),
    telefone          VARCHAR(20),
    email             VARCHAR(150),
    logradouro        VARCHAR(200),
    numero            VARCHAR(10),
    bairro            VARCHAR(100),
    cidade            VARCHAR(100),
    estado            CHAR(2),
    cep               CHAR(8),
    nome_responsavel  VARCHAR(200),   -- para menores de idade
    convenio          VARCHAR(100),
    numero_convenio   VARCHAR(50),
    ativo             BOOLEAN      DEFAULT TRUE,
    criado_em         TIMESTAMPTZ  DEFAULT NOW(),
    atualizado_em     TIMESTAMPTZ  DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- AGENDAMENTOS — EXCLUDE CONSTRAINT anti-double-booking
-- Impede que o mesmo médico tenha dois agendamentos com sobreposição de tempo.
-- btree_gist permite usar UUID (tipo B-tree) dentro de um índice GIST.
-- ---------------------------------------------------------------------------
CREATE TABLE hospital.agendamentos (
    agendamento_id    UUID         DEFAULT uuid_generate_v4() PRIMARY KEY,
    paciente_id       UUID         NOT NULL REFERENCES hospital.pacientes(paciente_id),
    medico_id         UUID         NOT NULL REFERENCES hospital.medicos(medico_id),
    data_hora_inicio  TIMESTAMPTZ  NOT NULL,
    data_hora_fim     TIMESTAMPTZ  NOT NULL,
    tipo_consulta     VARCHAR(20)  DEFAULT 'CONSULTA'
                      CHECK (tipo_consulta IN ('CONSULTA','RETORNO','URGENCIA','EXAME','CIRURGIA')),
    status            VARCHAR(20)  DEFAULT 'AGENDADO'
                      CHECK (status IN ('AGENDADO','CONFIRMADO','REALIZADO','CANCELADO','FALTOU')),
    observacoes       TEXT,
    criado_em         TIMESTAMPTZ  DEFAULT NOW(),
    CONSTRAINT chk_agend_datas CHECK (data_hora_fim > data_hora_inicio),
    -- EXCLUDE: mesmo médico + intervalos de tempo sobrepostos → rejeita inserção
    EXCLUDE USING GIST (
        medico_id WITH =,
        tstzrange(data_hora_inicio, data_hora_fim, '[)') WITH &&
    ) WHERE (status NOT IN ('CANCELADO','FALTOU'))
);

-- ---------------------------------------------------------------------------
-- PRONTUÁRIOS — PARTICIONADO POR RANGE (ano)
-- Queries em 2025 não tocam nos dados de 2023 ou 2024.
-- PK composta (prontuario_id, data_consulta) é obrigatória para tabela particionada.
-- ---------------------------------------------------------------------------
CREATE TABLE hospital.prontuarios (
    prontuario_id     UUID         DEFAULT uuid_generate_v4(),
    paciente_id       UUID         NOT NULL,
    medico_id         UUID         NOT NULL,
    agendamento_id    UUID,
    data_consulta     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    queixa_principal  TEXT         NOT NULL,
    anamnese          TEXT,
    exame_fisico      TEXT,
    hipotese_diag     VARCHAR(255),
    cid10_primario    CHAR(7)      REFERENCES hospital.cid10(codigo),
    cid10_secundarios CHAR(7)[],   -- array nativo: sem tabela de junção extra
    conduta           TEXT,
    observacoes       TEXT,
    criado_em         TIMESTAMPTZ  DEFAULT NOW(),
    PRIMARY KEY (prontuario_id, data_consulta)
) PARTITION BY RANGE (data_consulta);

-- Partições anuais — criar nova partição todo dezembro para o ano seguinte
CREATE TABLE hospital.prontuarios_2023 PARTITION OF hospital.prontuarios
    FOR VALUES FROM ('2023-01-01') TO ('2024-01-01');
CREATE TABLE hospital.prontuarios_2024 PARTITION OF hospital.prontuarios
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
CREATE TABLE hospital.prontuarios_2025 PARTITION OF hospital.prontuarios
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
CREATE TABLE hospital.prontuarios_2026 PARTITION OF hospital.prontuarios
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

-- FKs em tabela particionada (PostgreSQL 12+)
ALTER TABLE hospital.prontuarios
    ADD CONSTRAINT fk_pront_paciente FOREIGN KEY (paciente_id)
        REFERENCES hospital.pacientes(paciente_id);
ALTER TABLE hospital.prontuarios
    ADD CONSTRAINT fk_pront_medico FOREIGN KEY (medico_id)
        REFERENCES hospital.medicos(medico_id);

-- ---------------------------------------------------------------------------
-- PRESCRIÇÕES
-- ---------------------------------------------------------------------------
CREATE TABLE hospital.prescricoes (
    prescricao_id   UUID         DEFAULT uuid_generate_v4() PRIMARY KEY,
    prontuario_id   UUID         NOT NULL,
    data_prontuario TIMESTAMPTZ  NOT NULL,
    medicamento     VARCHAR(200) NOT NULL,
    principio_ativo VARCHAR(200),
    dose            VARCHAR(50)  NOT NULL,       -- ex: "500mg"
    via             VARCHAR(50),                 -- oral, IV, IM, SC, tópico
    frequencia      VARCHAR(100) NOT NULL,        -- ex: "8/8 horas"
    duracao_dias    SMALLINT,
    quantidade      SMALLINT,
    instrucoes      TEXT,
    prescrito_em    TIMESTAMPTZ  DEFAULT NOW(),
    FOREIGN KEY (prontuario_id, data_prontuario)
        REFERENCES hospital.prontuarios(prontuario_id, data_consulta)
);

-- ---------------------------------------------------------------------------
-- LEITOS E INTERNAÇÕES
-- ---------------------------------------------------------------------------
CREATE TABLE hospital.leitos (
    leito_id  SERIAL      PRIMARY KEY,
    numero    VARCHAR(10) NOT NULL UNIQUE,
    ala       VARCHAR(50) NOT NULL,
    tipo      VARCHAR(20) CHECK (tipo IN ('ENFERMARIA','UTI','SEMINTENSIVA','ISOLAMENTO','CIRURGICO')),
    ativo     BOOLEAN     DEFAULT TRUE
);

CREATE TABLE hospital.internacoes (
    internacao_id  UUID         DEFAULT uuid_generate_v4() PRIMARY KEY,
    paciente_id    UUID         NOT NULL REFERENCES hospital.pacientes(paciente_id),
    leito_id       INT          NOT NULL REFERENCES hospital.leitos(leito_id),
    medico_resp_id UUID         NOT NULL REFERENCES hospital.medicos(medico_id),
    data_entrada   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    data_saida     TIMESTAMPTZ,
    motivo         TEXT         NOT NULL,
    cid10_admissao CHAR(7)      REFERENCES hospital.cid10(codigo),
    cid10_alta     CHAR(7)      REFERENCES hospital.cid10(codigo),
    tipo_alta      VARCHAR(20)  CHECK (tipo_alta IN ('CURADO','TRANSFERIDO','OBITO','EVASAO','A_PEDIDO')),
    obs_alta       TEXT,
    status         VARCHAR(20)  DEFAULT 'ATIVO' CHECK (status IN ('ATIVO','FINALIZADO')),
    CONSTRAINT chk_intern_datas CHECK (data_saida IS NULL OR data_saida > data_entrada)
);

-- ---------------------------------------------------------------------------
-- EXAMES — resultado pode ser texto ou JSON estruturado (hemograma, ECG, etc.)
-- ---------------------------------------------------------------------------
CREATE TABLE hospital.exames (
    exame_id         UUID         DEFAULT uuid_generate_v4() PRIMARY KEY,
    paciente_id      UUID         NOT NULL REFERENCES hospital.pacientes(paciente_id),
    medico_solid_id  UUID         REFERENCES hospital.medicos(medico_id),
    tipo_exame       VARCHAR(100) NOT NULL,
    codigo_tuss      VARCHAR(20),                -- código TUSS para faturamento SADT
    data_solicitacao TIMESTAMPTZ  DEFAULT NOW(),
    data_coleta      TIMESTAMPTZ,
    data_resultado   TIMESTAMPTZ,
    resultado_texto  TEXT,
    resultado_json   JSONB,                      -- valores estruturados (hemograma, etc.)
    status           VARCHAR(20)  DEFAULT 'SOLICITADO'
                     CHECK (status IN ('SOLICITADO','COLETADO','EM_ANALISE','DISPONIVEL','CANCELADO')),
    laudo            TEXT,
    criado_em        TIMESTAMPTZ  DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- AUDIT LOG — imutável; rastreia INSERT/UPDATE/DELETE em tabelas sensíveis
-- ---------------------------------------------------------------------------
CREATE TABLE hospital.audit_log (
    log_id      BIGSERIAL    PRIMARY KEY,
    schema_name TEXT         NOT NULL,
    table_name  TEXT         NOT NULL,
    operacao    TEXT         NOT NULL CHECK (operacao IN ('INSERT','UPDATE','DELETE')),
    usuario_db  TEXT         DEFAULT current_user,
    app_usuario TEXT,                    -- usuário da aplicação via SET LOCAL
    data_hora   TIMESTAMPTZ  DEFAULT NOW(),
    dado_antigo JSONB,                   -- estado anterior (UPDATE/DELETE)
    dado_novo   JSONB,                   -- estado novo (INSERT/UPDATE)
    ip_origem   INET
);

-- ---------------------------------------------------------------------------
-- ÍNDICES
-- ---------------------------------------------------------------------------
-- Trigram: suporta ILIKE '%carlos%' com índice (sem full scan)
CREATE INDEX idx_pac_nome_trgm  ON hospital.pacientes USING GIN (nome_completo gin_trgm_ops);
CREATE INDEX idx_pac_cpf        ON hospital.pacientes(cpf);

-- Agenda do médico
CREATE INDEX idx_agend_med_data ON hospital.agendamentos(medico_id, data_hora_inicio DESC);
CREATE INDEX idx_agend_pac      ON hospital.agendamentos(paciente_id, data_hora_inicio DESC);

-- Histórico do paciente (aplica nas partições automaticamente)
CREATE INDEX idx_pront_pac  ON hospital.prontuarios(paciente_id, data_consulta DESC);
CREATE INDEX idx_pront_med  ON hospital.prontuarios(medico_id,   data_consulta DESC);

-- Índice parcial: só busca exames em aberto (ignora DISPONIVEL/CANCELADO)
CREATE INDEX idx_exames_pend ON hospital.exames(paciente_id, data_solicitacao)
    WHERE status NOT IN ('DISPONIVEL','CANCELADO');

-- Índice parcial: leitos ativos em tempo real
CREATE INDEX idx_intern_ativas ON hospital.internacoes(leito_id, data_entrada)
    WHERE status = 'ATIVO';

-- ---------------------------------------------------------------------------
-- ROW LEVEL SECURITY
-- ---------------------------------------------------------------------------
ALTER TABLE hospital.pacientes   ENABLE ROW LEVEL SECURITY;
ALTER TABLE hospital.prontuarios ENABLE ROW LEVEL SECURITY;

-- Médico vê apenas prontuários de consultas que realizou
CREATE POLICY pol_medico_prontuarios ON hospital.prontuarios
    FOR SELECT TO app_medico
    USING (medico_id = current_setting('app.medico_id', true)::UUID);

-- Paciente vê apenas seus próprios dados
CREATE POLICY pol_paciente_dados ON hospital.pacientes
    FOR SELECT TO app_paciente
    USING (paciente_id = current_setting('app.paciente_id', true)::UUID);

-- Admin vê tudo
CREATE POLICY pol_admin_pac   ON hospital.pacientes   TO app_admin USING (true);
CREATE POLICY pol_admin_pront ON hospital.prontuarios TO app_admin USING (true);
