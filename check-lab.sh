#!/bin/bash
# =============================================================================
# TFG OpenRAN Lab - comprobacion del estado del laboratorio
# -----------------------------------------------------------------------------
# Recorre los cuatro bloques verificando que cada componente este realmente
# operativo, no solo que el contenedor exista. Al final hace un ping de extremo
# a extremo y, opcionalmente, lanza la xApp para ver metricas en vivo.
#
# Uso:
#   ./check-lab.sh              comprobacion completa (sin xApp)
#   ./check-lab.sh --xapp       ademas lanza la xApp con trafico de fondo
#   ./check-lab.sh --metrics    solo lanza la xApp (util si ya sabes que va bien)
#
# Codigo de salida: 0 si todo correcto, 1 si algo fallo.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; BLUE='\033[0;34m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; ((AVISOS++)); }
err()  { echo -e "${RED}[FALLO]${NC} $1"; ((FALLOS++)); }
info() { echo -e "${BLUE}      ${NC}$1"; }

FALLOS=0
AVISOS=0
RIC_DIR="./oran-sc-ric"
E2_NODE_DU="gnbd_999_070_00019b_0"

MODE="check"
case "${1:-}" in
    --xapp)    MODE="check+xapp" ;;
    --metrics) MODE="metrics" ;;
    "")        MODE="check" ;;
    -h|--help)
        echo "Uso: ./check-lab.sh [--xapp | --metrics]"
        echo "  (sin opciones)  comprobacion completa del laboratorio"
        echo "  --xapp          ademas lanza la xApp con trafico de fondo"
        echo "  --metrics       solo lanza la xApp"
        exit 0 ;;
    *)
        err "Opcion desconocida: $1"
        echo "Usa ./check-lab.sh --help"
        exit 1 ;;
esac

# ---------------------------------------------------------------------------
lanzar_xapp() {
    echo ""
    echo "=== Metricas en vivo (xApp KPM) ==="

    if [ ! -d "$RIC_DIR" ]; then
        err "No se encuentra $RIC_DIR"
        return 1
    fi

    info "Generando trafico de fondo en el terminal..."
    docker exec -d ue-srsue ping -i 0.2 10.45.0.1 2>/dev/null

    info "Nodo E2: $E2_NODE_DU"
    info "Pulsa Ctrl+C para salir. El trafico de fondo se detiene al salir."
    echo ""

    # Al salir, cortar el ping de fondo. Estas imagenes no traen pkill,
    # asi que se usa pidof.
    trap 'docker exec ue-srsue sh -c "kill \$(pidof ping) 2>/dev/null" 2>/dev/null; echo ""; info "Trafico de fondo detenido."' EXIT

    (cd "$RIC_DIR" && docker compose exec python_xapp_runner ./kpm_mon_xapp.py \
        --e2_node_id="$E2_NODE_DU" \
        --metrics=DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl \
        --kpm_report_style=5)
}

if [ "$MODE" = "metrics" ]; then
    lanzar_xapp
    exit 0
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== 1. Near-RT RIC ==="

if [ -d "$RIC_DIR" ]; then
    ric_up=$(cd "$RIC_DIR" && docker compose ps --services --filter status=running 2>/dev/null | wc -l)
    if [ "$ric_up" -eq 7 ]; then
        ok "Los 7 contenedores del RIC estan en marcha"
    else
        err "Solo $ric_up de 7 contenedores del RIC en marcha"
        info "cd $RIC_DIR && docker compose ps"
    fi

    if docker exec ric_dbaas redis-cli ping 2>/dev/null | grep -q PONG; then
        ok "Redis responde"
    else
        err "Redis no responde"
    fi

    if docker exec ric_e2term cat /proc/net/sctp/eps 2>/dev/null | grep -q 36421; then
        ok "e2term escuchando en SCTP 36421"
    else
        err "e2term no escucha en el puerto 36421"
    fi
else
    warn "No se encuentra $RIC_DIR, se omite el bloque del RIC"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== 2. Core 5G ==="

core_up=$(docker compose ps --services --filter status=running 2>/dev/null \
    | grep -c -E '^(mongodb|open5gs-)')
if [ "$core_up" -eq 12 ]; then
    ok "Los 12 contenedores del Core estan en marcha"
else
    err "Solo $core_up de 12 contenedores del Core en marcha"
    info "docker compose ps"
fi

