#!/bin/bash
# =============================================================================
# TFG OpenRAN Lab - escenario MULTI-UE (experimental)
# -----------------------------------------------------------------------------
# Arranca el laboratorio en modo multi-UE siguiendo el orden que exige la
# documentacion oficial de srsRAN, verificando cada paso antes de continuar.
#
#   Core -> CU-CP -> CU-UP -> DU -> terminales -> broker
#
# El broker va el ULTIMO: los terminales no conectan hasta que existe el
# canal de bajada y subida.
#
# Uso:
#   ./start-multiue.sh            fase 1: un solo terminal (recomendado)
#   ./start-multiue.sh --ues 2    dos terminales
#   ./start-multiue.sh --ues 3    los tres
#   ./start-multiue.sh --con-ric  ademas levanta el Near-RT RIC
#
# Por defecto el RIC NO se levanta: durante la depuracion del camino ZMQ
# conviene reducir variables. Solo se crea su red, que la CU-CP y la DU
# necesitan para poder arrancar.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()  { echo -e "${RED}[FALLO]${NC} $1"; }
paso() { echo ""; echo "=== $1 ==="; }

# Lanza un comando de Compose y muestra el error si falla, en vez de ocultarlo
cup() {
    if ! $COMPOSE up -d "$@" >/tmp/compose_up.txt 2>&1; then
        err "Fallo al levantar: $*"
        sed 's/^/    /' /tmp/compose_up.txt | tail -5
        return 1
    fi
    return 0
}

COMPOSE="docker compose -f docker-compose.yaml -f docker-compose.multiue.yml"
RIC_DIR="./oran-sc-ric"
RIC_NET="oran-sc-ric_ric_network"
NUE=1
CON_RIC=0

while [ $# -gt 0 ]; do
    case "$1" in
        --ues)      NUE="${2:-1}"; shift 2 ;;
        --con-ric)  CON_RIC=1; shift ;;
        -h|--help)
            echo "Uso: ./start-multiue.sh [--ues 1|2|3] [--con-ric]"
            exit 0 ;;
        *) err "Opcion desconocida: $1"; exit 1 ;;
    esac
done

case "$NUE" in 1|2|3) ;; *) err "--ues debe ser 1, 2 o 3"; exit 1 ;; esac

# Sin estos ficheros, todos los comandos de Compose fallarian en silencio
for f in docker-compose.yaml docker-compose.multiue.yml config/ocudu/du_zmq_multiue.yml; do
    [ -f "$f" ] || { err "Falta el fichero $f"; exit 1; }
done
if ! $COMPOSE config --quiet 2>/tmp/compose_err.txt; then
    err "Los ficheros de Compose no son validos:"
    sed 's/^/    /' /tmp/compose_err.txt
    exit 1
fi

# Los terminales que se van a usar y sus puertos, para configurar el broker
case "$NUE" in
    1) UES="ue1";          ADDRS="10.0.0.30";                     TXP="2101";           RXP="2100";           GAINS="1.0" ;;
    2) UES="ue1 ue2";      ADDRS="10.0.0.30,10.0.0.31";           TXP="2101,2201";      RXP="2100,2200";      GAINS="1.0,1.0" ;;
    3) UES="ue1 ue2 ue3";  ADDRS="10.0.0.30,10.0.0.31,10.0.0.32"; TXP="2101,2201,2301"; RXP="2100,2200,2300"; GAINS="1.0,1.0,1.0" ;;
esac

echo ""
echo "############################################################"
echo "  Escenario MULTI-UE - $NUE terminal(es)"
echo "  Near-RT RIC: $([ "$CON_RIC" = "1" ] && echo "si" || echo "no (solo su red)")"
echo "############################################################"

# ---------------------------------------------------------------------------
paso "0. Prerrequisitos"

if ! lsmod | grep -q sctp; then
    sudo modprobe sctp || { err "No se pudo cargar sctp"; exit 1; }
fi
ok "Modulo sctp cargado"

# Limpieza: cualquier resto de pruebas anteriores
$COMPOSE stop ue-broker ue1 ue2 ue3 >/dev/null 2>&1
$COMPOSE rm -f ue-broker ue1 ue2 ue3 >/dev/null 2>&1
ok "Terminales y broker anteriores eliminados"

