#!/bin/bash
# =============================================================================
# TFG OpenRAN Lab - escenario MULTI-UE
# -----------------------------------------------------------------------------
# Traduccion literal de la secuencia verificada a mano el 15/10/2026, con la
# que los tres terminales obtuvieron sesion y ping sin perdidas.
#
# Este script NO intenta ser listo: hace siempre lo mismo, en el mismo orden y
# con los mismos tiempos. La version anterior (start-multiue.sh) intentaba
# detectar estados y adaptarse, y acabo dando [OK] en pasos que no lo estaban.
#
# Uso:
#   ./lab-multiue.sh            los tres terminales
#   ./lab-multiue.sh 1          solo uno
#   ./lab-multiue.sh 2          dos
#
# Si el laboratorio base no esta levantado, este script ejecuta ./start-lab.sh
# por su cuenta. No hace falta acordarse de encadenarlos.
#
# -----------------------------------------------------------------------------
# Lo que hay que respetar, aprendido a base de fallos:
#
# 1. GANANCIAS ESCALONADAS, nunca iguales. El broker suma las subidas, asi que
#    cada terminal recibe como interferencia lo que aportan los demas. Con
#    ganancias iguales la señal util y la interferencia crecen a la par y la
#    relacion señal-ruido se queda en 5-6 dB, por debajo del umbral: el CRC
#    falla y ningun terminal llega a registrarse. Con 0, 10 y 20 dB de
#    atenuacion (1.0 / 0.316 / 0.1 en lineal) la DU los distingue y la señal
#    sube a 9-12 dB. Son los valores del flujo oficial de srsRAN.
#
# 2. ORDEN ESTRICTO: DU reiniciada -> celda activa -> todos los terminales a la
#    vez -> broker el ultimo. El broker va al final porque los terminales no
#    conectan hasta que existe el camino de bajada y subida.
#
# 3. NINGUN TERMINAL ARRANCADO ANTES de reiniciar la DU. Si uno ya estaba en
#    marcha, su emparejamiento ZMQ queda roto y no se rehace solo.
#
# 4. La DU usa du_zmq_lab.yml (20 MHz, 23.04), con el rx_port apuntando al
#    broker en 10.0.0.35:2001. El fichero de superposicion NO debe
#    sobreescribir su volumen.
#
# 5. Medir siempre por direccion IP, nunca por nombre de interfaz: Docker no
#    garantiza el orden de eth0/eth1/eth2 al recrear un contenedor.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

VERDE='\033[0;32m'; AMAR='\033[1;33m'; ROJO='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${VERDE}[OK]${NC} $1"; }
avis() { echo -e "${AMAR}[AVISO]${NC} $1"; }
err()  { echo -e "${ROJO}[FALLO]${NC} $1"; ((FALLOS++)); }

C="docker compose -f docker-compose.yaml -f docker-compose.multiue.yml"
NUE="${1:-3}"
FALLOS=0

case "$NUE" in
    1) UES="ue-simulado";         CONT="ue-srsue"
       ADDRS="10.0.0.30";                     TXP="2001";           RXP="2100"
       GAINS="1.0" ;;
    2) UES="ue-simulado ue2";     CONT="ue-srsue ue-srsue2"
       ADDRS="10.0.0.30,10.0.0.31";           TXP="2001,2201";      RXP="2100,2200"
       GAINS="1.0,0.316" ;;
    3) UES="ue-simulado ue2 ue3"; CONT="ue-srsue ue-srsue2 ue-srsue3"
       ADDRS="10.0.0.30,10.0.0.31,10.0.0.32"; TXP="2001,2201,2301"; RXP="2100,2200,2300"
       GAINS="1.0,0.316,0.1" ;;
    *) echo "Uso: ./lab-multiue.sh [1|2|3]"; exit 1 ;;
esac

echo ""
echo "=========================================================="
echo "  MULTI-UE con $NUE terminal(es)   ganancias: $GAINS"
echo "=========================================================="

# --- 0. Laboratorio base ----------------------------------------------------
# Este script da por hecho que el Core, la CU-CP, la CU-UP y la DU estan en
# marcha. Si no lo estan, se levanta el laboratorio base primero.
base_lista() {
    docker ps --format '{{.Names}}' | grep -q '^ran-du$'        || return 1
    docker ps --format '{{.Names}}' | grep -q '^ran-cu-up$'     || return 1
    $C ps open5gs-amf 2>/dev/null | grep -q healthy             || return 1
    return 0
}

echo ""
if base_lista; then
    ok "Laboratorio base ya levantado"
else
    avis "El laboratorio base no esta levantado; ejecutando ./start-lab.sh"
    echo ""
    ./start-lab.sh
    echo ""
    if base_lista; then
        ok "Laboratorio base levantado"
    else
        err "El laboratorio base no quedo operativo; revisa la salida anterior"
        exit 1
    fi
    # El start-lab.sh arranca el terminal unico, que hay que parar antes de
    # seguir: no puede haber ningun terminal en marcha al reiniciar la DU.
    $C stop ue-simulado >/dev/null 2>&1