for svc in open5gs-amf open5gs-smf open5gs-nrf mongodb; do
    if docker compose ps "$svc" 2>/dev/null | grep -q "healthy"; then
        ok "$svc healthy"
    else
        err "$svc no reporta healthy"
    fi
done

if docker exec core-upf ip addr show ogstun 2>/dev/null | grep -q "10.45.0.1"; then
    ok "Interfaz ogstun activa con 10.45.0.1"
else
    err "ogstun sin IP o inactiva (el trafico de datos fallara)"
    info "docker exec core-upf ip addr show ogstun"
fi

subs=$(docker exec core-mongodb mongosh open5gs --quiet \
    --eval 'db.subscribers.countDocuments()' 2>/dev/null | tr -d '[:space:]')
if [ "${subs:-0}" -ge 1 ]; then
    ok "Suscriptores dados de alta: $subs"
else
    err "No hay suscriptores en MongoDB (el terminal no podra registrarse)"
    info "ver config/open5gs/subscriber-test.md"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== 3. Red de acceso (OCUDU) ==="

for c in ran-cu-cp ran-cu-up ran-du; do
    if docker ps --format '{{.Names}}' | grep -q "^${c}$"; then
        ok "$c en marcha"
    else
        exit_code=$(docker inspect "$c" --format '{{.State.ExitCode}}' 2>/dev/null || echo "?")
        err "$c no esta en marcha (codigo de salida: $exit_code)"
        if [ "$exit_code" = "139" ]; then
            info "El codigo 139 es un fallo de segmento. Suele deberse a estado"
            info "residual en el RIC. Solucion: ./stop-lab.sh --clean && ./start-lab.sh"
        fi
    fi
done

if docker compose logs --since 30m ocudu-cu-up 2>/dev/null \
    | grep -q "E1: Connection to CU-CP completed"; then
    ok "Asociacion E1 establecida"
else
    warn "No se encuentra confirmacion reciente de la asociacion E1"
fi

if [ -f logs/ran/du/du.log ] && grep -q "Cell was activated" logs/ran/du/du.log 2>/dev/null; then
    ultima=$(grep "Cell was activated" logs/ran/du/du.log | tail -1 | cut -c1-19)
    ok "Celda activada (ultima vez: $ultima)"
else
    err "La celda de la DU no consta como activada"
    info "cat logs/ran/du/du.log"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== 4. Terminal (srsUE) ==="

if docker ps --format '{{.Names}}' | grep -q '^ue-srsue$'; then
    ok "Contenedor del terminal en marcha"

    if docker exec ue-srsue ip addr show tun_srsue >/dev/null 2>&1; then
        ip_ue=$(docker exec ue-srsue ip -4 addr show tun_srsue 2>/dev/null \
            | grep -oE 'inet [0-9.]+' | awk '{print $2}')
        ok "Sesion de datos activa, IP del terminal: $ip_ue"
    else
        err "La interfaz tun_srsue no existe: el terminal no tiene sesion"
        info "Solucion habitual (ver config/NOTAS-ARRANQUE.md):"
        info "  docker compose stop ue-simulado"
        info "  docker compose restart ocudu-du && sleep 70"
        info "  docker compose up -d ue-simulado"
    fi
else
    err "El contenedor del terminal no esta en marcha"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== 5. Telemetria E2 ==="

if [ -d "$RIC_DIR" ]; then
    estados=$(docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null)
    conectados=$(echo "$estados" | grep -o '"CONNECTED"' | wc -l)
    desconectados=$(echo "$estados" | grep -o '"DISCONNECTED"' | wc -l)

    if [ "$conectados" -eq 2 ]; then
        ok "Los 2 nodos E2 estan conectados (CU-CP y DU)"
    elif [ "$conectados" -gt 0 ]; then
        warn "Solo $conectados nodo(s) E2 conectado(s), $desconectados desconectado(s)"
    else
        err "Ningun nodo E2 conectado"
    fi

    echo ""
    echo "  \$ docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states"
    if [ -n "$estados" ]; then
        # Una linea por nodo, legible
        echo "$estados" \
            | sed 's/^\[//' \
            | sed 's/},{/}\n{/g' \
            | sed 's/{"inventoryName":"/  nodo: /' \
            | sed 's/","globalNbId".*"connectionStatus":"/  ->  /' \
            | sed 's/"}\]*//'
    else
        echo "  (sin respuesta del gestor E2)"
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== 6. Plano de usuario (extremo a extremo) ==="

