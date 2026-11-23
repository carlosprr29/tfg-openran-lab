#!/bin/bash
# =============================================================================
# Escenario 04 - Jamming en la bajada
# -----------------------------------------------------------------------------
# Los tres terminales mantienen un trafico de bajada moderado y constante toda
# la sesion. En el tercio central, el broker inyecta ruido gaussiano en la
# bajada (un jammer que sube el suelo de ruido del canal). No se cambia el
# trafico: lo que cambia es la calidad del enlace.
#
# A diferencia del terminal comprometido (un pico de subida en un solo
# terminal), aqui la degradacion es ancha: afecta a los tres a la vez, y mas
# al que menos margen tiene (UE3, el mas atenuado). La firma no es un salto de
# caudal sino el retardo RLC y el volumen retransmitido subiendo en bloque.
#
# El nivel de ruido (segundo parametro) es la intensidad del ataque. Se barre
# de mas a menos para trazar la curva de detectabilidad, buscando el punto en
# que la degradacion deja de verse en el caudal pero sigue en el retardo.
#
# Uso:
#   ./escenarios/04-jamming-dl/ataque.sh                 180 s, nivel 0.015
#   ./escenarios/04-jamming-dl/ataque.sh 180 0.02        nivel 0.02
#   ./escenarios/04-jamming-dl/ataque.sh 180 0.012       nivel bajo (sutil)
#
# El control del ruido es el fichero /tmp/jam_nivel dentro del contenedor del
# broker, que este broker lee en caliente (ver broker/intento-propio).
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."   # raiz del proyecto

VERDE='\033[0;32m'; AMAR='\033[1;33m'; ROJO='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${VERDE}[OK]${NC} $1"; }
avis() { echo -e "${AMAR}[AVISO]${NC} $1"; }
err()  { echo -e "${ROJO}[FALLO]${NC} $1"; }

DUR="${1:-180}"
NIVEL="${2:-0.015}"        # intensidad del ataque (amplitud del ruido en la bajada)
CAUDAL_DL="${3:-2M}"       # trafico de bajada de cada terminal (constante)
C="docker compose -f docker-compose.yaml -f docker-compose.multiue.yml"
UES="ue-srsue ue-srsue2 ue-srsue3"
METRICAS="DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl,DRB.RlcDelayUl,DRB.RlcSduTransmittedVolumeDL,DRB.RlcSduTransmittedVolumeUL"

# El ataque ocupa el tercio central de la sesion
INICIO_ATAQUE=$((DUR / 3))
FIN_ATAQUE=$((2 * DUR / 3))
DUR_ATAQUE=$((FIN_ATAQUE - INICIO_ATAQUE))

INT_ETIQUETA=$(echo "$NIVEL" | tr -d ' ')
SESION="data/escenarios/04-jamming-dl-${INT_ETIQUETA}-$(date +%Y%m%d-%H%M)"
SESION_ABS="$(pwd)/$SESION"
E2_NODO=""

echo ""
echo "=========================================================="
echo "  Escenario 04 - Jamming en la bajada"
echo "  Duracion: ${DUR}s  |  Ataque: ${INICIO_ATAQUE}s -> ${FIN_ATAQUE}s"
echo "  Ruido en la bajada durante el ataque: nivel ${NIVEL}"
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

# Partimos de ruido apagado, pase lo que pase de una sesion anterior
docker exec ue-broker sh -c "echo 0 > /tmp/jam_nivel" 2>/dev/null
ok "Ruido del broker a 0 (enlace limpio)"

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
    # El agente E2 de la DU se reconecta solo al RIC despues del arranque.
    # Esperamos a que lo haga SIN reiniciar la DU: los tres terminales ya estan
    # sincronizados, y reiniciar la DU los tumbaria y nos dejaria sin trafico ni
    # metricas (eso paso en la primera version, con dos reinicios seguidos).
    echo ">> Esperando a que el E2 de la DU conecte con el RIC (sin tocar la DU)"
    esperado=0
    while [ "$(e2_conectados)" -lt 2 ] && [ "$esperado" -lt 90 ]; do
        sleep 10; esperado=$((esperado + 10))
    done
    # Si no conecto, un empujon por el lado del RIC: reiniciar e2term NO toca los
    # terminales (solo la DU los tumbaria, y eso no lo hacemos). Suele bastar para
    # que el agente E2 de la DU se reenganche.
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
        cp xapp_ai/kpm_csv_xapp.py oran-sc-ric/xApps/python/ 2>/dev/null
        chmod +x oran-sc-ric/xApps/python/kpm_csv_xapp.py 2>/dev/null
        ok "Nodo E2: $E2_NODO (conecto tras ${esperado}s)"
        METRICAS_OK=1
    else
        avis "El E2 no conecto en 180s; sesion sin metricas (no reiniciamos la DU para no perder los terminales)"
    fi
