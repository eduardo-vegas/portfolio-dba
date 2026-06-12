# 🚀 Performance — Sistema Hospitalar (PostgreSQL 16)

## Parâmetros Críticos do postgresql.conf

| Parâmetro | Windows | Linux | Justificativa |
|-----------|---------|-------|---------------|
| `shared_buffers` | 25% da RAM | 25% da RAM | Cache de páginas; acima de 8 GB sem ganho adicional |
| `effective_cache_size` | 50% da RAM | 75% da RAM | Linux usa mais memória para page cache do SO |
| `work_mem` | 16–64 MB | 64–256 MB | Hash joins e sorts; multiplica por conexões simultâneas |
| `maintenance_work_mem` | 256 MB | 1–2 GB | VACUUM, CREATE INDEX, carga de partições |
| `wal_buffers` | 16–32 MB | 64 MB | Buffer WAL antes de flush ao disco |
| `max_connections` | 100 | 200–500 | Windows: overhead maior por processo (~5 MB/proc) |
| `checkpoint_completion_target` | 0.9 | 0.9 | Distribui escrita do checkpoint, evita pico de I/O |
| `random_page_cost` | 2.0–4.0 | 1.1 (SSD) | Planner: SSDs têm custo quase igual ao sequencial |

## Windows

```ini
# postgresql.conf — servidor 16 GB RAM, SSD NVMe (Windows)
shared_buffers                = 4GB
effective_cache_size          = 8GB
work_mem                      = 64MB
maintenance_work_mem          = 512MB
wal_buffers                   = 32MB
max_connections               = 100
random_page_cost              = 2.0
checkpoint_completion_target  = 0.9
```

**Dicas específicas Windows:**
- Formatar volume de dados NTFS com **allocation unit 64 KB** (não o padrão 4 KB)
- Excluir diretório de dados do PostgreSQL do antivírus em tempo real
- Usar **pgBouncer** para pooling (cada conexão PG no Windows = 1 processo ~5 MB)
- Separar WAL em volume diferente dos datafiles (reduz contenção de I/O)

## Linux (Ubuntu 22.04 / Rocky Linux)

```ini
# postgresql.conf — mesmo hardware no Linux
shared_buffers                = 4GB
effective_cache_size          = 12GB
work_mem                      = 128MB
maintenance_work_mem          = 1GB
wal_buffers                   = 64MB
max_connections               = 200
random_page_cost              = 1.1
huge_pages                    = try   # ativa Huge Pages se disponível no kernel
checkpoint_completion_target  = 0.9
```

```bash
# Huge Pages: shared_buffers 4 GB → 4096 MB / 2 MB por huge page = 2048
echo 'vm.nr_hugepages = 2048' >> /etc/sysctl.conf
sysctl -p

# XFS com noatime é recomendado para volumes de dados PostgreSQL
# /etc/fstab: /dev/nvme0n1p1  /var/lib/postgresql  xfs  defaults,noatime  0 2

# I/O scheduler NVMe: none (sem fila extra, hardware já gerencia)
echo none > /sys/block/nvme0n1/queue/scheduler
```

## Manutenção das Partições

```sql
-- Criar partição do próximo ano (executar em dezembro)
CREATE TABLE hospital.prontuarios_2027 PARTITION OF hospital.prontuarios
    FOR VALUES FROM ('2027-01-01') TO ('2028-01-01');

-- VACUUM ANALYZE após carga expressiva
VACUUM (ANALYZE, VERBOSE) hospital.prontuarios_2025;

-- Verificar tamanho por partição
SELECT tablename,
       pg_size_pretty(pg_total_relation_size('hospital.'||tablename)) AS tamanho
FROM pg_tables
WHERE tablename LIKE 'prontuarios_%'
ORDER BY pg_total_relation_size('hospital.'||tablename) DESC;
```

## Verificar Partition Pruning

```sql
-- O planner deve acessar APENAS prontuarios_2025 nesta query:
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM hospital.prontuarios
WHERE data_consulta BETWEEN '2025-01-01' AND '2025-12-31'
  AND paciente_id = 'UUID-AQUI';
-- Esperado: "Seq Scan on prontuarios_2025" sem varrer outras partições
```