# La CU-CP y la DU necesitan que exista la red del RIC para poder crearse
if [ "$CON_RIC" = "1" ] && [ -d "$RIC_DIR" ]; then
    (cd "$RIC_DIR" && docker compose up -d >/dev/null 2>&1)
    sleep 20
    (cd "$RIC_DIR" && docker compose restart e2mgr >/dev/null 2>&1); sleep 15
    (cd "$RIC_DIR" && docker compose restart e2term >/dev/null 2>&1); sleep 15
    ok "Near-RT RIC levantado"
else
    if docker network ls --format '{{.Name}}' | grep -q "^${RIC_NET}$"; then
        ok "La red del RIC ya existe"
    else
        docker network create --subnet 10.0.2.0/24 "$RIC_NET" >/dev/null 2>&1 \
            && ok "Red del RIC creada (sin levantar el RIC)" \
            || err "No se pudo crear la red $RIC_NET"
    fi
fi

# ---------------------------------------------------------------------------
paso "1. Core 5G"
cup mongodb open5gs-nrf open5gs-ausf open5gs-udm open5gs-udr \
    open5gs-pcf open5gs-bsf open5gs-nssf open5gs-amf open5gs-upf open5gs-smf

for i in $(seq 1 20); do
    $COMPOSE ps open5gs-amf 2>/dev/null | grep -q healthy && break
    sleep 2
done
$COMPOSE ps open5gs-amf 2>/dev/null | grep -q healthy \
    && ok "Core sano (AMF healthy)" || err "El AMF no reporta healthy"

docker exec core-upf ip addr show ogstun 2>/dev/null | grep -q "10.45.0.1" \
    && ok "Interfaz ogstun activa" || err "ogstun sin IP"

subs=$(docker exec core-mongodb mongosh open5gs --quiet \
    --eval 'db.subscribers.countDocuments()' 2>/dev/null | tr -d '[:space:]')
[ "${subs:-0}" -ge "$NUE" ] \
    && ok "Suscriptores dados de alta: $subs" \
    || err "Solo hay ${subs:-0} suscriptores y hacen falta $NUE"

# ---------------------------------------------------------------------------
paso "2. CU-CP y CU-UP"
cup ocudu-cu-cp
for i in $(seq 1 20); do
    $COMPOSE ps ocudu-cu-cp 2>/dev/null | grep -q healthy && break
    sleep 2
done
$COMPOSE ps ocudu-cu-cp 2>/dev/null | grep -q healthy \
    && ok "CU-CP sana" || err "CU-CP no healthy"

sleep 10
cup ocudu-cu-up
sleep 10

inicio=$(docker inspect ran-cu-up --format '{{.State.StartedAt}}' 2>/dev/null)
if $COMPOSE logs --since "$inicio" ocudu-cu-up 2>/dev/null | grep -q "E1: Connection to CU-CP completed"; then
    ok "E1 establecido"
else
    err "No se confirmo la asociacion E1"
fi

# ---------------------------------------------------------------------------
paso "3. DU (10 MHz, apuntando al broker)"
cup --force-recreate ocudu-du
sleep 20

du_inicio=$(docker inspect ran-du --format '{{.State.StartedAt}}' 2>/dev/null | cut -c1-19)
if [ -z "$du_inicio" ]; then
    err "El contenedor de la DU no existe: no se puede comprobar la celda"
    echo "     Revisa: $COMPOSE logs ocudu-du"
    cell_ok=0
else
    cell_ok=0
    for i in $(seq 1 20); do
        if [ -f logs/ran/du/du.log ] && \
           awk -v ts="$du_inicio" '/Cell was activated/ { if (substr($0,1,19) >= ts) f=1 } END { exit !f }' \
               logs/ran/du/du.log 2>/dev/null; then
            cell_ok=1; break
        fi
        sleep 3
    done
    [ "$cell_ok" = "1" ] && ok "Celda activa" || err "La celda no se activo"
fi

docker exec ran-du ss -tln 2>/dev/null | grep -q ":2000" \
    && ok "DU escuchando en 2000 (bajada)" || err "DU no escucha en 2000"