ping_out=$(docker exec ue-srsue ping -c 4 -W 3 10.45.0.1 2>&1)
ping_rc=$?

if [ "$ping_rc" -eq 0 ]; then
    ok "Ping UE -> UPF correcto"
else
    err "El ping UE -> UPF no responde"
fi

echo ""
echo "  \$ docker exec ue-srsue ping -c 4 10.45.0.1"
echo "$ping_out" | sed 's/^/  /'

# Interfaces implicadas, para ver el camino completo
echo ""
echo "  Interfaces de datos en los dos extremos:"
ue_if=$(docker exec ue-srsue ip -4 addr show tun_srsue 2>/dev/null \
    | grep -oE 'inet [0-9./]+' | awk '{print $2}')
upf_if=$(docker exec core-upf ip -4 addr show ogstun 2>/dev/null \
    | grep -oE 'inet [0-9./]+' | awk '{print $2}')
echo "    UE  (tun_srsue) -> ${ue_if:-no existe}"
echo "    UPF (ogstun)    -> ${upf_if:-no existe}"

# ---------------------------------------------------------------------------
# Comprueba que la cadena E2 entrega datos reales, no solo que los nodos
# figuren conectados. No vuelca la salida de la xApp: solo confirma si llegan
# metricas o no.
#
# Estas imagenes no traen pkill, asi que se usa kill con pidof para detener
# los procesos dentro de los contenedores.
if [ "$FALLOS" -eq 0 ] && [ -d "$RIC_DIR" ] && [ "$MODE" != "metrics" ]; then
    echo ""
    echo "=== 7. Recepcion de metricas (xApp, ~15 s) ==="

    SALIDA_XAPP=$(mktemp)

    # Limpiar restos de ejecuciones anteriores
    (cd "$RIC_DIR" && docker compose restart python_xapp_runner >/dev/null 2>&1) || true
    docker exec ue-srsue sh -c "kill \$(pidof ping) 2>/dev/null" 2>/dev/null || true
    sleep 3

    docker exec -d ue-srsue ping -i 0.2 10.45.0.1 2>/dev/null
    sleep 2

    (cd "$RIC_DIR" && docker compose exec -T python_xapp_runner \
        ./kpm_mon_xapp.py --e2_node_id="$E2_NODE_DU" \
        --metrics=DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl \
        --kpm_report_style=5 > "$SALIDA_XAPP" 2>&1) &
    PID_XAPP=$!

    sleep 15

    # Detener la xApp reiniciando su contenedor, y el trafico de fondo
    (cd "$RIC_DIR" && docker compose restart python_xapp_runner >/dev/null 2>&1) || true
    kill "$PID_XAPP" 2>/dev/null || true
    wait "$PID_XAPP" 2>/dev/null || true
    docker exec ue-srsue sh -c "kill \$(pidof ping) 2>/dev/null" 2>/dev/null || true

    n_ind=$(grep -c "Metric:" "$SALIDA_XAPP" 2>/dev/null || echo 0)
    if [ "$n_ind" -gt 0 ]; then
        ok "La xApp recibe metricas correctamente ($n_ind lecturas en 15 s)"
    else
        warn "No se recibieron metricas en la muestra"
        info "Para verlas en vivo: ./check-lab.sh --metrics"
    fi

    rm -f "$SALIDA_XAPP"
fi

# ---------------------------------------------------------------------------
echo ""
echo "============================================"
if [ "$FALLOS" -eq 0 ] && [ "$AVISOS" -eq 0 ]; then
    echo -e "${GREEN}El laboratorio funciona correctamente.${NC}"
elif [ "$FALLOS" -eq 0 ]; then
    echo -e "${YELLOW}El laboratorio funciona, con $AVISOS aviso(s).${NC}"
else
    echo -e "${RED}$FALLOS comprobacion(es) fallida(s) y $AVISOS aviso(s).${NC}"
    echo ""
    echo "Si el fallo persiste tras reiniciar, prueba un arranque limpio:"
    echo "  ./stop-lab.sh --clean && ./start-lab.sh"
fi
echo "============================================"

if [ "$MODE" = "check+xapp" ] && [ "$FALLOS" -eq 0 ]; then
    lanzar_xapp
elif [ "$MODE" = "check+xapp" ]; then
    echo ""
    warn "No se lanza la xApp: hay comprobaciones fallidas."
fi

exit $([ "$FALLOS" -eq 0 ] && echo 0 || echo 1)
