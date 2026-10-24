#!/bin/bash
# =============================================================================
# TFG OpenRAN Lab - sesiones de captura para el estudio de metricas
# -----------------------------------------------------------------------------
# Genera trafico controlado con los tres terminales y guarda, en una carpeta
# con fecha: las capturas PCAP de cada terminal y de la DU, el trafico medido
# por iperf3, las metricas recogidas por el interfaz E2 y una ficha con los
# parametros usados.
#
# Las metricas se recogen solo si el RIC esta levantado y sus nodos E2 estan
# conectados. Si no lo estan, el script intenta reconectarlos reiniciando el
# terminador E2 y la DU; si aun asi no se consigue, toma la captura sin
# metricas en lugar de abortar.
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
METRICAS="DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl,DRB.RlcDelayUl,DRB.RlcSduTransmittedVolumeDL,DRB.RlcSduTransmittedVolumeUL"
E2_NODO=""
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
SESION_ABS="$(pwd)/$SESION"

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

# --- Comprobar el interfaz E2 -----------------------------------------------
# La xApp no puede suscribirse a un nodo que no este CONNECTED. El reinicio de
# la DU, que forma parte del arranque del escenario, rompe con frecuencia esa
# asociacion: el terminador E2 pierde su registro en la mensajeria interna del
# RIC y rechaza el alta con "cause=unknown". La receta conocida es reiniciar
# e2term DESPUES de que e2mgr este operativo.
e2_conectados() {
    docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null \
        | grep -o '"connectionStatus":"CONNECTED"' | wc -l
}

e2_nodo_du() {
    docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null \
        | grep -oE '"inventoryName":"gnbd_[^"]*"' | head -1 \
        | sed 's/.*:"//;s/"//'
}

preparar_e2() {
    docker ps --format '{{.Names}}' | grep -q '^ric_e2mgr$' || {
        avis "El RIC no esta levantado: no se recogeran metricas"
        return 1
    }

    if [ "$(e2_conectados)" -ge 2 ]; then
        ok "Nodos E2 conectados"
    else
        avis "Nodos E2 desconectados; reiniciando e2term"
        (cd oran-sc-ric && docker compose restart e2term >/dev/null 2>&1)
        sleep 30
        $C restart ocudu-du >/dev/null 2>&1
        sleep 80
        if [ "$(e2_conectados)" -ge 2 ]; then
            ok "Nodos E2 reconectados"
        else
            avis "Los nodos E2 siguen desconectados: se tomara la captura sin metricas"
            return 1
        fi
    fi

    E2_NODO=$(e2_nodo_du)
    [ -n "$E2_NODO" ] || { avis "No se identifico el nodo de la DU"; return 1; }
    ok "Nodo E2 de la DU: $E2_NODO"
    return 0
}

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
# --- Recoleccion de metricas por E2 -----------------------------------------
METRICAS_OK=0
echo ""
if preparar_e2; then
    cp xapp_ai/kpm_csv_xapp.py oran-sc-ric/xApps/python/ 2>/dev/null
    chmod +x oran-sc-ric/xApps/python/kpm_csv_xapp.py 2>/dev/null
    # Un CSV de una sesion anterior falsearia el resultado si la xApp fallara
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner \
        rm -f /tmp/metricas_sesion.csv >/dev/null 2>&1)
    METRICAS_OK=1
fi

echo ""
echo ">> Generando trafico durante ${DUR} s..."
echo "   (no interrumpas el proceso: las capturas se escriben al final)"

# La xApp se lanza en segundo plano, con la misma duracion que el trafico, de
# modo que la serie de metricas cubra exactamente la misma ventana temporal
# que las capturas.
if [ "$METRICAS_OK" = "1" ]; then
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner \
        ./kpm_csv_xapp.py \
        --e2_node_id="$E2_NODO" \
        --metrics="$METRICAS" \
        --kpm_report_style=5 \
        --output=/tmp/metricas_sesion.csv \
        --duration=$((DUR + 10)) > "$SESION_ABS/xapp.log" 2>&1) &
    XAPP_PID=$!
    sleep 5
    ok "Recoleccion de metricas en marcha"
fi

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

# --- Recoger las metricas ---------------------------------------------------
if [ "$METRICAS_OK" = "1" ]; then
    echo ">> Esperando a que la xApp termine de recoger"
    wait "$XAPP_PID" 2>/dev/null
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner \
        cat /tmp/metricas_sesion.csv 2>/dev/null) > "$SESION_ABS/metricas.csv"
    n=$(($(wc -l < "$SESION/metricas.csv") - 1))
    if [ "$n" -gt 0 ]; then
        ok "Metricas recogidas: $n filas"
    else
        avis "El fichero de metricas quedo vacio; ver $SESION/xapp.log"
    fi
fi

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

# --- Resumen de las metricas ------------------------------------------------
if [ -s "$SESION/metricas.csv" ]; then
    echo ""
    echo "  Metricas por terminal (media de la sesion):"
    awk -F, 'NR>1 && $4!="" {
        n[$4]++
        for (i=5; i<=NF; i++) if ($i != "") { s[$4,i]+=$i; c[$4,i]++ }
    }
    END {
        for (u in n) {
            printf "    UE id=%-3s  muestras=%-5d", u, n[u]
            for (i=5; i<=7; i++) {
                if (c[u,i]>0) printf "  %.1f", s[u,i]/c[u,i]; else printf "  -"
            }
            printf "\n"
        }
    }' "$SESION/metricas.csv" | sort

    {
        echo ""
        echo "## Metricas recogidas por E2"
        echo ""
        echo "Fichero: \`metricas.csv\` — una fila por terminal y periodo de informe."
        echo ""
        echo "Columnas: timestamp, t_rel, e2_node, ue_id, y una por metrica:"
        echo ""
        echo '```'
        echo "$METRICAS" | tr ',' '\n' | sed 's/^/  /'
        echo '```'
        echo ""
        echo "Filas: $(($(wc -l < "$SESION/metricas.csv") - 1))"
        echo ""
        echo "Los identificadores de terminal del controlador (0, 1, 2) no coinciden"
        echo "con los de la captura (C-RNTI 17921 y siguientes): el RIC emplea su"
        echo "propia numeracion interna."
    } >> "$SESION/README.md"
fi

echo ""
echo "=========================================================="
ok "Sesion guardada en $SESION"
echo "  Para volver a levantar los terminales: ./lab-multiue.sh"
echo "=========================================================="
echo ""
