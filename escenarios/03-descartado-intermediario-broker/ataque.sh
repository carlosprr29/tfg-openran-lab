#!/bin/bash
# =============================================================================
# Escenario 03 - Intermediario ZMQ (MitM de aplicacion)
# -----------------------------------------------------------------------------
# Inserta un proxy malicioso en el canal ZMQ de UE3. A diferencia del ARP
# spoofing (escenario 02), que sobre ZMQ solo consigue cortar, este se mete en
# el propio canal de la aplicacion -el punto de insercion correcto en este
# laboratorio- y SI intercepta de forma transparente.
#
#   Normal:  broker <==ZMQ==> UE3
#   Con MitM: broker <==ZMQ==> [PROXY intercepta+retarda] <==ZMQ==> UE3
#
# El proxy intercepta, retarda y reenvia. UE3 no lo nota salvo por el retardo.
# Esa es la firma del intermediario: mas retardo SIN perdida de caudal, lo que
# lo distingue de un DoS o una congestion.
#
# NOTA DE DISENO: el emparejamiento ZMQ lo fija la configuracion del broker al
# arrancar, no la capa de red. Por eso el intermediario se inserta al levantar
# el escenario, haciendo que el broker apunte al proxy para UE3. UE1 y UE2
# siguen directos. El "antes/despues" se logra con el retardo: el proxy arranca
# con 0 ms (transparente) y en la fase central sube a DELAY_MS.
#
# Uso:
#   ./escenarios/03-intermediario/ataque.sh           180 s, 80 ms
#   ./escenarios/03-intermediario/ataque.sh 180 150   retardo mayor
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

VERDE='\033[0;32m'; AMAR='\033[1;33m'; ROJO='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${VERDE}[OK]${NC} $1"; }
avis() { echo -e "${AMAR}[AVISO]${NC} $1"; }
err()  { echo -e "${ROJO}[FALLO]${NC} $1"; }

DUR="${1:-180}"
RETARDO_MS="${2:-80}"
C="docker compose -f docker-compose.yaml -f docker-compose.multiue.yml"
UES="ue-srsue ue-srsue2 ue-srsue3"
METRICAS="DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl,DRB.RlcDelayUl,DRB.RlcSduTransmittedVolumeDL,DRB.RlcSduTransmittedVolumeUL"

PROXY="lab-mitm"
PROXY_IP="10.0.0.40"
UE3_IP="10.0.0.32"
BROKER_IP="10.0.0.35"
RED="tfg-openran-lab_oran_5g_net"

CAUDAL=("100K" "100K" "50K")
INICIO=$((DUR / 3))
FIN=$((2 * DUR / 3))

SESION="data/escenarios/03-intermediario-$(date +%Y%m%d-%H%M)"
SESION_ABS="$(pwd)/$SESION"
E2_NODO=""

echo ""
echo "=========================================================="
echo "  Escenario 03 - Intermediario ZMQ (MitM de aplicacion)"
echo "  Victima: UE3 ($UE3_IP)  Proxy: $PROXY_IP"
echo "  Duracion: ${DUR}s | Retardo en fase de ataque: ${RETARDO_MS} ms"
echo "=========================================================="

echo ""
docker ps --format '{{.Names}}' | grep -q '^ran-du$' || {
    err "Laboratorio base no levantado. Ejecuta: ./start-lab.sh"; exit 1; }
ok "Laboratorio base levantado"
mkdir -p "$SESION"

# --- Construir la imagen del proxy si no existe -----------------------------
if ! docker images --format '{{.Repository}}' | grep -q '^local/mitm$'; then
    echo ">> Construyendo la imagen del intermediario"
    docker build -t local/mitm:latest escenarios/03-intermediario/mitm/ >/dev/null 2>&1 \
        && ok "Imagen del proxy construida" \
        || { err "No se pudo construir la imagen del proxy"; exit 1; }
fi

