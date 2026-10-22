#!/bin/bash
# =============================================================================
# TFG OpenRAN Lab - sesiones de captura para el estudio de metricas
# -----------------------------------------------------------------------------
# Genera trafico controlado con los tres terminales y guarda, en una carpeta
# con fecha: las capturas PCAP de cada terminal y de la DU, el trafico medido
# por iperf3 y una ficha con los parametros usados.
#
# Uso:
#   ./captura.sh holgado       trafico muy por debajo de la capacidad (referencia)
#   ./captura.sh base          trafico moderado (en la practica, satura)
#   ./captura.sh contencion    los tres a caudal alto a la vez
#   ./captura.sh asimetrico    uno intenso, dos suaves
#   ./captura.sh base 300      lo mismo, durante 300 segundos
#
# Requisito: el escenario multi-UE levantado y con los tres terminales con
# sesion (./start-lab.sh && ./lab-multiue.sh).
#
# IMPORTANTE: el servidor de trafico corre en el UPF (10.45.0.1), no en la VM.
# La tabla de rutas del terminal solo encamina 10.45.0.0/16 por la radio; si el
# servidor estuviera en la VM, el trafico saldria por la red Docker sin pasar
# por la red 5G y estariamos midiendo otra cosa.
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

VERDE='\033[0;32m'; AMAR='\033[1;33m'; ROJO='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${VERDE}[OK]${NC} $1"; }
avis() { echo -e "${AMAR}[AVISO]${NC} $1"; }
err()  { echo -e "${ROJO}[FALLO]${NC} $1"; }

PERFIL="${1:-base}"
DUR="${2:-180}"
C="docker compose -f docker-compose.yaml -f docker-compose.multiue.yml"
UES="ue-srsue ue-srsue2 ue-srsue3"

# Caudal por terminal segun el perfil
case "$PERFIL" in
    holgado)    CAUDALES=("100K" "100K" "50K")
                DESC="Trafico muy por debajo de la capacidad de la red. Referencia de normalidad con margen: cualquier degradacion posterior deberia notarse." ;;
    base)       CAUDALES=("500K" "500K" "500K")
                DESC="Trafico moderado. En la practica satura la red: los tres terminales entregan su maximo (~400/300/110 Kbps) independientemente de lo pedido." ;;
    contencion) CAUDALES=("5M" "5M" "5M")
                DESC="Los tres terminales a caudal alto simultaneamente: competencia por los recursos radio." ;;
    asimetrico) CAUDALES=("5M" "300K" "300K")
                DESC="UE1 con trafico intenso, UE2 y UE3 suaves: un terminal que se comporta distinto del resto." ;;
    *) echo "Uso: ./captura.sh [holgado|base|contencion|asimetrico] [duracion_en_segundos]"; exit 1 ;;
esac

SESION="data/capturas/$(date +%Y%m%d-%H%M)-${PERFIL}"

echo ""
echo "=========================================================="
echo "  Captura: $PERFIL   ($DUR s)"
echo "  Caudales: ${CAUDALES[0]} / ${CAUDALES[1]} / ${CAUDALES[2]}"
echo "  Destino: $SESION"
echo "=========================================================="

# --- Comprobaciones previas -------------------------------------------------
echo ""
docker ps --format '{{.Names}}' | grep -q '^ran-du$' || {
    err "El laboratorio base no esta levantado"
    echo "    Ejecuta primero:  ./start-lab.sh"
    exit 1
}
ok "Laboratorio base levantado"

mkdir -p "$SESION"

