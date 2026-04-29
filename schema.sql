-- ============================================================
-- AlloyDB schema para hot tier de CDC desde Oracle
-- Diseñado para lookups por PK con latencia < 10ms
-- Este solo es un archivo ejemplo no representa el producto final
-- ============================================================

-- Habilitar columnar engine para queries analíticas que igual lleguen aquí
-- (si las queries son 100% point lookups, puedes omitir esto)
CREATE EXTENSION IF NOT EXISTS google_columnar_engine;

-- Habilitar pg_stat_statements para observar queries lentas
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- ============================================================
-- Tabla: customers
-- Lookups esperados: por customer_id (PK), por email, por phone
-- ============================================================
CREATE TABLE customers (
    customer_id     BIGINT PRIMARY KEY,
    email           VARCHAR(255) NOT NULL,
    phone           VARCHAR(20),
    first_name      VARCHAR(100),
    last_name       VARCHAR(100),
    country_code    CHAR(2),
    created_at      TIMESTAMPTZ NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL,
    -- Metadata CDC: usado por el job de Dataflow para idempotencia
    cdc_scn         BIGINT NOT NULL,           -- Oracle System Change Number
    cdc_op_ts       TIMESTAMPTZ NOT NULL,      -- timestamp del evento en Oracle
    cdc_received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),  -- timestamp en AlloyDB
    is_deleted      BOOLEAN NOT NULL DEFAULT FALSE
);

-- Índices secundarios para lookups por columnas no-PK
-- B-tree estándar — para igualdad y rango
CREATE INDEX idx_customers_email ON customers (email) WHERE NOT is_deleted;
CREATE INDEX idx_customers_phone ON customers (phone) WHERE NOT is_deleted AND phone IS NOT NULL;

-- Índice parcial: si la mayoría de lookups son customers activos, esto reduce el índice
CREATE INDEX idx_customers_country_active ON customers (country_code, customer_id)
    WHERE NOT is_deleted;

