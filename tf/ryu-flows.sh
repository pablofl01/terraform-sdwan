#!/usr/bin/env bash
set -euo pipefail

################  Resolver cliente K8s ########################
if command -v kubectl >/dev/null 2>&1; then
  KCTL="kubectl"
elif command -v microk8s >/dev/null 2>&1; then
  KCTL="microk8s kubectl"
else
  echo "  No se encontró ni kubectl ni microk8s" >&2; exit 1
fi
echo "  Cliente K8s = $KCTL"

################  Configuración ###############################
JSON_DIR="../json"     # carpeta con los .json
NAMESPACE="rdsv"                               # namespace de los Pods
COMMON_JSONS=(
  from-cpe.json
  to-cpe.json
  broadcast-from-axs.json
  from-mpls.json
  to-voip-gw.json
)

################  Verificaciones previas ######################
[[ -d "$JSON_DIR" ]] || { echo "  Carpeta $JSON_DIR no existe"; exit 1; }
command -v curl >/dev/null || { echo "  curl no encontrado"; exit 1; }

################  Detectar sites sdedgeN ######################
mapfile -t EDGE_DIRS < <(find "$JSON_DIR" -maxdepth 1 -type d -name 'sdedge*' | sort)
[[ ${#EDGE_DIRS[@]} -gt 0 ]] || { echo "  No se encontraron sdedge*"; exit 1; }

echo "🔎 Sites detectados: ${EDGE_DIRS[*]##*/}"

################  Bucle principal por site ####################
for EDGE_DIR in "${EDGE_DIRS[@]}"; do
  NETNUM=$(basename "$EDGE_DIR" | sed 's/^sdedge//')   # 1, 2, …
  SITE="site${NETNUM}"                                 # site1, site2, …
  APP_LABEL="vnf-wan-${SITE}"                          # label del Pod
  SVC="vnf-wan-${SITE}-service"                        # Service (8080)
  echo -e "\n═══════════════  Cargando reglas en ${SITE}  ═══════════════"

  ######## 1) Esperar a que el Pod Ryu esté Ready ############
  echo "...Esperando Pod Ryu (${APP_LABEL})..."
  $KCTL wait --for=condition=ready pod -l "k8s-app=${APP_LABEL}" \
      -n "$NAMESPACE" --timeout=120s

  ######## 2) Acceso por NodePort #########
  NODEPORT="$($KCTL get svc -n "$NAMESPACE" "$SVC" \
    -o jsonpath='{.spec.ports[?(@.name=="ryu-rest")].nodePort}')"
  [[ -n "$NODEPORT" ]] || { echo "  No se pudo obtener NodePort de $SVC"; exit 1; }

  # Construir URL base
  RYU_ROOT="http://localhost:${NODEPORT}/stats"
  FLOW_URL="${RYU_ROOT}/flowentry/add"
  echo "🎯 Endpoint REST (NodePort) = ${FLOW_URL}"

  ######## 3) Esperar datapath 1 en Ryu ######################
  for i in {1..12}; do
    curl -sf "${RYU_ROOT}/switches" | grep -q '\[1\]' && break
    echo "   Esperando datapath… ($i/12)"; sleep 2
  done

  ######## 4) Construir lista de JSON a enviar ###############
  FILES=()
  for f in "${COMMON_JSONS[@]}"; do FILES+=("${JSON_DIR}/${f}"); done
  SPEC_JSON="${EDGE_DIR}/to-voip.json"
  [[ -f "$SPEC_JSON" ]] && FILES+=("$SPEC_JSON") \
    || echo "  $(basename "$SPEC_JSON") no encontrado, se omite"

  ######## 5) Enviar los JSON uno a uno ######################
  for FILE in "${FILES[@]}"; do
    [[ -f "$FILE" ]] || { echo "  $FILE no existe, se salta"; continue; }
    echo "➜ $(basename "$FILE")"
    code=$(curl -s -o /dev/null -w '%{http_code}' \
              -H 'Content-Type: application/json' \
              -X POST -d @"$FILE" "$FLOW_URL")
    if [[ "$code" != 200 ]]; then
      echo "  Error HTTP $code al enviar $(basename "$FILE"); abortando"; exit 1
    fi
  done

  echo "  ✅ Reglas cargadas en ${SITE}"

  ######## 6) Abrir FlowManager GUI ############
  GUI_URL="http://localhost:${NODEPORT}/home/index.html"
  echo "🌐 Abriendo FlowManager GUI en ${GUI_URL}"
  firefox "$GUI_URL" &
done

echo -e "\n  Todas las reglas SDN se han inyectado con éxito"

exit 0
