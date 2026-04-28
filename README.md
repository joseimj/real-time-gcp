# Dual-sink CDC: Oracle → BigQuery + AlloyDB

Stack de despliegue end-to-end para el patrón dual-sink con CDC desde Oracle.

## Arquitectura

```
Oracle OLTP
    │ (redo logs vía LogMiner)
    ▼
Datastream
    │
    ▼
Pub/Sub (ordering key = PK)
    ├──────────────┬──────────────┐
    ▼              ▼              ▼
Dataflow      Dataflow         DLQ
serving       analytics      (errores)
    │              │
    ▼              ▼
AlloyDB        BigQuery
(hot tier)     (analítica)
```

## Latencias objetivo

| Métrica                                  | Objetivo  | Cómo se logra                          |
|------------------------------------------|-----------|----------------------------------------|
| Lectura app → AlloyDB                    | < 10 ms   | VPC privado, índices, connection pool  |
| Propagación Oracle → AlloyDB             | 1-3 s     | Streaming Dataflow, batches pequeños   |
| Propagación Oracle → BigQuery            | 5-30 s    | Storage Write API con CDC              |
| Lookup percentil 99 desde la app         | < 50 ms   | Read pool nodes en misma región        |

> Si necesitas propagación CDC < 1 segundo, este stack no es suficiente.
> Cambia Datastream por Debezium+Kafka o usa Oracle GoldenGate.

## Estructura del repo

```
.
├── terraform/             # IaC para todo el stack en GCP
├── oracle/                # SQL para preparar Oracle (usuario CDC, supplemental logging)
├── alloydb/               # Schema y configuración del hot tier
├── bigquery/              # Schemas y configuración del data warehouse
├── dataflow/serving/      # Pipeline Pub/Sub → AlloyDB (Python Beam)
├── reconciliation/        # Job de Cloud Run que valida consistencia
└── deploy.sh              # Orquestación del despliegue
```

## Pre-requisitos

- Proyecto GCP con billing habilitado
- Oracle 12c+ con archivelog mode y supplemental logging
- Conectividad de red Oracle ↔ GCP (Cloud Interconnect, VPN, o reverse proxy)
- `gcloud`, `terraform >= 1.5`, `python >= 3.10` instalados localmente

## Despliegue

```bash
# 1. Configura tu entorno
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# edita terraform.tfvars con tus valores

# 2. Prepara Oracle (correr como SYSDBA)
sqlplus sys/password@oracle as sysdba @oracle/setup.sql

# 3. Despliega infraestructura
cd terraform
terraform init
terraform plan
terraform apply

# 4. Aplica schemas
psql "$(terraform output -raw alloydb_connection)" -f ../alloydb/schema.sql
bq query --use_legacy_sql=false < ../bigquery/setup.sql

# 5. Construye y despliega el job de Dataflow
cd ../dataflow/serving
./build_and_deploy.sh

# 6. Despliega el reconciliador
cd ../../reconciliation
gcloud run deploy reconciliation --source .

# 7. Verifica
../deploy.sh verify
```

## Configuración crítica para baja latencia

Las decisiones que más impactan la latencia están en cuatro lugares:

1. **`terraform/networking.tf`**: VPC peering vs PSC, región única para todos los componentes
2. **`terraform/alloydb.tf`**: machine type, read pool nodes, columnar engine
3. **`dataflow/serving/main.py`**: triggering interval, batch size, connection pooling
4. **`alloydb/schema.sql`**: índices, tipo de columnas, particionamiento

Si bajas alguno de estos, la latencia sube. Lee los comentarios antes de cambiar.

## Operación

- **Métricas**: `monitoring.tf` define dashboards para lag y throughput
- **Alertas**: lag de cada sink, errores de Dataflow, conexiones AlloyDB
- **DLQ**: `gcloud pubsub subscriptions pull dlq-sub` para inspeccionar fallas
- **Reconciliación**: corre cada hora vía Cloud Scheduler, alerta en divergencias > 0.01%

## Costo estimado mensual (5 TB/mes de CDC)

| Componente                  | Costo aproximado |
|-----------------------------|------------------|
| Datastream                  | $1,500           |
| Pub/Sub                     | $200             |
| Dataflow (2 jobs streaming) | $1,200           |
| AlloyDB (4 vCPU + read pool)| $1,800           |
| BigQuery storage + queries  | $400-2,000       |
| Egress / networking         | $100             |
| **Total**                   | **$5,200-6,800** |

Costos crecen aproximadamente lineales con volumen de CDC.

