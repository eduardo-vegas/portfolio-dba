-- =============================================================================
-- DADOS DE EXEMPLO — Sistema Hospitalar (contexto: Fortaleza/CE)
-- =============================================================================
SET search_path TO hospital, public;

INSERT INTO especialidades(nome) VALUES
    ('Clínica Geral'),('Cardiologia'),('Ortopedia'),
    ('Pediatria'),('Neurologia'),('Ginecologia'),('Psiquiatria');

INSERT INTO cid10(codigo, descricao, categoria) VALUES
    ('J00',   'Rinofaringite aguda (resfriado comum)',     'Respiratório'),
    ('I10',   'Hipertensão essencial (primária)',          'Circulatório'),
    ('K35.2', 'Apendicite aguda com peritonite',          'Digestivo'),
    ('M54.5', 'Dor lombar baixa',                         'Osteomuscular'),
    ('F32.0', 'Episódio depressivo leve',                 'Mental'),
    ('E11',   'Diabetes mellitus tipo 2',                 'Endócrino'),
    ('J18.9', 'Pneumonia não especificada',               'Respiratório'),
    ('S52.5', 'Fratura da extremidade distal do rádio',   'Lesões');

INSERT INTO medicos(crm, nome_completo, especialidade_id, email) VALUES
    ('CRM/CE-12345','Dr. Antônio Ferreira Lima',   1,'antonio.lima@hospital.com'),
    ('CRM/CE-23456','Dra. Beatriz Santos Nunes',   2,'beatriz.nunes@hospital.com'),
    ('CRM/CE-34567','Dr. Carlos Mendonça Alves',   3,'carlos.alves@hospital.com'),
    ('CRM/CE-45678','Dra. Diana Rocha Cavalcante', 4,'diana.cavalcante@hospital.com'),
    ('CRM/CE-56789','Dr. Eduardo Pinto Moreira',   5,'eduardo.moreira@hospital.com');

-- Grade semanal seg-sex para todos os médicos
INSERT INTO horarios_medico(medico_id, dia_semana, hora_inicio, hora_fim)
SELECT m.medico_id, d.dia, '08:00'::TIME, '17:00'::TIME
FROM medicos m CROSS JOIN (VALUES (1),(2),(3),(4),(5)) AS d(dia);

INSERT INTO leitos(numero, ala, tipo) VALUES
    ('A01','Ala A','ENFERMARIA'),('A02','Ala A','ENFERMARIA'),
    ('A03','Ala A','ENFERMARIA'),('B01','UTI',  'UTI'),
    ('B02','UTI',  'UTI'),       ('C01','Ala C','SEMINTENSIVA'),
    ('D01','Ala D','ISOLAMENTO'),('E01','Cirúrgico','CIRURGICO');

INSERT INTO pacientes(cpf, nome_completo, data_nascimento, sexo, telefone, cidade, estado) VALUES
    ('12345678901','Ana Clara Souza Rodrigues','1985-03-12','F','(85)99111-2233','Fortaleza','CE'),
    ('23456789012','Bruno Henrique Martins',   '1992-07-25','M','(85)99222-3344','Fortaleza','CE'),
    ('34567890123','Carla Menezes Figueiredo', '1978-11-08','F','(85)99333-4455','Caucaia',  'CE'),
    ('45678901234','Diego Albuquerque Costa',  '2001-05-19','M','(85)99444-5566','Maracanaú','CE'),
    ('56789012345','Eliane Torres Barbosa',    '1965-09-30','F','(85)99555-6677','Fortaleza','CE');

-- Prontuário de 2025 (vai para partição prontuarios_2025 automaticamente)
INSERT INTO prontuarios(paciente_id, medico_id, data_consulta, queixa_principal,
                        hipotese_diag, cid10_primario, conduta)
SELECT p.paciente_id, m.medico_id, NOW() - INTERVAL '15 days',
       'Dor de cabeça intensa há 3 dias e tontura',
       'Hipertensão arterial sistêmica', 'I10',
       'Iniciar captopril 25mg 12/12h. Retorno em 30 dias.'
FROM pacientes p, medicos m
WHERE p.cpf = '12345678901' AND m.crm = 'CRM/CE-23456';

INSERT INTO prontuarios(paciente_id, medico_id, data_consulta, queixa_principal,
                        cid10_primario, conduta)
SELECT p.paciente_id, m.medico_id, NOW() - INTERVAL '7 days',
       'Dor lombar há 2 semanas após esforço físico',
       'M54.5','Ibuprofeno 600mg 8/8h por 5 dias + fisioterapia.'
FROM pacientes p, medicos m
WHERE p.cpf = '23456789012' AND m.crm = 'CRM/CE-34567';

-- Prescrição vinculada ao prontuário acima
INSERT INTO prescricoes(prontuario_id, data_prontuario, medicamento,
                        principio_ativo, dose, via, frequencia, duracao_dias)
SELECT pr.prontuario_id, pr.data_consulta,
       'Captopril','Captopril','25mg','oral','12/12 horas',30
FROM prontuarios pr JOIN pacientes p ON p.paciente_id = pr.paciente_id
WHERE p.cpf = '12345678901';

-- Internação ativa
INSERT INTO internacoes(paciente_id, leito_id, medico_resp_id, motivo, cid10_admissao, status)
SELECT p.paciente_id, l.leito_id, m.medico_id,
       'Pneumonia com hipoxemia, necessita oxigenoterapia','J18.9','ATIVO'
FROM pacientes p, leitos l, medicos m
WHERE p.cpf = '56789012345' AND l.numero = 'A01' AND m.crm = 'CRM/CE-12345';