# --- Limpiar capturas anteriores --------------------------------------------
# IMPORTANTE: hay que borrarlas con los terminales PARADOS. Si se borra un
# fichero que un proceso tiene abierto, el proceso sigue escribiendo en un
# inodo que ya no esta en el directorio, y al volcar la captura al cerrarse
# no aparece nada.
$C stop ue-simulado ue2 ue3 >/dev/null 2>&1
docker rm -f ue-broker >/dev/null 2>&1
sleep 3
sudo rm -f logs/ue/*.pcap logs/ran/du/*.pcap logs/ran/cu_cp/*.pcap 2>/dev/null

# Los registros de iperf3 tambien: la herramienta los abre en modo ANADIR, y
# como /tmp del contenedor esta montado en logs/ue/, el fichero sobrevive
# entre sesiones. Sin borrarlo, el resumen promedia los datos de todas las
# capturas anteriores y da cifras imposibles (mas caudal del solicitado).
sudo rm -f logs/ue/iperf_*.log 2>/dev/null
ok "Capturas y registros anteriores eliminados (con los terminales parados)"

# --- Levantar el escenario de cero ------------------------------------------
echo ""
echo ">> Levantando los tres terminales y el broker"
./lab-multiue.sh > "$SESION/arranque.log" 2>&1
if grep -q "operativo con 3 terminal" "$SESION/arranque.log"; then
    ok "Escenario multi-UE operativo"
else
    err "El escenario no quedo operativo; ver $SESION/arranque.log"
    exit 1
fi

# --- Servidor de trafico en el UPF ------------------------------------------
docker exec core-upf sh -c 'pkill iperf3 2>/dev/null; exit 0'
sleep 1
for p in 5201 5202 5203; do
    docker exec -d core-upf iperf3 -s -B 10.45.0.1 -p $p
done
sleep 3

n_srv=$(docker exec core-upf sh -c 'ss -tln 2>/dev/null | grep -c "10.45.0.1:520"')
[ "${n_srv:-0}" -ge 3 ] \
    && ok "Servidor de trafico escuchando en 10.45.0.1 (puertos 5201-5203)" \
    || { err "El servidor de trafico no arranco"; exit 1; }

# --- Reiniciar los terminales para que la captura empiece limpia ------------
# Reiniciar los terminales obliga a reiniciar tambien la DU (emparejamiento
# ZMQ), asi que en su lugar se deja correr y se descuenta el arranque.
echo ""
echo ">> Generando trafico durante ${DUR} s..."
echo "   (no interrumpas el proceso: las capturas se escriben al final)"

i=0
for c in $UES; do
    puerto=$((5201 + i))
    docker exec -d "$c" sh -c \
        "iperf3 -c 10.45.0.1 -p $puerto -b ${CAUDALES[$i]} -t $DUR -i 10 \
         --logfile /tmp/iperf_${c}.log"
    i=$((i+1))
done

# Barra de progreso sencilla
for s in $(seq 1 $((DUR/10))); do
    sleep 10
    printf "   %d/%d s\r" $((s*10)) "$DUR"
done
sleep 5
echo ""
ok "Trafico completado"

# --- Recoger resultados de iperf3 -------------------------------------------
for c in $UES; do
    docker exec "$c" cat "/tmp/iperf_${c}.log" > "$SESION/iperf_${c}.txt" 2>/dev/null
done
ok "Resultados de iperf3 guardados"

# --- Parar los terminales: aqui se escriben los PCAP ------------------------
echo ""
echo ">> Parando los terminales para volcar las capturas..."
$C stop ue-simulado ue2 ue3 >/dev/null 2>&1
sleep 8

cp logs/ue/*.pcap "$SESION/" 2>/dev/null
cp logs/ran/du/du_mac.pcap "$SESION/" 2>/dev/null
cp logs/ran/cu_cp/*.pcap "$SESION/" 2>/dev/null

# --- Ficha de la sesion -----------------------------------------------------
cat > "$SESION/README.md" << FICHA
# Captura: $PERFIL

**Fecha:** $(date '+%Y-%m-%d %H:%M')
**Duracion:** ${DUR} s

## Escenario

$DESC

| Terminal | Caudal solicitado | Puerto |
|---|---|---|
| ue-srsue  | ${CAUDALES[0]} | 5201 |
| ue-srsue2 | ${CAUDALES[1]} | 5202 |
| ue-srsue3 | ${CAUDALES[2]} | 5203 |

Servidor: iperf3 en el UPF, 10.45.0.1
Celda: 20 MHz, 106 PRB, banda n3
Ganancias del broker: 1.0 / 0.316 / 0.1

## Ficheros

| Fichero | Contenido |
|---|---|
| \`du_mac.pcap\` | Trafico agregado de los tres terminales (el mas util) |
| \`ueN_mac_nr.pcap\` | Trafico 5G de cada terminal por separado |
| \`ueN_nas.pcap\` | Señalizacion NAS de cada terminal |
| \`cu_cp_f1ap.pcap\` | Señalizacion CU-CP - DU |
| \`iperf_*.txt\` | Caudal medido por iperf3 en cada terminal |

## Como leerlas

Ver \`config/NOTAS-CAPTURAS.md\`. En resumen:

\`\`\`bash
tshark -r du_mac.pcap -o 'uat:user_dlts:"User 2 (DLT=149)","udp","0","","0",""'
\`\`\`
FICHA

echo ""
echo "----- Resumen -----"
ls -lh "$SESION"/*.pcap 2>/dev/null | awk '{print "  "$9": "$5}'
echo ""
echo "  Caudal conseguido (media de los intervalos):"
i=0
for c in $UES; do
    # Solo las lineas de intervalo (las que empiezan por [ N] y llevan "sec")
    med=$(grep -E "^\[ *[0-9]+\].*sec" "$SESION/iperf_${c}.txt" 2>/dev/null \
        | grep -vE "sender|receiver" \
        | grep -oE "[0-9.]+ [KM]bits/sec" \
        | awk '{v=$1; if ($2=="Mbits/sec") v=v*1000; s+=v; n++} END {if(n>0) printf "%.0f Kbps", s/n; else print "sin datos"}')
    printf "    %-12s pedido %-6s  conseguido %-12s\n" "$c" "${CAUDALES[$i]}" "${med:-sin datos}"
    i=$((i+1))
done

# Anadir los resultados a la ficha de la sesion
{
    echo ""
    echo "## Resultado"
    echo ""
    echo "| Terminal | Pedido | Conseguido |"
    echo "|---|---|---|"
    i=0
    for c in $UES; do
        med=$(grep -E "^\[ *[0-9]+\].*sec" "$SESION/iperf_${c}.txt" 2>/dev/null \
            | grep -vE "sender|receiver" | grep -oE "[0-9.]+ [KM]bits/sec" \
            | awk '{v=$1; if ($2=="Mbits/sec") v=v*1000; s+=v; n++} END {if(n>0) printf "%.0f Kbps", s/n; else print "sin datos"}')
        echo "| $c | ${CAUDALES[$i]} | ${med:-sin datos} |"
        i=$((i+1))
    done
    echo ""
    echo "El caudal conseguido depende de la atenuacion asignada a cada"
    echo "terminal en el broker (1.0 / 0.316 / 0.1): el tercero, con 20 dB"
    echo "de atenuacion, obtiene sistematicamente menos."
} >> "$SESION/README.md"

echo ""
echo "=========================================================="
ok "Sesion guardada en $SESION"
echo "  Para volver a levantar los terminales: ./lab-multiue.sh"
echo "=========================================================="
echo ""
