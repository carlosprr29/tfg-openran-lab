#!/bin/bash
# =============================================================================
# TFG OpenRAN Lab - arranque del escenario MULTI-UE
# -----------------------------------------------------------------------------
# Levanta el laboratorio completo con varios terminales simultaneos, siguiendo
# la secuencia verificada en config/ocudu/MULTIUE-RECETA.md:
#
#   RIC -> Core -> CU-CP -> CU-UP -> DU -> terminales -> broker
#
# El broker va SIEMPRE el ultimo: los terminales no pueden conectar hasta que
# existe el camino de bajada y subida.
#
# Uso:
#   ./start-multiue.sh              los tres terminales (por defecto)
#   ./start-multiue.sh --ues 1      solo uno
#   ./start-multiue.sh --ues 2      dos
#   ./start-multiue.sh --sin-ric    omite el Near-RT RIC (solo crea su red)
#
# Notas importantes:
#   - La DU usa la configuracion del compose base (20 MHz, 23.04). El fichero
#     de superposicion NO debe sobreescribirla: hacerlo provocaba que se
#     recreara a mitad de arranque.
#   - El numero de terminales arrancados y el configurado en el broker tienen
#     que coincidir: el broker suma las subidas y espera a todas sus entradas.
#   - Las interfaces se localizan por IP, nunca por nombre (Docker no garantiza
#     el orden de eth0/eth1/eth2 entre recreaciones del contenedor).
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()  { echo -e "${RED}[FALLO]${NC} $1"; }
paso() { echo ""; echo "=== $1 ==="; }

COMPOSE="docker compose -f docker-compose.yaml -f docker-compose.multiue.yml"
RIC_DIR="./oran-sc-ric"
RIC_NET="oran-sc-ric_ric_network"
NUE=3
CON_RIC=1
FALLOS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --ues)      NUE="${2:-3}"; shift 2 ;;
        --sin-ric)  CON_RIC=0; shift ;;
        -h|--help)
            echo "Uso: ./start-multiue.sh [--ues 1|2|3] [--sin-ric]"
            exit 0 ;;
        *) err "Opcion desconocida: $1"; exit 1 ;;
    esac
done

case "$NUE" in 1|2|3) ;; *) err "--ues debe ser 1, 2 o 3"; exit 1 ;; esac

for f in docker-compose.yaml docker-compose.multiue.yml; do
    [ -f "$f" ] || { err "Falta el fichero $f"; exit 1; }
done
if ! $COMPOSE config --quiet 2>/tmp/compose_err.txt; then
    err "Los ficheros de Compose no son validos:"; sed 's/^/    /' /tmp/compose_err.txt; exit 1
fi

# Terminales y parametros del broker segun el numero elegido
case "$NUE" in
    1) UES="ue-simulado";              CONT="ue-srsue"
       ADDRS="10.0.0.30";                     TXP="2001";           RXP="2100";           GAINS="1.0" ;;
    2) UES="ue-simulado ue2";          CONT="ue-srsue ue-srsue2"
       ADDRS="10.0.0.30,10.0.0.31";           TXP="2001,2201";      RXP="2100,2200";      GAINS="1.0,1.0" ;;
    3) UES="ue-simulado ue2 ue3";      CONT="ue-srsue ue-srsue2 ue-srsue3"
       ADDRS="10.0.0.30,10.0.0.31,10.0.0.32"; TXP="2001,2201,2301"; RXP="2100,2200,2300"; GAINS="1.0,1.0,1.0" ;;
esac

echo ""
echo "############################################################"
echo "  Laboratorio MULTI-UE - $NUE terminal(es)"
echo "############################################################"

# ---------------------------------------------------------------------------
paso "1. Prerrequisitos"

if ! lsmod | grep -q sctp; then
    sudo modprobe sctp || { err "No se pudo cargar sctp"; exit 1; }
fi
ok "Modulo sctp cargado"

docker rm -f ue-broker >/dev/null 2>&1
$COMPOSE stop ue-simulado ue2 ue3 >/dev/null 2>&1
$COMPOSE rm -f ue-simulado ue2 ue3 >/dev/null 2>&1
ok "Terminales y broker anteriores eliminados"

# ---------------------------------------------------------------------------
paso "2. Near-RT RIC"

if [ "$CON_RIC" = "1" ] && [ -d "$RIC_DIR" ]; then
    (cd "$RIC_DIR" && docker compose up -d >/dev/null 2>&1)
    sleep 20
    # e2mgr suele perder la carrera con Redis; e2term debe reiniciarse despues
    if ! (cd "$RIC_DIR" && docker compose logs --since 2m e2mgr 2>/dev/null) | grep -q "redis: got"; then
        (cd "$RIC_DIR" && docker compose restart e2mgr >/dev/null 2>&1); sleep 20
    fi
    (cd "$RIC_DIR" && docker compose logs --since 2m e2mgr 2>/dev/null) | grep -q "redis: got" \
        && ok "e2mgr conectado a Redis" || { err "e2mgr no conecto a Redis"; ((FALLOS++)); }

    (cd "$RIC_DIR" && docker compose restart e2term >/dev/null 2>&1); sleep 20
    ok "e2term reiniciado con e2mgr operativo"