# ---------------------------------------------------------------------------
paso "4. Terminales ($NUE)"
cup --force-recreate $UES
sleep 15

for u in $UES; do
    n="${u#ue}"
    docker exec "ue-srsue${n}" ss -tln 2>/dev/null | grep -q ":${n}101\|:2${n}01" \
        && ok "$u escuchando en su puerto de subida" \
        || warn "$u: no se confirmo el puerto de subida"
done
ok "Terminales arrancados (esperando al broker, es lo normal)"

# ---------------------------------------------------------------------------
paso "5. Broker (el ultimo)"
docker rm -f ue-broker >/dev/null 2>&1
docker run -d --name ue-broker \
    --network tfg-openran-lab_oran_5g_net --ip 10.0.0.35 \
    -e PYTHONUNBUFFERED=1 \
    -e DU_ADDR=10.0.0.24 -e DU_TX_PORT=2000 -e DU_RX_PORT=2001 \
    -e UE_ADDRS="$ADDRS" -e UE_TX_PORTS="$TXP" -e UE_RX_PORTS="$RXP" \
    -e UE_GAINS="$GAINS" -e SAMP_RATE=23.04e6 \
    local/ue-broker:latest >/dev/null 2>&1

sleep 10
docker ps --format '{{.Names}}' | grep -q '^ue-broker$' \
    && ok "Broker en marcha con $NUE terminal(es)" || err "El broker no arranco"

n_sock=$(docker exec ue-broker ss -tn 2>/dev/null | grep -cE "10.0.0.(24|30|31|32)")
esperados=$((2 + NUE * 2))
[ "$n_sock" -eq "$esperados" ] \
    && ok "Conexiones ZMQ: $n_sock de $esperados" \
    || warn "Conexiones ZMQ: $n_sock, se esperaban $esperados"

# ---------------------------------------------------------------------------
paso "6. Verificacion del registro (60 s)"
echo "Esperando a que los terminales se registren..."

for intento in $(seq 1 12); do
    listos=0
    for u in $UES; do
        n="${u#ue}"
        docker exec "ue-srsue${n}" ip -4 addr show tun_srsue >/dev/null 2>&1 && listos=$((listos+1))
    done
    [ "$listos" -eq "$NUE" ] && break
    sleep 5
done

echo ""
for u in $UES; do
    n="${u#ue}"
    ip=$(docker exec "ue-srsue${n}" ip -4 addr show tun_srsue 2>/dev/null \
        | grep -oE 'inet [0-9.]+' | awk '{print $2}')
    if [ -n "$ip" ]; then
        ok "$u -> sesion establecida, IP $ip"
    else
        err "$u -> sin sesion"
    fi
done

# ---------------------------------------------------------------------------
paso "7. Flujo de muestras"
du_tx1=$(docker exec ran-du cat /proc/net/dev 2>/dev/null | grep eth0 | awk '{print $10}')
sleep 10
du_tx2=$(docker exec ran-du cat /proc/net/dev 2>/dev/null | grep eth0 | awk '{print $10}')
delta=$(( ${du_tx2:-0} - ${du_tx1:-0} ))

if [ "$delta" -gt 1000000 ]; then
    ok "La DU transmite $((delta/1024/1024)) MB en 10 s: hay muestras circulando"
elif [ "$delta" -gt 10000 ]; then
    warn "La DU transmite $((delta/1024)) KB en 10 s: hay trafico pero poco para ser muestras"
else
    err "La DU transmite $delta bytes en 10 s: no circulan muestras"
    echo "     Revisa: grep -iE 'zmq' logs/ran/du/du.log | tail -5"
fi

# ---------------------------------------------------------------------------
paso "8. Plano de usuario"
for u in $UES; do
    n="${u#ue}"
    if docker exec "ue-srsue${n}" ping -c 2 -W 3 10.45.0.1 >/dev/null 2>&1; then
        ok "$u -> ping al UPF correcto"
    else
        err "$u -> el ping al UPF no responde"
    fi
done

echo ""
echo "############################################################"
echo "  Para parar:  docker rm -f ue-broker && ./stop-lab.sh"
echo "  Diagnostico: config/ocudu/NOTAS-MULTIUE.md"
echo "############################################################"
echo ""
