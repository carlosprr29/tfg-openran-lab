#!/bin/bash
# =============================================================================
# Escenario 05 - Envenenamiento de metricas (xApp maliciosa)
# -----------------------------------------------------------------------------
# La red funciona con normalidad: los tres terminales mantienen trafico de
# bajada constante y no hay ningun ataque sobre la radio ni sobre el plano de
# usuario. El ataque esta en el plano de control: la xApp que recoge las
# metricas esta comprometida y, durante el tercio central, falsea una de ellas
# multiplicandola por un factor. Es el modelo de una xApp maliciosa (software
# de terceros dentro del RIC) que envenena los datos que ve el detector.
#
# La xApp maliciosa conoce el valor real (lo recibe del nodo E2) y el que decide
# reportar, asi que escribe ambos en el CSV: la columna <metrica> lleva el valor
# reportado (lo que veria la victima) y <metrica>_real la verdad. La deteccion
# se mide comparando las dos.
#
# El factor (segundo parametro) es la intensidad del ataque. >1 fabrica una
# anomalia falsa sobre trafico normal; <1 enmascararia una subida real. Se barre
# para trazar la curva de detectabilidad: a partir de que desviacion el valor
# reportado se sale de lo que la verdad permite.
#
# Uso:
#   ./escenarios/05-envenenamiento-metricas/ataque.sh                 180 s, factor 2.0
#   ./escenarios/05-envenenamiento-metricas/ataque.sh 180 1.5         factor 1.5
#   ./escenarios/05-envenenamiento-metricas/ataque.sh 180 3 DRB.UEThpDl
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."   # raiz del proyecto

VERDE='\033[0;32m'; AMAR='\033[1;33m'; ROJO='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${VERDE}[OK]${NC} $1"; }
avis() { echo -e "${AMAR}[AVISO]${NC} $1"; }
err()  { echo -e "${ROJO}[FALLO]${NC} $1"; }

DUR="${1:-180}"
FACTOR="${2:-2.0}"              # factor de envenenamiento (intensidad del ataque)
POISON_MET="${3:-DRB.UEThpUl}"  # metrica que se falsea
CAUDAL_DL="${4:-2M}"            # trafico de bajada de cada terminal (constante)
C="docker compose -f docker-compose.yaml -f docker-compose.multiue.yml"
UES="ue-srsue ue-srsue2 ue-srsue3"
METRICAS="DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl,DRB.RlcDelayUl,DRB.RlcSduTransmittedVolumeDL,DRB.RlcSduTransmittedVolumeUL"

# El ataque ocupa el tercio central de la sesion
INICIO_ATAQUE=$((DUR / 3))
FIN_ATAQUE=$((2 * DUR / 3))

INT_ETIQUETA=$(echo "$FACTOR" | tr -d ' ')
SESION="data/escenarios/05-envenenamiento-${INT_ETIQUETA}-$(date +%Y%m%d-%H%M)"
SESION_ABS="$(pwd)/$SESION"
E2_NODO=""

echo ""
echo "=========================================================="
echo "  Escenario 05 - Envenenamiento de metricas (xApp maliciosa)"
echo "  Duracion: ${DUR}s  |  Envenenamiento: ${INICIO_ATAQUE}s -> ${FIN_ATAQUE}s"
echo "  Metrica falseada: ${POISON_MET}  x ${FACTOR}"
echo "  Trafico DL constante por terminal: ${CAUDAL_DL}"
echo "  Destino: $SESION"
echo "=========================================================="

# --- Comprobaciones ---------------------------------------------------------
echo ""
docker ps --format '{{.Names}}' | grep -q '^ran-du$' || {
    err "El laboratorio base no esta levantado. Ejecuta: ./start-lab.sh"; exit 1; }
docker ps --format '{{.Names}}' | grep -q '^ue-broker$' || {
    err "El broker no esta levantado. Ejecuta: ./lab-multiue.sh"; exit 1; }
ok "Laboratorio base y broker levantados"

mkdir -p "$SESION"