else
    if docker network ls --format '{{.Name}}' | grep -q "^${RIC_NET}$"; then
        ok "La red del RIC ya existe"
    else
        docker network create --subnet 10.0.2.0/24 "$RIC_NET" >/dev/null 2>&1 \
            && ok "Red del RIC creada (sin levantar el RIC)" \
            || { err "No se pudo crear la red $RIC_NET"; ((FALLOS++)); }
    fi
fi

# ---------------------------------------------------------------------------
paso "3. Core 5G"
$COMPOSE up -d mongodb open5gs-nrf open5gs-ausf open5gs-udm open5gs-udr \
    open5gs-pcf open5gs-bsf open5gs-nssf open5gs-amf open5gs-upf open5gs-smf \
    open5gs-webui >/dev/null 2>&1

for i in $(seq 1 20); do
    $COMPOSE ps open5gs-amf 2>/dev/null | grep -q healthy && break
    sleep 2
done
$COMPOSE ps open5gs-amf 2>/dev/null | grep -q healthy \
    && ok "Core sano (AMF healthy)" || { err "El AMF no reporta healthy"; ((FALLOS++)); }

docker exec core-upf ip addr show ogstun 2>/dev/null | grep -q "10.45.0.1" \
    && ok "Interfaz ogstun activa" || { err "ogstun sin IP"; ((FALLOS++)); }

subs=$(docker exec core-mongodb mongosh open5gs --quiet \
    --eval 'db.subscribers.countDocuments()' 2>/dev/null | tr -d '[:space:]')
if [ "${subs:-0}" -ge "$NUE" ]; then
    ok "Suscriptores dados de alta: $subs"
else
    err "Solo hay ${subs:-0} suscriptores y hacen falta $NUE"; ((FALLOS++))
fi

# ---------------------------------------------------------------------------
paso "4. CU-CP y CU-UP"
$COMPOSE up -d ocudu-cu-cp >/dev/null 2>&1
for i in $(seq 1 20); do
    $COMPOSE ps ocudu-cu-cp 2>/dev/null | grep -q healthy && break
    sleep 2
done
$COMPOSE ps ocudu-cu-cp 2>/dev/null | grep -q healthy \
    && ok "CU-CP sana" || { err "CU-CP no healthy"; ((FALLOS++)); }

sleep 10
$COMPOSE up -d ocudu-cu-up >/dev/null 2>&1
sleep 12

inicio=$(docker inspect ran-cu-up --format '{{.State.StartedAt}}' 2>/dev/null)
if [ -n "$inicio" ] && $COMPOSE logs --since "$inicio" ocudu-cu-up 2>/dev/null \
     | grep -q "E1: Connection to CU-CP completed"; then
    ok "E1 establecido"
else
    err "No se confirmo la asociacion E1"; ((FALLOS++))
fi

# ---------------------------------------------------------------------------
paso "5. DU"
$COMPOSE up -d --force-recreate ocudu-du >/dev/null 2>&1

# La DU debe usar la configuracion del compose base, no la de multiue
montaje=$(docker inspect ran-du --format '{{range .Mounts}}{{.Source}} {{end}}' 2>/dev/null)
case "$montaje" in
    *du_zmq_multiue.yml*) warn "La DU esta usando du_zmq_multiue.yml; deberia usar du_zmq_lab.yml" ;;
    *du_zmq_lab.yml*)     ok "La DU usa du_zmq_lab.yml (correcto)" ;;
esac

echo "Esperando a que la celda quede activa (hasta 80 s)..."
du_inicio=$(docker inspect ran-du --format '{{.State.StartedAt}}' 2>/dev/null | cut -c1-19)
cell_ok=0
if [ -n "$du_inicio" ]; then
    for i in $(seq 1 27); do
        if [ -f logs/ran/du/du.log ] && \
           awk -v ts="$du_inicio" '/Cell was activated/ { if (substr($0,1,19) >= ts) f=1 } END { exit !f }' \
               logs/ran/du/du.log 2>/dev/null; then
            cell_ok=1; break
        fi
        sleep 3
    done
fi
[ "$cell_ok" = "1" ] && ok "Celda activa" || { err "La celda no se activo"; ((FALLOS++)); }

