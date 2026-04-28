#!/usr/bin/env bash
# Despliegue end-to-end del stack dual-sink CDC
# Uso: ./deploy.sh [init|deploy|verify|destroy]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ID="${PROJECT_ID:?Set PROJECT_ID env var}"
REGION="${REGION:-us-central1}"

# ============================================================
COMMAND="${1:-deploy}"

case "${COMMAND}" in
  init)
    echo "=== 1. Crear bucket para Terraform state ==="
    gsutil mb -p "${PROJECT_ID}" -l "${REGION}" \
        "gs://${PROJECT_ID}-tfstate" 2>/dev/null || true
    gsutil versioning set on "gs://${PROJECT_ID}-tfstate"

    echo "=== 2. Crear secrets ==="
    # Oracle password
    if ! gcloud secrets describe oracle-cdc-password --project="${PROJECT_ID}" 2>/dev/null; then
        echo -n "Enter Oracle CDC password: "
        read -rs ORACLE_PASS
        echo
        echo -n "${ORACLE_PASS}" | gcloud secrets create oracle-cdc-password \
            --data-file=- --project="${PROJECT_ID}"
    fi

    # AlloyDB password
    if ! gcloud secrets describe alloydb-postgres-password --project="${PROJECT_ID}" 2>/dev/null; then
        echo -n "Enter AlloyDB postgres password: "
        read -rs ALLOY_PASS
        echo
        echo -n "${ALLOY_PASS}" | gcloud secrets create alloydb-postgres-password \
            --data-file=- --project="${PROJECT_ID}"
    fi

    echo "=== Init complete. Edit terraform/terraform.tfvars and run './deploy.sh deploy' ==="
    ;;

  build-image)
    echo "=== Building Dataflow image ==="
    cd "${SCRIPT_DIR}/dataflow/serving"
    PROJECT_ID="${PROJECT_ID}" REGION="${REGION}" ./build_and_deploy.sh
    ;;

  deploy)
    echo "=== 1. Build Dataflow image ==="
    cd "${SCRIPT_DIR}/dataflow/serving"
    PROJECT_ID="${PROJECT_ID}" REGION="${REGION}" ./build_and_deploy.sh

    echo "=== 2. Terraform apply ==="
    cd "${SCRIPT_DIR}/terraform"
    terraform init -backend-config="bucket=${PROJECT_ID}-tfstate"
    terraform apply -auto-approve

    echo "=== 3. Apply AlloyDB schema ==="
    ALLOYDB_IP=$(terraform output -raw alloydb_primary_ip)
    ALLOYDB_PASS=$(gcloud secrets versions access latest \
        --secret=alloydb-postgres-password --project="${PROJECT_ID}")

    PGPASSWORD="${ALLOYDB_PASS}" psql \
        "postgresql://postgres@${ALLOYDB_IP}:5432/postgres?sslmode=require" \
        -f "${SCRIPT_DIR}/alloydb/schema.sql"

    # Setear password para usuarios creados en schema.sql
    PGPASSWORD="${ALLOYDB_PASS}" psql \
        "postgresql://postgres@${ALLOYDB_IP}:5432/postgres?sslmode=require" \
        -c "ALTER ROLE app_reader WITH LOGIN PASSWORD '${ALLOYDB_PASS}';" \
        -c "ALTER ROLE dataflow_writer WITH LOGIN PASSWORD '${ALLOYDB_PASS}';"

    echo "=== 4. Apply BigQuery schemas ==="
    sed "s/\${PROJECT_ID}/${PROJECT_ID}/g; s/\${REGION}/${REGION}/g" \
        "${SCRIPT_DIR}/bigquery/setup.sql" \
        | bq query --use_legacy_sql=false --project_id="${PROJECT_ID}"

    echo "=== 5. Deploy reconciliation service ==="
    cd "${SCRIPT_DIR}/reconciliation"
    gcloud run deploy "${PROJECT_ID}-reconciliation" \
        --source . \
        --region="${REGION}" \
        --no-allow-unauthenticated \
        --vpc-connector="prod-cdc-vpc-connector" \
        --vpc-egress=all-traffic \
        --set-env-vars="PROJECT_ID=${PROJECT_ID},ORACLE_HOST=${ORACLE_HOST:-},ORACLE_SERVICE_NAME=${ORACLE_SERVICE:-ORCL}" \
        --set-secrets="ORACLE_PASSWORD_SECRET=oracle-cdc-password:latest,ALLOYDB_PASSWORD_SECRET=alloydb-postgres-password:latest"

    echo "=== 6. Schedule reconciliation hourly ==="
    RECON_URL=$(gcloud run services describe "${PROJECT_ID}-reconciliation" \
        --region="${REGION}" --format='value(status.url)')

    gcloud scheduler jobs create http reconciliation-hourly \
        --location="${REGION}" \
        --schedule="0 * * * *" \
        --uri="${RECON_URL}/reconcile" \
        --http-method=POST \
        --oidc-service-account-email="reconciliation-invoker@${PROJECT_ID}.iam.gserviceaccount.com" \
        2>/dev/null || echo "Scheduler job ya existe"

    echo "=== Deploy complete ==="
    ;;

  verify)
    echo "=== Verificando estado del stack ==="

    cd "${SCRIPT_DIR}/terraform"

    echo "--- Datastream stream ---"
    STREAM_ID=$(terraform output -raw datastream_stream_id 2>/dev/null || echo "")
    [ -n "${STREAM_ID}" ] && gcloud datastream streams describe "${STREAM_ID}" --location="${REGION}"

    echo "--- AlloyDB ---"
    gcloud alloydb instances list --region="${REGION}"

    echo "--- Dataflow jobs ---"
    gcloud dataflow jobs list --region="${REGION}" --status=active

    echo "--- DLQ message counts ---"
    gcloud pubsub subscriptions describe prod-cdc-dlq-serving-inspect \
        --format='value(name,messageRetentionDuration)' 2>/dev/null || true

    echo "--- Recent reconciliation runs ---"
    gcloud logging read "resource.type=cloud_run_revision \
        AND resource.labels.service_name=${PROJECT_ID}-reconciliation \
        AND severity>=WARNING" \
        --limit=5 --format=json
    ;;

  destroy)
    echo "WARNING: Esto va a destruir todo el stack."
    read -p "Estás seguro? (yes/N): " CONFIRM
    [ "${CONFIRM}" != "yes" ] && exit 1

    cd "${SCRIPT_DIR}/terraform"
    terraform destroy -auto-approve
    ;;

  *)
    echo "Uso: $0 [init|build-image|deploy|verify|destroy]"
    exit 1
    ;;
esac
