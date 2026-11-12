#!/usr/bin/env bash
set -Eeuo pipefail

export PATH="/usr/local/bin:/Users/reddragon/.docker/bin:${PATH}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "${ROOT_DIR}/.aws/credentials" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${ROOT_DIR}/.aws/credentials"
  export AWS_CONFIG_FILE="${ROOT_DIR}/.aws/config"
fi

echo "=================================================================="
echo " 1. Estado de los Pods en Amazon EKS"
echo "=================================================================="
kubectl get pods -o wide

echo ""
echo "=================================================================="
echo " 2. Contenido de /usr/src/app/logs/clickstream.log (Volumen emptyDir)"
echo "=================================================================="
for POD in $(kubectl get pods -l app=backend -o jsonpath='{.items[*].metadata.name}'); do
  echo "--- Pod: ${POD} (Contenedor: backend-api) ---"
  kubectl exec "${POD}" -c backend-api -- sh -c 'if [ -s /usr/src/app/logs/clickstream.log ]; then tail -n 15 /usr/src/app/logs/clickstream.log; else echo "(Archivo clickstream.log creado y vacío — navega en la web para generar eventos)"; ls -la /usr/src/app/logs/; fi'
  echo ""
done

echo "=================================================================="
echo " 3. Logs del Contenedor Sidecar (clickstream-sidecar -> CloudWatch)"
echo "=================================================================="
if [[ "${1:-}" == "-f" ]]; then
  echo "Escuchando eventos de clickstream en TIEMPO REAL (Ctrl+C para salir)..."
  kubectl logs -l app=backend -c clickstream-sidecar -f --prefix=true --tail=20
else
  for POD in $(kubectl get pods -l app=backend -o jsonpath='{.items[*].metadata.name}'); do
    echo "--- Pod: ${POD} (Contenedor: clickstream-sidecar) ---"
    kubectl logs "${POD}" -c clickstream-sidecar --tail=20
    echo ""
  done
  echo "Tip: Ejecuta './scripts/ver_logs.sh -f' para seguir los logs en tiempo real."
fi