# --- Limpieza y arranque del escenario --------------------------------------
$C stop ue-simulado ue2 ue3 >/dev/null 2>&1
docker rm -f ue-broker >/dev/null 2>&1
sleep 3
sudo rm -f logs/ue/*.pcap logs/ran/du/*.pcap logs/ran/cu_cp/*.pcap logs/ue/iperf_*.log 2>/dev/null
(cd oran-sc-ric && docker compose exec -T python_xapp_runner rm -f /tmp/metricas_sesion.csv >/dev/null 2>&1)
ok "Capturas y registros anteriores eliminados"

echo ""
echo ">> Levantando los tres terminales y el broker"
./lab-multiue.sh > "$SESION_ABS/arranque.log" 2>&1
if grep -q "operativo con 3 terminal" "$SESION_ABS/arranque.log"; then
    ok "Escenario multi-UE operativo"
else
    err "El escenario no quedo operativo; ver $SESION/arranque.log"; exit 1
fi

# --- Servidor de trafico ----------------------------------------------------
docker exec core-upf sh -c 'pkill iperf3 2>/dev/null; exit 0'; sleep 1
for p in 5201 5202 5203; do docker exec -d core-upf iperf3 -s -B 10.45.0.1 -p $p; done
sleep 3
ok "Servidor de trafico en marcha"

# --- Interfaz E2 ------------------------------------------------------------
e2_conectados() {
    docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null \
        | grep -o '"connectionStatus":"CONNECTED"' | wc -l
}
METRICAS_OK=0
if docker ps --format '{{.Names}}' | grep -q '^ric_e2mgr$'; then
    echo ">> Esperando a que el E2 de la DU conecte con el RIC (sin tocar la DU)"
    esperado=0
    while [ "$(e2_conectados)" -lt 2 ] && [ "$esperado" -lt 90 ]; do
        sleep 10; esperado=$((esperado + 10))
    done
    if [ "$(e2_conectados)" -lt 2 ]; then
        avis "E2 sin conectar tras ${esperado}s; reiniciando e2term (lado RIC, no toca los terminales)"
        (cd oran-sc-ric && docker compose restart e2term >/dev/null 2>&1)
        esperado=0
        while [ "$(e2_conectados)" -lt 2 ] && [ "$esperado" -lt 120 ]; do
            sleep 10; esperado=$((esperado + 10))
        done
    fi
    if [ "$(e2_conectados)" -ge 2 ]; then
        E2_NODO=$(docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null \
            | grep -oE '"inventoryName":"gnbd_[^"]*"' | head -1 | sed 's/.*:"//;s/"//')
        cp escenarios/05-envenenamiento-metricas/kpm_csv_xapp_malicioso.py oran-sc-ric/xApps/python/ 2>/dev/null
        chmod +x oran-sc-ric/xApps/python/kpm_csv_xapp_malicioso.py 2>/dev/null
        ok "Nodo E2: $E2_NODO (conecto tras ${esperado}s)"
        METRICAS_OK=1
    else
        avis "El E2 no conecto; sesion sin metricas (no reiniciamos la DU para no perder los terminales)"
    fi
fi

# --- Lanzar la recoleccion con la xApp MALICIOSA ----------------------------
if [ "$METRICAS_OK" = "1" ]; then
    # Reiniciar el runner libera el puerto HTTP de cualquier xApp anterior.
    (cd oran-sc-ric && docker compose restart python_xapp_runner >/dev/null 2>&1)
    sleep 10
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner ./kpm_csv_xapp_malicioso.py \
        --e2_node_id="$E2_NODO" --metrics="$METRICAS" --kpm_report_style=5 \
        --output=/tmp/metricas_sesion.csv --duration=$((DUR + 10)) \
        --poison_mode=scale --poison_factor="$FACTOR" --poison_metrics="$POISON_MET" \
        --poison_start="$INICIO_ATAQUE" --poison_end="$FIN_ATAQUE" \
        > "$SESION_ABS/xapp.log" 2>&1) &
    XAPP_PID=$!
    sleep 3
fi

# --- Trafico de bajada: constante en los tres terminales --------------------
echo ""
echo ">> Arrancando trafico de bajada (${CAUDAL_DL} por terminal, toda la sesion)"
i=0
for c in $UES; do
    p=$((5201 + i))
    docker exec -d "$c" sh -c "iperf3 -c 10.45.0.1 -p $p -R -b ${CAUDAL_DL} -t $DUR -i 5 --logfile /tmp/iperf_${c}.log"
    i=$((i+1))
done
sleep 2

# --- Fases: la red no cambia; la xApp falsea en la ventana central ----------
echo ">> FASE 1: trafico normal, metricas limpias ($INICIO_ATAQUE s)"
sleep "$INICIO_ATAQUE"
echo ">> FASE 2: la xApp falsea ${POISON_MET} x${FACTOR} ($((FIN_ATAQUE - INICIO_ATAQUE)) s)"
sleep $((FIN_ATAQUE - INICIO_ATAQUE))
echo ">> FASE 3: metricas limpias de nuevo ($((DUR - FIN_ATAQUE)) s)"
sleep $((DUR - FIN_ATAQUE + 5))
ok "Trafico completado"

# --- Recoger resultados -----------------------------------------------------
for c in $UES; do
    docker exec "$c" cat "/tmp/iperf_${c}.log" > "$SESION/iperf_${c}.txt" 2>/dev/null
done

if [ "$METRICAS_OK" = "1" ]; then
    esperado=0
    while kill -0 "$XAPP_PID" 2>/dev/null && [ "$esperado" -lt 60 ]; do
        sleep 3; esperado=$((esperado + 3))
    done
    kill "$XAPP_PID" 2>/dev/null
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner cat /tmp/metricas_sesion.csv 2>/dev/null) > "$SESION_ABS/metricas.csv"
    n=$(($(wc -l < "$SESION/metricas.csv") - 1))
    [ "$n" -gt 0 ] && ok "Metricas recogidas: $n filas" || avis "Metricas vacias; ver xapp.log"
fi

echo ""
echo ">> Parando terminales para volcar capturas"
$C stop ue-simulado ue2 ue3 >/dev/null 2>&1
sleep 8
cp logs/ue/*.pcap logs/ran/du/du_mac.pcap logs/ran/cu_cp/*.pcap "$SESION/" 2>/dev/null

# --- Ficha ------------------------------------------------------------------
cat > "$SESION/README.md" << FICHA
# Sesion: envenenamiento de metricas (xApp maliciosa)

**Fecha:** $(date '+%Y-%m-%d %H:%M')  **Duracion:** ${DUR}s

## Ataque

La red funciona con normalidad. Durante el tercio central (${INICIO_ATAQUE}s a
${FIN_ATAQUE}s) la xApp de recoleccion, comprometida, multiplica ${POISON_MET}
por ${FACTOR} antes de escribirla. El CSV lleva el valor reportado (lo que ve la
victima) y el real (<metrica>_real), para poder medir la deteccion.

| Fase | Intervalo | Metrica reportada |
|---|---|---|
| Normal | 0 - ${INICIO_ATAQUE}s | real |
| Ataque | ${INICIO_ATAQUE} - ${FIN_ATAQUE}s | ${POISON_MET} x **${FACTOR}** |
| Normal | ${FIN_ATAQUE} - ${DUR}s | real |

## Que buscar

En la ventana central, la columna ${POISON_MET} se separa de ${POISON_MET}_real.
La deteccion no es un umbral: hay que contrastar lo reportado contra la verdad
(las columnas _real, o el trafico real de iperf) y contra la coherencia entre
metricas (p. ej. caudal alto deberia llevar volumen transmitido alto). El reto
es el factor bajo: una desviacion pequena que no rompe esa coherencia.
FICHA

echo ""
echo "=========================================================="
ok "Sesion guardada en $SESION"
echo "  Volver al base: ./lab-multiue.sh"
echo "=========================================================="
echo ""
