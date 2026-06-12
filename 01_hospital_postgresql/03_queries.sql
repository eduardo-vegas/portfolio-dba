-- =============================================================================
-- QUERIES ANALÍTICAS — Sistema Hospitalar
-- Cada query responde uma pergunta real de gestão hospitalar.
-- =============================================================================
SET search_path TO hospital, public;

-- ---------------------------------------------------------------------------
-- Q1: Resumo de agenda por médico — últimos 7 dias
-- FILTER(WHERE): conta condicionalmente sem CASE/SUM aninhado
-- ---------------------------------------------------------------------------
SELECT
    m.nome_completo                                             AS medico,
    e.nome                                                      AS especialidade,
    DATE(a.data_hora_inicio)                                    AS data,
    COUNT(*)                                                    AS total_agendados,
    COUNT(*) FILTER (WHERE a.status = 'REALIZADO')              AS realizados,
    COUNT(*) FILTER (WHERE a.status = 'FALTOU')                 AS faltas,
    COUNT(*) FILTER (WHERE a.status = 'CANCELADO')              AS cancelados,
    ROUND(
        COUNT(*) FILTER (WHERE a.status = 'REALIZADO')::NUMERIC /
        NULLIF(COUNT(*) FILTER (WHERE a.status IN ('REALIZADO','FALTOU')), 0) * 100, 1
    )                                                           AS taxa_comparecimento_pct
FROM agendamentos a
JOIN medicos m         ON m.medico_id       = a.medico_id
JOIN especialidades e  ON e.especialidade_id = m.especialidade_id
WHERE a.data_hora_inicio >= NOW() - INTERVAL '7 days'
GROUP BY m.nome_completo, e.nome, DATE(a.data_hora_inicio)
ORDER BY m.nome_completo, data;

-- ---------------------------------------------------------------------------
-- Q2: Pacientes com READMISSÃO em menos de 30 dias (indicador de qualidade)
-- LAG() compara a internação atual com a alta anterior do mesmo paciente
-- ---------------------------------------------------------------------------
WITH internacoes_lag AS (
    SELECT
        paciente_id,
        data_entrada,
        data_saida,
        LAG(data_saida) OVER (PARTITION BY paciente_id ORDER BY data_entrada) AS alta_anterior
    FROM internacoes WHERE status = 'FINALIZADO'
)
SELECT
    p.nome_completo,
    p.cpf,
    il.alta_anterior                                            AS data_alta_anterior,
    il.data_entrada                                             AS nova_internacao,
    EXTRACT(DAY FROM il.data_entrada - il.alta_anterior)::INT  AS dias_entre_internacoes
FROM internacoes_lag il
JOIN pacientes p ON p.paciente_id = il.paciente_id
WHERE il.alta_anterior IS NOT NULL
  AND il.data_entrada - il.alta_anterior <= INTERVAL '30 days'
ORDER BY dias_entre_internacoes;

-- ---------------------------------------------------------------------------
-- Q3: Top 5 medicamentos por especialidade — últimos 90 dias
-- DENSE_RANK() dentro de cada especialidade (sem QUALIFY — não existe no PG)
-- ---------------------------------------------------------------------------
SELECT especialidade, medicamento, principio_ativo, total, pacientes_distintos, ranking
FROM (
    SELECT
        esp.nome                                                AS especialidade,
        pr.medicamento,
        pr.principio_ativo,
        COUNT(*)                                                AS total,
        COUNT(DISTINCT pron.paciente_id)                       AS pacientes_distintos,
        DENSE_RANK() OVER (
            PARTITION BY esp.nome ORDER BY COUNT(*) DESC
        )                                                       AS ranking
    FROM prescricoes pr
    JOIN prontuarios pron ON pron.prontuario_id   = pr.prontuario_id
                          AND pron.data_consulta   = pr.data_prontuario
    JOIN medicos m        ON m.medico_id           = pron.medico_id
    JOIN especialidades esp ON esp.especialidade_id = m.especialidade_id
    WHERE pr.prescrito_em >= NOW() - INTERVAL '90 days'
    GROUP BY esp.nome, pr.medicamento, pr.principio_ativo
) ranked
WHERE ranking <= 5
ORDER BY especialidade, total DESC;