fi

# --- 1. Partir de limpio -----------------------------------------------------
echo ""
echo ">> Parando broker y terminales"
docker rm -f ue-broker >/dev/null 2>&1
$C stop ue-simulado ue2 ue3 >/dev/null 2>&1

# --- 2. DU ------------------------------------------------------------------
echo ">> Reiniciando la DU (70 s de espera)"
$C restart ocudu-du >/dev/null 2>&1
sleep 70

du_ini=$(docker inspect ran-du --format '{{.State.StartedAt}}' 2>/dev/null | cut -c1-19)
if [ -n "$du_ini" ] && awk -v ts="$du_ini" \
     '/Cell was activated/ { if (substr($0,1,19) >= ts) f=1 } END { exit !f }' \
     logs/ran/du/du.log 2>/dev/null; then
    ok "Celda activa"
else
    err "La celda no se activo tras reiniciar la DU"
fi

# --- 3. Terminales ----------------------------------------------------------
echo ">> Arrancando $NUE terminal(es) (20 s de espera)"
$C up -d $UES >/dev/null 2>&1
sleep 20

n=0
for c in $CONT; do docker ps --format '{{.Names}}' | grep -q "^${c}$" && n=$((n+1)); done
[ "$n" -eq "$NUE" ] && ok "$n terminal(es) en marcha" || err "Solo $n de $NUE en marcha"

# --- 4. Broker, el ultimo ---------------------------------------------------
echo ">> Arrancando el broker (60 s de espera)"
docker run -d --name ue-broker \
    --network tfg-openran-lab_oran_5g_net --ip 10.0.0.35 \
    -e PYTHONUNBUFFERED=1 \
    -e DU_ADDR=10.0.0.24 -e DU_TX_PORT=2000 -e DU_RX_PORT=2001 \
    -e UE_ADDRS="$ADDRS" -e UE_TX_PORTS="$TXP" -e UE_RX_PORTS="$RXP" \
    -e UE_GAINS="$GAINS" -e SAMP_RATE=23.04e6 \
    local/ue-broker:latest >/dev/null 2>&1
sleep 60

docker ps --format '{{.Names}}' | grep -q '^ue-broker$' \
    && ok "Broker en marcha" || err "El broker no arranco"

# --- 5. Resultado -----------------------------------------------------------
echo ""
echo "----- Sesiones -----"
for c in $CONT; do
    ip=$(docker exec "$c" ip -4 addr show tun_srsue 2>/dev/null \
        | grep -oE 'inet [0-9.]+' | awk '{print $2}')
    [ -n "$ip" ] && ok "$c -> $ip" || err "$c -> sin sesion"
done

echo ""
echo "----- Caudal del enlace ZMQ (10 s) -----"
du_tx() {
    docker exec ran-du sh -c '
        IF=$(ip -o addr show | grep "10.0.0.24" | awk "{print \$2}")
        grep "$IF" /proc/net/dev | awk "{print \$10}"
    ' 2>/dev/null || echo 0
}
a=$(du_tx); sleep 10; b=$(du_tx)
d=$(( ${b:-0} - ${a:-0} ))
if [ "$d" -gt 500000000 ]; then
    ok "La DU transmite $((d/1048576)) MB (referencia: ~850 MB)"
else
    avis "La DU transmite $((d/1048576)) MB, por debajo de lo habitual"
fi

echo ""
echo "----- Calidad de señal -----"
grep -oE "rnti=0x46[0-9]+ .*sinr=[0-9.]+dB" logs/ran/du/du.log 2>/dev/null \
    | grep -oE "rnti=0x46[0-9]+|sinr=[0-9.]+dB" | paste - - | tail -"$NUE" \
    | sed 's/^/  /' || echo "  (sin datos)"
echo "  Referencia: 9-12 dB con tres terminales. Por debajo de 7 dB el CRC falla."

echo ""
echo "----- Plano de usuario -----"
for c in $CONT; do
    if docker exec "$c" ping -c 3 -W 3 10.45.0.1 >/dev/null 2>&1; then
        rtt=$(docker exec "$c" ping -c 3 -W 3 10.45.0.1 2>/dev/null | tail -1 | cut -d'=' -f2)
        ok "$c -> ping correcto (${rtt:- n/d})"
    else
        err "$c -> ping sin respuesta"
    fi
done

echo ""
echo "=========================================================="
if [ "$FALLOS" -eq 0 ]; then
    echo -e "  ${VERDE}Escenario MULTI-UE operativo con $NUE terminal(es)${NC}"
else
    echo -e "  ${ROJO}$FALLOS comprobacion(es) fallida(s)${NC}"
    echo "  Ver config/ocudu/MULTIUE-RECETA.md"
fi
echo "  Parar: docker rm -f ue-broker && ./stop-lab.sh"
echo "=========================================================="
echo ""
exit $([ "$FALLOS" -eq 0 ] && echo 0 || echo 1)
