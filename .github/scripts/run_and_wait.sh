#!/usr/bin/env bash
# Dispara um workflow_dispatch em outro repositório (via PAT, já que o
# GITHUB_TOKEN padrão não pode disparar workflows fora deste repo) e aguarda
# sua conclusão, falhando (exit != 0) se a run não terminar com sucesso.
#
# Uso: run_and_wait.sh <repo> <workflow-file> <aws_access_key_id> <aws_secret_access_key> <aws_session_token>
set -euo pipefail

REPO_NAME="$1"
WORKFLOW_FILE="$2"
AWS_ACCESS_KEY_ID="$3"
AWS_SECRET_ACCESS_KEY="$4"
AWS_SESSION_TOKEN="$5"

FULL_REPO="${ORG}/${REPO_NAME}"

echo "Disparando ${WORKFLOW_FILE} em ${FULL_REPO}..."
DISPATCHED_AT=$(date -u +%Y-%m-%dT%H:%M:%S)

gh workflow run "$WORKFLOW_FILE" \
  --repo "$FULL_REPO" \
  -f aws_access_key_id="$AWS_ACCESS_KEY_ID" \
  -f aws_secret_access_key="$AWS_SECRET_ACCESS_KEY" \
  -f aws_session_token="$AWS_SESSION_TOKEN"

# `gh workflow run` não retorna o run id diretamente — precisamos localizar a
# run que acabamos de criar entre as mais recentes (criada após o dispatch).
RUN_ID=""
for _ in $(seq 1 15); do
  sleep 4
  RUN_ID=$(gh run list \
    --repo "$FULL_REPO" \
    --workflow "$WORKFLOW_FILE" \
    --limit 5 \
    --json databaseId,createdAt \
    --jq "[.[] | select(.createdAt >= \"${DISPATCHED_AT}\")] | sort_by(.createdAt) | .[0].databaseId // empty")

  if [ -n "$RUN_ID" ]; then
    break
  fi
  echo "Aguardando a run aparecer em ${FULL_REPO}..."
done

if [ -z "$RUN_ID" ]; then
  echo "::error::Não foi possível localizar a run disparada em ${FULL_REPO}/${WORKFLOW_FILE}."
  exit 1
fi

echo "Aguardando conclusão do job principal da run ${RUN_ID} em ${FULL_REPO}..."

# Aguardamos só o PRIMEIRO job da run (o único sem `needs:`, ou seja, o
# trabalho real de deploy). Alguns workflows (ex: api/cd_deploy.yml) têm um
# 2º job de autodestruição de segurança que dorme horas antes de destruir —
# `gh run watch` esperaria a run inteira, incluindo esse sleep, travando a
# orquestração sem necessidade.
while true; do
  JOB_INFO=$(gh run view "$RUN_ID" --repo "$FULL_REPO" --json jobs --jq '.jobs[0] | {name, status, conclusion}')
  JOB_STATUS=$(echo "$JOB_INFO" | jq -r '.status')

  if [ "$JOB_STATUS" = "completed" ]; then
    JOB_NAME=$(echo "$JOB_INFO" | jq -r '.name')
    JOB_CONCLUSION=$(echo "$JOB_INFO" | jq -r '.conclusion')
    echo "Job '${JOB_NAME}' concluído com conclusion=${JOB_CONCLUSION}."

    if [ "$JOB_CONCLUSION" != "success" ]; then
      echo "::error::Job principal de ${FULL_REPO} falhou (conclusion=${JOB_CONCLUSION})."
      exit 1
    fi

    # Os serviços têm um 2º job que se autodestrói após 2h. No deploy orquestrado quem decide
    # a hora de destruir é o deploy_all.yml (por inatividade), então cancelamos essa espera.
    if [ "$WORKFLOW_FILE" = "cd_deploy.yml" ]; then
      gh run cancel "$RUN_ID" --repo "$FULL_REPO" >/dev/null 2>&1 || true
    fi
    break
  fi

  sleep 15
done