# ---------------------------------------------------------------------------
paso "6. Terminales ($NUE)"
$COMPOSE up -d --force-recreate $UES >/dev/null 2>&1
sleep 25

arriba=0
for c in $CONT; do
    docker ps --format '{{.Names}}' | grep -q "^${c}$" && arriba=$((arriba+1))
done
[ "$arriba" -eq "$NUE" ] \
    && ok "$arriba terminal(es) arrancados (esperando al broker, es lo normal)" \
    || { err "Solo $arriba de $NUE terminales en marcha"; ((FALLOS++)); }

# ---------------------------------------------------------------------------
paso "7. Broker (el ultimo)"
docker run -d --name ue-broker \
    --network tfg-openran-lab_oran_5g_net --ip 10.0.0.35 \
    -e PYTHONUNBUFFERED=1 \
    -e DU_ADDR=10.0.0.24 -e DU_TX_PORT=2000 -e DU_RX_PORT=2001 \
    -e UE_ADDRS="$ADDRS" -e UE_TX_PORTS="$TXP" -e UE_RX_PORTS="$RXP" \
    -e UE_GAINS="$GAINS" -e SAMP_RATE=23.04e6 \
    local/ue-broker:latest >/dev/null 2>&1

sleep 10
docker ps --format '{{.Names}}' | grep -q '^ue-broker$' \
    && ok "Broker en marcha con $NUE terminal(es)" || { err "El broker no arranco"; ((FALLOS++)); }

# ---------------------------------------------------------------------------
paso "8. Sesiones de datos (hasta 75 s)"
for intento in $(seq 1 15); do
    listos=0
    for c in $CONT; do
        docker exec "$c" ip -4 addr show tun_srsue >/dev/null 2>&1 && listos=$((listos+1))
    done
    [ "$listos" -eq "$NUE" ] && break
    sleep 5
done

echo ""
for c in $CONT; do
    ip=$(docker exec "$c" ip -4 addr show tun_srsue 2>/dev/null \
        | grep -oE 'inet [0-9.]+' | awk '{print $2}')
    if [ -n "$ip" ]; then
        ok "$c -> sesion establecida, IP $ip"
    else
        err "$c -> sin sesion"; ((FALLOS++))
    fi
done

# ---------------------------------------------------------------------------
paso "9. Caudal del enlace ZMQ"
# Interfaz localizada por IP: Docker no garantiza el orden de los nombres
du_bytes() {
    docker exec ran-du sh -c '
        IF=$(ip -o addr show | grep "10.0.0.24" | awk "{print \$2}")
        grep "$IF" /proc/net/dev | awk "{print \$10}"
    ' 2>/dev/null || echo 0
}
t1=$(du_bytes); sleep 10; t2=$(du_bytes)
delta=$(( ${t2:-0} - ${t1:-0} ))

if [ "$delta" -gt 100000000 ]; then
    ok "La DU transmite $((delta/1048576)) MB en 10 s"
elif [ "$delta" -gt 1000000 ]; then
    warn "La DU transmite $((delta/1048576)) MB en 10 s (por debajo de lo habitual, ~1 GB)"
else
    err "La DU transmite $delta bytes en 10 s: no circulan muestras"; ((FALLOS++))
fi

# ---------------------------------------------------------------------------
paso "10. Plano de usuario"
for c in $CONT; do
    if docker exec "$c" ping -c 3 -W 3 10.45.0.1 >/dev/null 2>&1; then
        rtt=$(docker exec "$c" ping -c 3 -W 3 10.45.0.1 2>/dev/null | tail -1 | cut -d'=' -f2)
        ok "$c -> ping correcto (${rtt:- n/d})"
    else
        err "$c -> el ping al UPF no responde"; ((FALLOS++))
    fi
done

# ---------------------------------------------------------------------------
if [ "$CON_RIC" = "1" ]; then
    paso "11. Registro E2"
    estados=$(docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null)
    n=$(echo "$estados" | grep -o '"CONNECTED"' | wc -l)
    [ "$n" -eq 2 ] && ok "Nodos E2 conectados: $n" || warn "Nodos E2 conectados: $n (se esperaban 2)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "############################################################"
if [ "$FALLOS" -eq 0 ]; then
    echo -e "  ${GREEN}Laboratorio MULTI-UE operativo con $NUE terminal(es)${NC}"
else
    echo -e "  ${RED}$FALLOS comprobacion(es) fallida(s)${NC}"
    echo "  Diagnostico: config/ocudu/MULTIUE-RECETA.md (apartado 8)"
fi
echo ""
echo "  Medir caudal:  ./caudal.sh"
echo "  Parar todo:    docker rm -f ue-broker && ./stop-lab.sh"
echo "############################################################"
echo ""
exit $([ "$FALLOS" -eq 0 ] && echo 0 || echo 1)
