#!/bin/bash
# =============================================================================
# Escenario 01 - Terminal comprometido
# -----------------------------------------------------------------------------
# Parte del escenario holgado (tres terminales con trafico suave) y hace que
# UE3 pase a generar una rafaga intensa, simulando un dispositivo infectado que
# abusa de los recursos. Los otros dos siguen con su trafico normal.
#
# Recoge capturas y metricas igual que captura.sh, y guarda todo en
# data/escenarios/01-ue-comprometido-<fecha>/
#
# Uso:
#   ./escenarios/01-ue-comprometido/ataque.sh           180 s (por defecto)
#   ./escenarios/01-ue-comprometido/ataque.sh 120       120 s
#
# El ataque no dura toda la sesion: los primeros y ultimos segundos son
# trafico normal, y el ataque ocurre en el tramo central. Asi la propia
# sesion contiene el "antes", el "durante" y el "despues", lo que facilita
# ver donde empieza y acaba la anomalia.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."   # raiz del proyecto

VERDE='\033[0;32m'; AMAR='\033[1;33m'; ROJO='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${VERDE}[OK]${NC} $1"; }
avis() { echo -e "${AMAR}[AVISO]${NC} $1"; }
err()  { echo -e "${ROJO}[FALLO]${NC} $1"; }

DUR="${1:-180}"
C="docker compose -f docker-compose.yaml -f docker-compose.multiue.yml"
UES="ue-srsue ue-srsue2 ue-srsue3"
METRICAS="DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl,DRB.RlcDelayUl,DRB.RlcSduTransmittedVolumeDL,DRB.RlcSduTransmittedVolumeUL"

# Caudal normal (holgado) de cada terminal
CAUDAL_NORMAL=("100K" "100K" "50K")
# Caudal del terminal comprometido durante el ataque
CAUDAL_ATAQUE="5M"
# El atacante es UE3 (indice 2)
IDX_ATACANTE=2

# El ataque ocupa el tercio central de la sesion
INICIO_ATAQUE=$((DUR / 3))
FIN_ATAQUE=$((2 * DUR / 3))
DUR_ATAQUE=$((FIN_ATAQUE - INICIO_ATAQUE))

SESION="data/escenarios/01-ue-comprometido-$(date +%Y%m%d-%H%M)"
SESION_ABS="$(pwd)/$SESION"
E2_NODO=""

echo ""
echo "=========================================================="
echo "  Escenario 01 - Terminal comprometido"
echo "  Duracion: ${DUR}s  |  Ataque: ${INICIO_ATAQUE}s -> ${FIN_ATAQUE}s"
echo "  Atacante: UE3 pasa de 50K a ${CAUDAL_ATAQUE}"
echo "  Destino: $SESION"
echo "=========================================================="

# --- Comprobaciones ---------------------------------------------------------
echo ""
docker ps --format '{{.Names}}' | grep -q '^ran-du$' || {
    err "El laboratorio base no esta levantado. Ejecuta: ./start-lab.sh"; exit 1; }
ok "Laboratorio base levantado"

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
    if [ "$(e2_conectados)" -lt 2 ]; then
        avis "Nodos E2 desconectados; reiniciando e2term"
        (cd oran-sc-ric && docker compose restart e2term >/dev/null 2>&1); sleep 30
        $C restart ocudu-du >/dev/null 2>&1; sleep 80
    fi
    if [ "$(e2_conectados)" -ge 2 ]; then
        E2_NODO=$(docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null \
            | grep -oE '"inventoryName":"gnbd_[^"]*"' | head -1 | sed 's/.*:"//;s/"//')
        cp xapp_ai/kpm_csv_xapp.py oran-sc-ric/xApps/python/ 2>/dev/null
        chmod +x oran-sc-ric/xApps/python/kpm_csv_xapp.py 2>/dev/null
        ok "Nodo E2: $E2_NODO"
        METRICAS_OK=1
    else
        avis "Sin E2: se tomara la sesion sin metricas"
    fi
fi