# --- Limpiar ----------------------------------------------------------------
$C stop ue-simulado ue2 ue3 >/dev/null 2>&1
docker rm -f ue-broker "$PROXY" >/dev/null 2>&1
sleep 3
sudo rm -f logs/ue/*.pcap logs/ran/du/*.pcap logs/ran/cu_cp/*.pcap logs/ue/iperf_*.log 2>/dev/null
(cd oran-sc-ric && docker compose exec -T python_xapp_runner rm -f /tmp/metricas_sesion.csv >/dev/null 2>&1)

# --- DU y celda (como lab-multiue) ------------------------------------------
echo ""
echo ">> Reiniciando la DU"
$C restart ocudu-du >/dev/null 2>&1
sleep 70
grep -i "Cell was activated" logs/ran/du/du.log | tail -1 >/dev/null && ok "Celda activa"

# --- Arrancar el proxy ANTES que el broker ----------------------------------
# El proxy arranca con retardo 0: transparente. Se sube luego, en la fase de
# ataque, reiniciando el contenedor con el nuevo DELAY_MS.
echo ">> Insertando el intermediario en el canal de UE3 (transparente)"
docker run -d --name "$PROXY" --network "$RED" --ip "$PROXY_IP" \
    -e PYTHONUNBUFFERED=1 \
    -e UE_ADDR="$UE3_IP" -e UE_TX_PORT=2301 -e UE_RX_PORT=2300 \
    -e BROKER_ADDR="$BROKER_IP" -e DELAY_MS=0 \
    -e CAPTURA=/tmp/intercept.csv \
    local/mitm:latest >/dev/null 2>&1
sleep 3
docker ps --format '{{.Names}}' | grep -q "^${PROXY}$" \
    && ok "Intermediario en marcha (retardo 0, transparente)" \
    || { err "El proxy no arranco"; exit 1; }

# --- Arrancar los terminales ------------------------------------------------
echo ">> Arrancando los tres terminales"
$C up -d ue-simulado ue2 ue3 >/dev/null 2>&1
sleep 20

# --- Arrancar el broker: UE3 apunta al PROXY, no a si mismo -----------------
echo ">> Arrancando el broker (UE3 a traves del proxy)"
docker run -d --name ue-broker \
    --network "$RED" --ip 10.0.0.35 \
    -e PYTHONUNBUFFERED=1 \
    -e DU_ADDR=10.0.0.24 -e DU_TX_PORT=2000 -e DU_RX_PORT=2001 \
    -e UE_ADDRS=10.0.0.30,10.0.0.31,${PROXY_IP} \
    -e UE_TX_PORTS=2001,2201,2301 \
    -e UE_RX_PORTS=2100,2200,2300 \
    -e UE_GAINS=1.0,0.316,0.1 -e SAMP_RATE=23.04e6 \
    local/ue-broker:latest >/dev/null 2>&1
sleep 60

# --- Comprobar sesiones -----------------------------------------------------
listos=0
for c in $UES; do docker exec "$c" ip -4 addr show tun_srsue >/dev/null 2>&1 && listos=$((listos+1)); done
[ "$listos" -eq 3 ] && ok "Los tres terminales con sesion (UE3 via proxy)" \
    || avis "Solo $listos de 3 terminales con sesion"

# --- Servidor de trafico + E2 -----------------------------------------------
docker exec core-upf sh -c 'pkill iperf3 2>/dev/null; exit 0'; sleep 1
for p in 5201 5202 5203; do docker exec -d core-upf iperf3 -s -B 10.45.0.1 -p $p; done
sleep 2

e2c() { docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null | grep -o '"connectionStatus":"CONNECTED"' | wc -l; }
METRICAS_OK=0
if docker ps --format '{{.Names}}' | grep -q '^ric_e2mgr$'; then
    for intento in 1 2 3; do
        [ "$(e2c)" -ge 2 ] && break
        avis "E2 desconectado ($intento/3); reiniciando e2term y DU"
        (cd oran-sc-ric && docker compose restart e2term >/dev/null 2>&1); sleep 30
        $C restart ocudu-du >/dev/null 2>&1; sleep 80
    done
    if [ "$(e2c)" -ge 2 ]; then
        E2_NODO=$(docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null | grep -oE '"inventoryName":"gnbd_[^"]*"' | head -1 | sed 's/.*:"//;s/"//')
        cp xapp_ai/kpm_csv_xapp.py oran-sc-ric/xApps/python/ 2>/dev/null
        chmod +x oran-sc-ric/xApps/python/kpm_csv_xapp.py 2>/dev/null
        ok "Nodo E2: $E2_NODO"; METRICAS_OK=1
    else
        avis "Sin E2: sesion sin metricas"
    fi
fi
if [ "$METRICAS_OK" = "1" ]; then
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner ./kpm_csv_xapp.py \
        --e2_node_id="$E2_NODO" --metrics="$METRICAS" --kpm_report_style=5 \
        --output=/tmp/metricas_sesion.csv --duration=$((DUR + 10)) \
        > "$SESION_ABS/xapp.log" 2>&1) &
    XAPP_PID=$!; sleep 3
fi

# --- Trafico + fases del retardo --------------------------------------------
echo ""
echo ">> FASE 1: normal, proxy transparente ($INICIO s)"
i=0
for c in $UES; do
    p=$((5201 + i))
    docker exec -d "$c" sh -c "iperf3 -c 10.45.0.1 -p $p -b ${CAUDAL[$i]} -t $DUR -i 5 --logfile /tmp/iperf_${c}.log"
    i=$((i+1))
done
sleep "$INICIO"

echo ">> FASE 2: ATAQUE - el proxy sube el retardo a ${RETARDO_MS} ms"
# Reiniciar el proxy con retardo. El reinicio rehace el emparejamiento ZMQ de
# UE3 (que va por el proxy); los otros dos no se tocan.
docker rm -f "$PROXY" >/dev/null 2>&1
docker run -d --name "$PROXY" --network "$RED" --ip "$PROXY_IP" \
    -e PYTHONUNBUFFERED=1 \
    -e UE_ADDR="$UE3_IP" -e UE_TX_PORT=2301 -e UE_RX_PORT=2300 \
    -e BROKER_ADDR="$BROKER_IP" -e DELAY_MS="$RETARDO_MS" \
    -e CAPTURA=/tmp/intercept.csv \
    local/mitm:latest >/dev/null 2>&1
ok "Retardo del intermediario a ${RETARDO_MS} ms"
sleep $((FIN - INICIO))

echo ">> FASE 3: proxy vuelve a transparente (0 ms)"
docker rm -f "$PROXY" >/dev/null 2>&1
docker run -d --name "$PROXY" --network "$RED" --ip "$PROXY_IP" \
    -e PYTHONUNBUFFERED=1 \
    -e UE_ADDR="$UE3_IP" -e UE_TX_PORT=2301 -e UE_RX_PORT=2300 \
    -e BROKER_ADDR="$BROKER_IP" -e DELAY_MS=0 \
    local/mitm:latest >/dev/null 2>&1
sleep $((DUR - FIN + 5))
ok "Trafico completado"

# --- Recoger ----------------------------------------------------------------
for c in $UES; do docker exec "$c" cat "/tmp/iperf_${c}.log" > "$SESION/iperf_${c}.txt" 2>/dev/null; done
docker exec "$PROXY" cat /tmp/intercept.csv > "$SESION/interceptado_resumen.csv" 2>/dev/null \
    && ok "Resumen de lo interceptado guardado"
if [ "$METRICAS_OK" = "1" ]; then
    for _ in $(seq 1 40); do
        kill -0 "$XAPP_PID" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$XAPP_PID" 2>/dev/null; then
        avis "La xApp no cerro; forzando"
        (cd oran-sc-ric && docker compose exec -T python_xapp_runner \
            pkill -f kpm_csv_xapp >/dev/null 2>&1) || true
        kill "$XAPP_PID" 2>/dev/null || true
    fi
    wait "$XAPP_PID" 2>/dev/null || true
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner cat /tmp/metricas_sesion.csv 2>/dev/null) > "$SESION_ABS/metricas.csv"
    n=$(($(wc -l < "$SESION/metricas.csv") - 1))
    [ "$n" -gt 0 ] && ok "Metricas recogidas: $n filas" || avis "Metricas vacias"
fi

echo ""
echo ">> Parando terminales y proxy"
$C stop ue-simulado ue2 ue3 >/dev/null 2>&1
docker rm -f "$PROXY" >/dev/null 2>&1
sleep 8
cp logs/ue/*.pcap logs/ran/du/du_mac.pcap "$SESION/" 2>/dev/null

cat > "$SESION/README.md" << FICHA
# Sesion: Intermediario ZMQ (MitM de aplicacion)

**Fecha:** $(date '+%Y-%m-%d %H:%M')  **Duracion:** ${DUR}s
**Retardo en fase de ataque:** ${RETARDO_MS} ms

## Ataque

Un proxy malicioso se inserta en el canal ZMQ de UE3: el broker conecta con el
proxy ($PROXY_IP) creyendo que es UE3. El proxy intercepta, retarda y reenvia.
UE1 y UE2 van directos.

El proxy arranca transparente (0 ms); en el tramo central sube el retardo a
${RETARDO_MS} ms; luego vuelve a 0.

| Fase | Intervalo | Retardo del proxy |
|---|---|---|
| Normal | 0 - ${INICIO}s | 0 ms (transparente) |
| Ataque | ${INICIO} - ${FIN}s | ${RETARDO_MS} ms |
| Normal | ${FIN} - ${DUR}s | 0 ms |

## Que buscar

- **Retardo de UE3**: sube en el tramo central, por el salto del proxy.
- **Caudal de UE3**: se mantiene (el proxy reenvia todo). Mas retardo SIN menos
  caudal es la firma del intermediario, distinta del DoS.
- **interceptado_resumen.csv**: cuanto trafico vio el atacante.

## Comparar con la linea base

\`\`\`bash
./graficas.py $SESION
./graficas.py --comparar data/capturas/20261024-1758-holgado $SESION
\`\`\`
FICHA

echo ""
echo "=========================================================="
ok "Sesion guardada en $SESION"
echo "  Graficas: ./graficas.py $SESION"
echo "  Volver al base: ./lab-multiue.sh"
echo "=========================================================="
echo ""
