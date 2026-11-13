#!/usr/bin/env bash
# Segura o job até o ambiente ficar ocioso ou atingir o teto de tempo — o que vier primeiro.
# "Uso" = conexões recebidas pelos Load Balancers públicos dos serviços (métrica RequestCount
# do CloudWatch; os health checks do próprio ELB não entram nessa conta).
#
# Variáveis: DEPLOY_STARTED_AT (epoch do início do deploy), IDLE_MINUTES, MAX_MINUTES,
# IDLE_THRESHOLD (até quantas conexões na janela ainda contam como ocioso — tolera o ruído
# de scanners da internet batendo nos endereços públicos), CHECK_INTERVAL (segundos).
set -euo pipefail

IDLE_MINUTES="${IDLE_MINUTES:-30}"
MAX_MINUTES="${MAX_MINUTES:-180}"
IDLE_THRESHOLD="${IDLE_THRESHOLD:-10}"
CHECK_INTERVAL="${CHECK_INTERVAL:-600}"
WAIT_STARTED_AT=$(date +%s)
DEPLOY_STARTED_AT="${DEPLOY_STARTED_AT:-$WAIT_STARTED_AT}"

iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

connections_in_window() {
  local now=$1 total=0 lb sum
  for lb in $(aws elb describe-load-balancers --query 'LoadBalancerDescriptions[].LoadBalancerName' --output text); do
    sum=$(aws cloudwatch get-metric-statistics --namespace AWS/ELB --metric-name RequestCount \
      --dimensions "Name=LoadBalancerName,Value=$lb" \
      --start-time "$(iso $((now - IDLE_MINUTES * 60)))" --end-time "$(iso "$now")" \
      --period $((IDLE_MINUTES * 60)) --statistics Sum \
      --query 'sum(Datapoints[].Sum)' --output text)
    [ "$sum" = "None" ] && sum=0
    total=$((total + ${sum%.*}))
  done
  echo "$total"
}

while true; do
  sleep "$CHECK_INTERVAL"
  NOW=$(date +%s)

  if [ $((NOW - DEPLOY_STARTED_AT)) -ge $((MAX_MINUTES * 60)) ]; then
    echo "Teto de ${MAX_MINUTES} min desde o início do deploy atingido. Destruindo o ambiente."
    exit 0
  fi

  # A janela de ociosidade só vale depois que o ambiente ficou disponível por IDLE_MINUTES.
  if [ $((NOW - WAIT_STARTED_AT)) -lt $((IDLE_MINUTES * 60)) ]; then
    echo "Ambiente disponível há menos de ${IDLE_MINUTES} min. Aguardando..."
    continue
  fi

  # Se a consulta falhar (ex.: credenciais vencidas), o `set -e` encerra com erro e o destroy
  # não roda às cegas.
  TOTAL=$(connections_in_window "$NOW")
  echo "Conexões nos últimos ${IDLE_MINUTES} min: ${TOTAL} (ocioso se <= ${IDLE_THRESHOLD})"
  if [ "$TOTAL" -le "$IDLE_THRESHOLD" ]; then
    echo "Ambiente ocioso. Destruindo."
    exit 0
  fi
done