-- ---------------------------------------------------------------------------
-- Q4: Ocupação de leitos em tempo real por ala e tipo
-- ---------------------------------------------------------------------------
SELECT
    l.ala,
    l.tipo,
    COUNT(l.leito_id)                                           AS total_leitos,
    COUNT(i.internacao_id)                                      AS ocupados,
    COUNT(l.leito_id) - COUNT(i.internacao_id)                  AS disponiveis,
    ROUND(COUNT(i.internacao_id)::NUMERIC / COUNT(l.leito_id) * 100, 1)
                                                                AS taxa_ocupacao_pct
FROM leitos l
LEFT JOIN internacoes i ON i.leito_id = l.leito_id AND i.status = 'ATIVO'
WHERE l.ativo = TRUE
GROUP BY l.ala, l.tipo ORDER BY l.ala, l.tipo;

-- ---------------------------------------------------------------------------
-- Q5: Evolução mensal de consultas por especialidade + variação M/M com LAG()
-- ---------------------------------------------------------------------------
WITH consultas_mes AS (
    SELECT
        DATE_TRUNC('month', a.data_hora_inicio)                 AS mes,
        esp.nome                                                AS especialidade,
        COUNT(*) FILTER (WHERE a.status = 'REALIZADO')          AS total
    FROM agendamentos a
    JOIN medicos m         ON m.medico_id           = a.medico_id
    JOIN especialidades esp ON esp.especialidade_id = m.especialidade_id
    WHERE a.data_hora_inicio >= NOW() - INTERVAL '12 months'
    GROUP BY 1, 2
)
SELECT
    mes, especialidade, total,
    LAG(total) OVER (PARTITION BY especialidade ORDER BY mes) AS mes_anterior,
    total - LAG(total) OVER (PARTITION BY especialidade ORDER BY mes) AS variacao_abs,
    ROUND(
        (total - LAG(total) OVER (PARTITION BY especialidade ORDER BY mes))
        / NULLIF(LAG(total) OVER (PARTITION BY especialidade ORDER BY mes), 0)::NUMERIC * 100, 1
    )                                                           AS variacao_pct
FROM consultas_mes ORDER BY especialidade, mes;

-- ---------------------------------------------------------------------------
-- Q6: Timeline completa de um paciente (UNION ALL de agendamentos + prontuários + internações)
-- ---------------------------------------------------------------------------
WITH timeline AS (
    SELECT a.data_hora_inicio AS data_evento,'AGENDAMENTO'::TEXT AS tipo,
           'Consulta: '||a.tipo_consulta||' — '||a.status AS descricao, m.nome_completo
    FROM agendamentos a JOIN medicos m ON m.medico_id = a.medico_id
    WHERE a.paciente_id = (SELECT paciente_id FROM pacientes WHERE cpf = '12345678901')
    UNION ALL
    SELECT pr.data_consulta,'PRONTUARIO',
           'CID: '||COALESCE(pr.cid10_primario,'N/A')||' | '||LEFT(pr.queixa_principal,80),
           m.nome_completo
    FROM prontuarios pr JOIN medicos m ON m.medico_id = pr.medico_id
    WHERE pr.paciente_id = (SELECT paciente_id FROM pacientes WHERE cpf = '12345678901')
    UNION ALL
    SELECT i.data_entrada,'INTERNACAO',
           'Leito: '||l.numero||' | '||i.motivo, m.nome_completo
    FROM internacoes i JOIN leitos l ON l.leito_id = i.leito_id
                       JOIN medicos m ON m.medico_id = i.medico_resp_id
    WHERE i.paciente_id = (SELECT paciente_id FROM pacientes WHERE cpf = '12345678901')
)
SELECT * FROM timeline ORDER BY data_evento DESC;

-- ---------------------------------------------------------------------------
-- Q7: Exames solicitados há mais de 7 dias sem resultado (cobrança ao laboratório)
-- ---------------------------------------------------------------------------
SELECT
    p.nome_completo AS paciente, p.telefone,
    e.tipo_exame, e.codigo_tuss, e.data_solicitacao,
    EXTRACT(DAY FROM NOW() - e.data_solicitacao)::INT AS dias_aguardando,
    m.nome_completo AS medico_solicitante
FROM exames e
JOIN pacientes p  ON p.paciente_id   = e.paciente_id
LEFT JOIN medicos m ON m.medico_id   = e.medico_solid_id
WHERE e.status NOT IN ('DISPONIVEL','CANCELADO')
  AND e.data_solicitacao < NOW() - INTERVAL '7 days'
ORDER BY dias_aguardando DESC;
