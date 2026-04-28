-- ============================================================
-- Oracle setup para Datastream CDC
-- Ejecutar como SYS / SYSDBA
-- ============================================================

-- 1) Habilitar ARCHIVELOG mode (solo si no está activo)
-- ALTER DATABASE ARCHIVELOG;
-- ALTER DATABASE OPEN;

-- 2) Habilitar supplemental logging a nivel de base de datos
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (PRIMARY KEY) COLUMNS;

-- 3) Crear usuario dedicado para Datastream
-- Usar password fuerte y rotarlo via Secret Manager en GCP
CREATE USER datastream_cdc IDENTIFIED BY "REEMPLAZAR_CON_PASSWORD_FUERTE"
    DEFAULT TABLESPACE USERS
    TEMPORARY TABLESPACE TEMP
    QUOTA UNLIMITED ON USERS;

-- 4) Privilegios necesarios para LogMiner CDC
GRANT CREATE SESSION TO datastream_cdc;
GRANT SELECT ON V_$DATABASE TO datastream_cdc;
GRANT SELECT ON V_$ARCHIVED_LOG TO datastream_cdc;
GRANT SELECT ON V_$LOGMNR_CONTENTS TO datastream_cdc;
GRANT SELECT ON V_$LOG TO datastream_cdc;
GRANT SELECT ON V_$LOGFILE TO datastream_cdc;
GRANT SELECT ON V_$THREAD TO datastream_cdc;
GRANT SELECT ON V_$INSTANCE TO datastream_cdc;
GRANT SELECT ON V_$STANDBY_LOG TO datastream_cdc;
GRANT SELECT ON V_$NLS_PARAMETERS TO datastream_cdc;
GRANT SELECT ON V_$DATABASE_INCARNATION TO datastream_cdc;
GRANT SELECT ON DBA_REGISTRY TO datastream_cdc;
GRANT SELECT ON DBA_TABLESPACES TO datastream_cdc;
GRANT SELECT ON DBA_OBJECTS TO datastream_cdc;
GRANT SELECT ON DBA_TABLES TO datastream_cdc;
GRANT SELECT ON DBA_TAB_COLUMNS TO datastream_cdc;
GRANT SELECT ON DBA_INDEXES TO datastream_cdc;
GRANT SELECT ON DBA_IND_COLUMNS TO datastream_cdc;
GRANT SELECT ON DBA_CONSTRAINTS TO datastream_cdc;
GRANT SELECT ON DBA_CONS_COLUMNS TO datastream_cdc;
GRANT SELECT ON ALL_INDEXES TO datastream_cdc;
GRANT SELECT ON ALL_OBJECTS TO datastream_cdc;
GRANT SELECT ON ALL_TABLES TO datastream_cdc;
GRANT SELECT ON ALL_TAB_COLUMNS TO datastream_cdc;
GRANT SELECT ON ALL_INDEXES TO datastream_cdc;
GRANT SELECT ON ALL_IND_COLUMNS TO datastream_cdc;

-- Privilegios LogMiner
GRANT EXECUTE ON DBMS_LOGMNR TO datastream_cdc;
GRANT EXECUTE ON DBMS_LOGMNR_D TO datastream_cdc;
GRANT EXECUTE_CATALOG_ROLE TO datastream_cdc;
GRANT LOGMINING TO datastream_cdc;

-- Para Oracle 19c+ con la API mejorada
GRANT SELECT ANY TRANSACTION TO datastream_cdc;
GRANT SELECT ANY DICTIONARY TO datastream_cdc;
GRANT FLASHBACK ANY TABLE TO datastream_cdc;

-- 5) Para cada schema/tabla a replicar, habilitar supplemental logging completo
--    Reemplaza <SCHEMA>.<TABLE> con tus tablas reales
ALTER TABLE APP_SCHEMA.CUSTOMERS ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
ALTER TABLE APP_SCHEMA.ORDERS ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
ALTER TABLE APP_SCHEMA.ORDER_ITEMS ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

-- 6) Otorgar SELECT al usuario CDC sobre las tablas a replicar
GRANT SELECT ON APP_SCHEMA.CUSTOMERS TO datastream_cdc;
GRANT SELECT ON APP_SCHEMA.ORDERS TO datastream_cdc;
GRANT SELECT ON APP_SCHEMA.ORDER_ITEMS TO datastream_cdc;

-- 7) Validación: verifica que todo esté correcto
-- Si alguna de estas devuelve 'NO' o vacío, el CDC no funcionará

-- Verificar archivelog
SELECT log_mode FROM v$database;
-- Esperado: ARCHIVELOG

-- Verificar supplemental logging
SELECT supplemental_log_data_min, supplemental_log_data_pk, supplemental_log_data_all
FROM v$database;
-- Esperado: YES, YES, (al menos uno)

-- Verificar supplemental logging por tabla
SELECT owner, table_name, log_group_type
FROM dba_log_groups
WHERE owner = 'APP_SCHEMA';
-- Esperado: una fila por tabla con ALL COLUMN LOG GROUP

-- Verificar privilegios del usuario
SELECT * FROM dba_role_privs WHERE grantee = 'DATASTREAM_CDC';
SELECT * FROM dba_sys_privs WHERE grantee = 'DATASTREAM_CDC';
