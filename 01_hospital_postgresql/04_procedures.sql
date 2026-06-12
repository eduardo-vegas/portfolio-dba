-- =============================================================================
-- STORED PROCEDURES & TRIGGERS — Sistema Hospitalar
-- =============================================================================
SET search_path TO hospital, public;

-- ---------------------------------------------------------------------------
-- TRIGGER: atualiza automaticamente 'atualizado_em' nos pacientes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hospital.fn_atualiza_timestamp()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.atualizado_em = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_pacientes_updated_at
    BEFORE UPDATE ON hospital.pacientes
    FOR EACH ROW EXECUTE FUNCTION hospital.fn_atualiza_timestamp();

-- ---------------------------------------------------------------------------
-- TRIGGER: Audit log genérico via JSONB
-- SECURITY DEFINER: executa como dono da função, não como usuário atual.
-- row_to_json(OLD/NEW) captura o estado completo da linha como JSON.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hospital.fn_audit()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER AS $$
BEGIN
    INSERT INTO hospital.audit_log(
        schema_name, table_name, operacao, app_usuario, dado_antigo, dado_novo
    ) VALUES (
        TG_TABLE_SCHEMA,
        TG_TABLE_NAME,
        TG_OP,
        current_setting('app.usuario_logado', true),
        CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN row_to_json(OLD)::JSONB END,
        CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN row_to_json(NEW)::JSONB END
    );
    RETURN COALESCE(NEW, OLD);
END;
$$;

-- Aplica audit em tabelas sensíveis (LGPD)
CREATE TRIGGER trg_audit_prontuarios
    AFTER INSERT OR UPDATE OR DELETE ON hospital.prontuarios
    FOR EACH ROW EXECUTE FUNCTION hospital.fn_audit();

CREATE TRIGGER trg_audit_prescricoes
    AFTER INSERT OR UPDATE OR DELETE ON hospital.prescricoes
    FOR EACH ROW EXECUTE FUNCTION hospital.fn_audit();

-- ---------------------------------------------------------------------------
-- FUNCTION: verifica se médico está disponível em um intervalo
-- Retorna TRUE se não houver conflito de agenda
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hospital.fn_medico_disponivel(
    p_medico_id UUID,
    p_inicio    TIMESTAMPTZ,
    p_fim       TIMESTAMPTZ
) RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE v_conflitos INT;
BEGIN
    SELECT COUNT(*) INTO v_conflitos
    FROM hospital.agendamentos
    WHERE medico_id = p_medico_id
      AND status NOT IN ('CANCELADO','FALTOU')
      AND tstzrange(data_hora_inicio, data_hora_fim, '[)') &&
          tstzrange(p_inicio, p_fim, '[)');
    RETURN v_conflitos = 0;
END;
$$;

-- ---------------------------------------------------------------------------
-- PROCEDURE: agenda consulta com validações completas
-- O EXCLUDE é o guard final no banco; esta procedure melhora a UX com mensagens claras.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE hospital.sp_agendar_consulta(
    p_paciente_id UUID,
    p_medico_id   UUID,
    p_inicio      TIMESTAMPTZ,
    p_fim         TIMESTAMPTZ,
    p_tipo        VARCHAR DEFAULT 'CONSULTA',
    p_obs         TEXT    DEFAULT NULL
) LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM hospital.medicos
                   WHERE medico_id = p_medico_id AND ativo = TRUE) THEN
        RAISE EXCEPTION 'Médico % não encontrado ou inativo.', p_medico_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM hospital.pacientes
                   WHERE paciente_id = p_paciente_id AND ativo = TRUE) THEN
        RAISE EXCEPTION 'Paciente % não encontrado ou inativo.', p_paciente_id;
    END IF;
    IF p_inicio <= NOW() THEN
        RAISE EXCEPTION 'Não é possível agendar para data/hora passada.';
    END IF;
    IF NOT hospital.fn_medico_disponivel(p_medico_id, p_inicio, p_fim) THEN
        RAISE EXCEPTION 'Médico já possui agendamento no intervalo % — %.', p_inicio, p_fim;
    END IF;

    INSERT INTO hospital.agendamentos(
        paciente_id, medico_id, data_hora_inicio, data_hora_fim, tipo_consulta, observacoes
    ) VALUES (p_paciente_id, p_medico_id, p_inicio, p_fim, p_tipo, p_obs);

    RAISE NOTICE 'Consulta agendada para %.', p_inicio;
END;
$$;

-- Exemplo de uso:
-- CALL hospital.sp_agendar_consulta(
--     'UUID-PACIENTE', 'UUID-MEDICO',
--     NOW() + INTERVAL '2 days',
--     NOW() + INTERVAL '2 days' + INTERVAL '30 minutes'
-- );

-- ---------------------------------------------------------------------------
-- FUNCTION: timeline completa do paciente (retorna TABLE)
-- Usada por dashboards clínicos e relatórios de histórico
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION hospital.fn_timeline_paciente(p_paciente_id UUID)
RETURNS TABLE (data_evento TIMESTAMPTZ, tipo_evento TEXT, descricao TEXT, profissional TEXT)
LANGUAGE sql STABLE AS $$
    SELECT a.data_hora_inicio, 'AGENDAMENTO'::TEXT,
           'Consulta: '||a.tipo_consulta||' | '||a.status, m.nome_completo
    FROM hospital.agendamentos a JOIN hospital.medicos m ON m.medico_id = a.medico_id
    WHERE a.paciente_id = p_paciente_id
    UNION ALL
    SELECT pr.data_consulta, 'PRONTUARIO'::TEXT,
           'CID: '||COALESCE(pr.cid10_primario,'N/A')||' | '||LEFT(pr.queixa_principal,100),
           m.nome_completo
    FROM hospital.prontuarios pr JOIN hospital.medicos m ON m.medico_id = pr.medico_id
    WHERE pr.paciente_id = p_paciente_id
    UNION ALL
    SELECT i.data_entrada, 'INTERNACAO'::TEXT,
           'Leito: '||l.numero||' | '||i.motivo, m.nome_completo
    FROM hospital.internacoes i
    JOIN hospital.leitos l ON l.leito_id = i.leito_id
    JOIN hospital.medicos m ON m.medico_id = i.medico_resp_id
    WHERE i.paciente_id = p_paciente_id
    ORDER BY 1 DESC;
$$;