fi

# --- Lanzar la recoleccion de metricas --------------------------------------
if [ "$METRICAS_OK" = "1" ]; then
    # El contenedor del xApp no tiene pkill, asi que un xApp de una toma anterior
    # podia quedar vivo ocupando el puerto HTTP y hacer que el nuevo fallara con
    # "Address already in use", dejando las metricas vacias. Reiniciar el runner
    # es la forma segura de liberar el puerto antes de medir.
    (cd oran-sc-ric && docker compose restart python_xapp_runner >/dev/null 2>&1)
    sleep 10
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner ./kpm_csv_xapp.py \
        --e2_node_id="$E2_NODO" --metrics="$METRICAS" --kpm_report_style=5 \
        --output=/tmp/metricas_sesion.csv --duration=$((DUR + 10)) \
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

# --- Fases: normal / ataque (ruido) / normal --------------------------------
echo ">> FASE 1: trafico normal, sin ruido ($INICIO_ATAQUE s)"
sleep "$INICIO_ATAQUE"

echo ">> FASE 2: ATAQUE - jamming DL a nivel $NIVEL ($DUR_ATAQUE s)"
docker exec ue-broker sh -c "echo $NIVEL > /tmp/jam_nivel"
sleep "$DUR_ATAQUE"

echo ">> FASE 3: fin del jamming, vuelta a la normalidad ($((DUR - FIN_ATAQUE)) s)"
docker exec ue-broker sh -c "echo 0 > /tmp/jam_nivel"
sleep $((DUR - FIN_ATAQUE + 5))
ok "Trafico completado"

# --- Recoger resultados -----------------------------------------------------
for c in $UES; do
    docker exec "$c" cat "/tmp/iperf_${c}.log" > "$SESION/iperf_${c}.txt" 2>/dev/null
done

if [ "$METRICAS_OK" = "1" ]; then
    # Espera acotada al xApp: deberia salir solo por --duration, pero si el E2
    # flaquea puede quedarse colgado. Esperamos como mucho 60 s y lo forzamos.
    esperado=0
    while kill -0 "$XAPP_PID" 2>/dev/null && [ "$esperado" -lt 60 ]; do
        sleep 3; esperado=$((esperado + 3))
    done
    kill "$XAPP_PID" 2>/dev/null
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner cat /tmp/metricas_sesion.csv 2>/dev/null) > "$SESION_ABS/metricas.csv"
    n=$(($(wc -l < "$SESION/metricas.csv") - 1))
    [ "$n" -gt 0 ] && ok "Metricas recogidas: $n filas" || avis "Metricas vacias; ver xapp.log"
fi

# Dejar el broker sin ruido al terminar, por si acaso
docker exec ue-broker sh -c "echo 0 > /tmp/jam_nivel" 2>/dev/null

echo ""
echo ">> Parando terminales para volcar capturas"
$C stop ue-simulado ue2 ue3 >/dev/null 2>&1
sleep 8
cp logs/ue/*.pcap logs/ran/du/du_mac.pcap logs/ran/cu_cp/*.pcap "$SESION/" 2>/dev/null

# --- Ficha ------------------------------------------------------------------
cat > "$SESION/README.md" << FICHA
# Sesion: jamming en la bajada

**Fecha:** $(date '+%Y-%m-%d %H:%M')  **Duracion:** ${DUR}s

## Ataque

Durante el tercio central (${INICIO_ATAQUE}s a ${FIN_ATAQUE}s) el broker inyecta
ruido gaussiano de nivel ${NIVEL} en la bajada. Los tres terminales mantienen un
trafico de bajada constante de ${CAUDAL_DL}. El ruido va despues de la ganancia
de cada terminal, asi que afecta mas a UE3 (el mas atenuado).

| Fase | Intervalo | Ruido DL |
|---|---|---|
| Normal | 0 - ${INICIO_ATAQUE}s | 0 |
| Ataque | ${INICIO_ATAQUE} - ${FIN_ATAQUE}s | **${NIVEL}** |
| Normal | ${FIN_ATAQUE} - ${DUR}s | 0 |

## Que buscar

A diferencia del terminal comprometido, aqui no hay un salto de caudal. La
firma es el retardo RLC de bajada (DRB.RlcSduDelayDl) y el volumen retransmitido
subiendo en los tres terminales a la vez durante el tramo central, con UE3 como
el mas afectado. En niveles bajos el caudal apenas se mueve y solo el retardo lo
delata: ese es el caso dificil para un umbral.

## Graficas

\`\`\`bash
./graficas.py $SESION
\`\`\`
FICHA

echo ""
echo "=========================================================="
ok "Sesion guardada en $SESION"
echo "  Graficas:   ./graficas.py $SESION"
echo "  Volver al base: ./lab-multiue.sh"
echo "=========================================================="
echo ""