# --- Lanzar la recoleccion de metricas --------------------------------------
if [ "$METRICAS_OK" = "1" ]; then
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner ./kpm_csv_xapp.py \
        --e2_node_id="$E2_NODO" --metrics="$METRICAS" --kpm_report_style=5 \
        --output=/tmp/metricas_sesion.csv --duration=$((DUR + 10)) \
        > "$SESION_ABS/xapp.log" 2>&1) &
    XAPP_PID=$!
    sleep 3
fi

# --- Trafico: normal / ataque / normal --------------------------------------
echo ""
echo ">> FASE 1: trafico normal ($INICIO_ATAQUE s)"
i=0
for c in $UES; do
    p=$((5201 + i))
    docker exec -d "$c" sh -c "iperf3 -c 10.45.0.1 -p $p -b ${CAUDAL_NORMAL[$i]} -t $DUR -i 5 --logfile /tmp/iperf_${c}.log"
    i=$((i+1))
done
sleep "$INICIO_ATAQUE"

echo ">> FASE 2: ATAQUE - UE3 a ${CAUDAL_ATAQUE} ($DUR_ATAQUE s)"
# Se lanza un segundo flujo de UE3, intenso, superpuesto al normal
atacante=$(echo $UES | cut -d' ' -f$((IDX_ATACANTE + 1)))
docker exec -d "$atacante" sh -c \
    "iperf3 -c 10.45.0.1 -p 5204 -b ${CAUDAL_ATAQUE} -t $DUR_ATAQUE --logfile /tmp/iperf_ataque.log" 2>/dev/null
# Servidor para el flujo de ataque
docker exec -d core-upf iperf3 -s -B 10.45.0.1 -p 5204
docker exec -d "$atacante" sh -c \
    "sleep 1; iperf3 -c 10.45.0.1 -p 5204 -b ${CAUDAL_ATAQUE} -t $DUR_ATAQUE --logfile /tmp/iperf_ataque.log"
sleep "$DUR_ATAQUE"

echo ">> FASE 3: vuelta a la normalidad ($((DUR - FIN_ATAQUE)) s)"
sleep $((DUR - FIN_ATAQUE + 5))
ok "Trafico completado"

# --- Recoger resultados -----------------------------------------------------
for c in $UES; do
    docker exec "$c" cat "/tmp/iperf_${c}.log" > "$SESION/iperf_${c}.txt" 2>/dev/null
done
docker exec "$atacante" cat /tmp/iperf_ataque.log > "$SESION/iperf_ataque.txt" 2>/dev/null

if [ "$METRICAS_OK" = "1" ]; then
    wait "$XAPP_PID" 2>/dev/null
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
# Sesion: terminal comprometido

**Fecha:** $(date '+%Y-%m-%d %H:%M')  **Duracion:** ${DUR}s

## Ataque

UE3 (normalmente 50 Kbps) genera una rafaga de ${CAUDAL_ATAQUE} durante el
tercio central de la sesion (${INICIO_ATAQUE}s a ${FIN_ATAQUE}s). UE1 y UE2
mantienen su trafico normal de 100 Kbps todo el tiempo.

| Fase | Intervalo | UE1 | UE2 | UE3 |
|---|---|---|---|---|
| Normal | 0 - ${INICIO_ATAQUE}s | 100K | 100K | 50K |
| Ataque | ${INICIO_ATAQUE} - ${FIN_ATAQUE}s | 100K | 100K | **${CAUDAL_ATAQUE}** |
| Normal | ${FIN_ATAQUE} - ${DUR}s | 100K | 100K | 50K |

## Que buscar

UE3 deberia mostrar un salto brusco de caudal y volumen en el tramo central,
muy por encima de su linea base (~123 Kbps). El reto de deteccion es que, aun
disparado, UE3 puede seguir por debajo de UE1 en valor absoluto: la anomalia
solo se ve comparando UE3 con su propia normalidad.

## Comparar con la linea base

\`\`\`bash
./graficas.py $SESION
./graficas.py --comparar data/capturas/*holgado $SESION
\`\`\`
FICHA

echo ""
echo "=========================================================="
ok "Sesion guardada en $SESION"
echo "  Graficas:   ./graficas.py $SESION"
echo "  Comparar:   ./graficas.py --comparar data/capturas/*holgado $SESION"
echo "  Volver al base: ./lab-multiue.sh"
echo "=========================================================="
echo ""