-- ============================================================
-- Tabla: orders
-- Lookups esperados: por order_id (PK), por customer_id (FK lookup)
-- ============================================================
CREATE TABLE orders (
    order_id        BIGINT PRIMARY KEY,
    customer_id     BIGINT NOT NULL,
    order_status    VARCHAR(20) NOT NULL,
    total_amount    NUMERIC(12,2) NOT NULL,
    currency        CHAR(3) NOT NULL,
    placed_at       TIMESTAMPTZ NOT NULL,
    updated_at      TIMESTAMPTZ NOT NULL,
    cdc_scn         BIGINT NOT NULL,
    cdc_op_ts       TIMESTAMPTZ NOT NULL,
    cdc_received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_deleted      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_orders_customer ON orders (customer_id, placed_at DESC) WHERE NOT is_deleted;
CREATE INDEX idx_orders_status ON orders (order_status) WHERE order_status IN ('PENDING','PROCESSING');

-- ============================================================
-- Tabla: order_items
-- ============================================================
CREATE TABLE order_items (
    item_id         BIGINT PRIMARY KEY,
    order_id        BIGINT NOT NULL,
    product_id      BIGINT NOT NULL,
    quantity        INTEGER NOT NULL,
    unit_price      NUMERIC(12,2) NOT NULL,
    cdc_scn         BIGINT NOT NULL,
    cdc_op_ts       TIMESTAMPTZ NOT NULL,
    cdc_received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    is_deleted      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE INDEX idx_items_order ON order_items (order_id) WHERE NOT is_deleted;

-- ============================================================
-- Tabla auxiliar: cdc_lag_metrics
-- El job de Dataflow inserta su propio heartbeat para medir lag
-- ============================================================
CREATE TABLE cdc_lag_metrics (
    table_name      VARCHAR(100) NOT NULL,
    cdc_op_ts       TIMESTAMPTZ NOT NULL,
    received_at     TIMESTAMPTZ NOT NULL,
    lag_ms          BIGINT GENERATED ALWAYS AS (
                        EXTRACT(EPOCH FROM (received_at - cdc_op_ts)) * 1000
                    ) STORED,
    PRIMARY KEY (table_name, cdc_op_ts)
);

CREATE INDEX idx_lag_recent ON cdc_lag_metrics (received_at DESC);

-- ============================================================
-- Función auxiliar: upsert idempotente con guard de timestamp
-- El job de Dataflow llama esta función vía prepared statement
-- ============================================================
CREATE OR REPLACE FUNCTION upsert_customer(
    p_customer_id   BIGINT,
    p_email         VARCHAR,
    p_phone         VARCHAR,
    p_first_name    VARCHAR,
    p_last_name     VARCHAR,
    p_country_code  CHAR,
    p_created_at    TIMESTAMPTZ,
    p_updated_at    TIMESTAMPTZ,
    p_cdc_scn       BIGINT,
    p_cdc_op_ts     TIMESTAMPTZ,
    p_is_deleted    BOOLEAN
) RETURNS VOID AS $$
BEGIN
    INSERT INTO customers (
        customer_id, email, phone, first_name, last_name, country_code,
        created_at, updated_at, cdc_scn, cdc_op_ts, is_deleted
    ) VALUES (
        p_customer_id, p_email, p_phone, p_first_name, p_last_name, p_country_code,
        p_created_at, p_updated_at, p_cdc_scn, p_cdc_op_ts, p_is_deleted
    )
    ON CONFLICT (customer_id) DO UPDATE SET
        email           = EXCLUDED.email,
        phone           = EXCLUDED.phone,
        first_name      = EXCLUDED.first_name,
        last_name       = EXCLUDED.last_name,
        country_code    = EXCLUDED.country_code,
        updated_at      = EXCLUDED.updated_at,
        cdc_scn         = EXCLUDED.cdc_scn,
        cdc_op_ts       = EXCLUDED.cdc_op_ts,
        is_deleted      = EXCLUDED.is_deleted,
        cdc_received_at = NOW()
    -- El guard: solo actualizamos si el evento entrante es más nuevo que el actual
    -- Esto previene que eventos desordenados sobrescriban estado más reciente
    WHERE customers.cdc_scn < EXCLUDED.cdc_scn;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- Permisos: usuario de aplicación con solo SELECT
-- ============================================================
CREATE ROLE app_reader;
GRANT CONNECT ON DATABASE postgres TO app_reader;
GRANT USAGE ON SCHEMA public TO app_reader;
GRANT SELECT ON customers, orders, order_items TO app_reader;

-- Usuario para el job de Dataflow (escribe)
CREATE ROLE dataflow_writer;
GRANT CONNECT ON DATABASE postgres TO dataflow_writer;
GRANT USAGE ON SCHEMA public TO dataflow_writer;
GRANT INSERT, UPDATE ON customers, orders, order_items, cdc_lag_metrics TO dataflow_writer;
GRANT EXECUTE ON FUNCTION upsert_customer TO dataflow_writer;

-- ============================================================
-- Tuning para latencia baja
-- ============================================================
-- Estos parámetros se setean a nivel de instancia en Terraform via flags,
-- pero los documentamos aquí para referencia:
--
-- shared_buffers              = 25% de RAM
-- effective_cache_size        = 75% de RAM
-- work_mem                    = 64MB (por operación de sort/hash)
-- maintenance_work_mem        = 2GB (para CREATE INDEX)
-- random_page_cost            = 1.1 (asumiendo SSD)
-- effective_io_concurrency    = 200 (SSD permite alto paralelismo)
-- max_parallel_workers        = N° de vCPUs
-- max_parallel_workers_per_gather = N°/2
--
-- Para hot tier con lookups por PK, lo más impactante es:
-- - shared_buffers grande (caché en memoria)
-- - random_page_cost = 1.1 (planner usa índices más agresivamente)
-- - connection pooling externo (PgBouncer en transaction mode)
