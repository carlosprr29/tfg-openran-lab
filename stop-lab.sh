#!/bin/bash
# =============================================================================
# TFG OpenRAN Lab - parada del laboratorio
# -----------------------------------------------------------------------------
# El ORDEN IMPORTA: primero el laboratorio (libera la red del RIC) y despues el
# RIC. Al reves, Docker avisa con "Network ... Resource is still in use", la red
# no se elimina y queda en un estado que provoca "Connection timed out" en el
# siguiente arranque.
#
# Modos:
#   ./stop-lab.sh              para los contenedores (los datos se conservan)
#   ./stop-lab.sh --clean      ademas borra el estado del RIC (Redis)
#   ./stop-lab.sh --purge      ademas borra MongoDB (se pierde el suscriptor)
#
# Cuando usar cada uno:
#   normal  -> uso diario, cuando terminas de trabajar
#   --clean -> tras un fallo del E2, un cierre brusco o si la CU-CP crashea
#   --purge -> para empezar totalmente de cero (hay que dar de alta el
#              suscriptor otra vez, ver config/open5gs/subscriber-test.md)
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

MODE="normal"
case "${1:-}" in
    --clean) MODE="clean" ;;
    --purge) MODE="purge" ;;
    "")      MODE="normal" ;;
    -h|--help)
        echo "Uso: ./stop-lab.sh [--clean | --purge]"
        echo "  (sin opciones)  para los contenedores, conserva los datos"
        echo "  --clean         ademas borra el estado del RIC (Redis)"
        echo "  --purge         ademas borra MongoDB (se pierde el suscriptor)"
        exit 0 ;;
    *)
        err "Opcion desconocida: $1"
        echo "Usa ./stop-lab.sh --help"
        exit 1 ;;
esac

RIC_DIR="./oran-sc-ric"

if [ "$MODE" = "purge" ]; then
    warn "Modo --purge: se borrara MongoDB y habra que dar de alta el suscriptor otra vez."
    read -r -p "¿Continuar? (escribe 'si' para confirmar): " respuesta
    if [ "$respuesta" != "si" ]; then
        echo "Cancelado."
        exit 0
    fi
fi

echo ""
echo "=== 1. Parando el laboratorio (bloques 1-3) ==="
if [ "$MODE" = "purge" ]; then
    docker compose down -v
    ok "Contenedores y volumenes eliminados (MongoDB incluido)"
else
    docker compose down
    ok "Contenedores eliminados (el volumen mongo_data se conserva)"
fi

echo ""
echo "=== 2. Parando el Near-RT RIC ==="
if [ -d "$RIC_DIR" ]; then
    if [ "$MODE" = "normal" ]; then
        (cd "$RIC_DIR" && docker compose down)
        ok "RIC parado (conserva el estado en Redis)"
    else
        (cd "$RIC_DIR" && docker compose down -v)
        ok "RIC parado y estado de Redis eliminado"
    fi
else
    warn "No se encuentra $RIC_DIR, se omite"
fi

echo ""
echo "=== 3. Comprobaciones ==="

# La red del RIC debe haber desaparecido. Si sigue ahi, algo quedo conectado.
if docker network ls --format '{{.Name}}' | grep -q "^oran-sc-ric_ric_network$"; then
    warn "La red del RIC sigue existiendo: algo continua conectado a ella."
    echo "    Contenedores conectados:"
    docker network inspect oran-sc-ric_ric_network \
        --format '{{range .Containers}}      - {{.Name}}{{"\n"}}{{end}}' 2>/dev/null
    echo "    Para forzar su eliminacion:"
    echo "      docker network rm oran-sc-ric_ric_network"
else
    ok "Red del RIC eliminada correctamente"
fi

# No debe quedar ningun contenedor del laboratorio en marcha
restantes=$(docker ps --format '{{.Names}}' \
    | grep -E '^(core-|ran-|ue-|ric_|python_xapp_runner)' | wc -l)
if [ "$restantes" -eq 0 ]; then
    ok "No queda ningun contenedor del laboratorio en ejecucion"
else
    warn "Siguen en marcha $restantes contenedores:"
    docker ps --format '      - {{.Names}}' \
        | grep -E 'core-|ran-|ue-|ric_|python_xapp_runner'
fi

echo ""
case "$MODE" in
    normal)
        echo "Laboratorio parado. Los datos se conservan (suscriptor, cuenta WebUI,"
        echo "estado del RIC). Para volver a arrancarlo: ./start-lab.sh"
        echo ""
        echo "Si al arrancar la CU-CP falla con codigo 139 o el E2 no conecta,"
        echo "vuelve a parar con: ./stop-lab.sh --clean"
        ;;
    clean)
        echo "Laboratorio parado y estado del RIC eliminado. El suscriptor de"
        echo "MongoDB se conserva. Para arrancar: ./start-lab.sh"
        ;;
    purge)
        echo "Laboratorio parado y todos los datos eliminados."
        echo "Antes de usarlo de nuevo hay que dar de alta el suscriptor:"
        echo "  ver config/open5gs/subscriber-test.md"
        ;;
esac
echo ""
