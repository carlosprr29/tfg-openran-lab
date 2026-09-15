#!/bin/bash
# ==============================================================================
# TFG OpenRAN Lab - arranque completo
# Levanta todo lo ya validado: Core 5G (Open5GS) + WebUI + OCUDU CU-CP/CU-UP.
# La DU se levanta al final, marcada aparte, porque todavia esta en pruebas.
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[AVISO]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# Espera activa a que un servicio con healthcheck pase a "healthy",
# en vez de un sleep fijo que puede dar falsos negativos.
wait_healthy() {
    local service="$1"
    local timeout="${2:-40}"
    local waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if docker compose ps "$service" 2>/dev/null | grep -q "healthy"; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# Espera activa a que un servicio (sin healthcheck) simplemente siga "Up"
# tras un margen, en vez de comprobar en el instante justo de arrancar.
wait_up() {
    local service="$1"
    local settle="${2:-8}"
    sleep "$settle"
    docker compose ps "$service" 2>/dev/null | grep -q "Up"
}

echo "=== 1. Prerrequisitos del host ==="

if ! lsmod | grep -q sctp; then
    warn "Modulo sctp no cargado, cargandolo (necesita sudo)..."
    sudo modprobe sctp || { err "No se pudo cargar sctp. El AMF/CU-CP no arrancaran."; exit 1; }
fi
ok "Modulo sctp cargado"

if ! swapon --show | grep -q .; then
    warn "No hay swap activo. Recomendado si vas a reconstruir OCUDU (compilaciones pesadas)."
else
    ok "Swap activo: $(swapon --show --noheadings | awk '{print $1, $3}')"
fi

echo ""
echo "=== 2. Near-RT RIC (O-RAN SC) ==="
# Secuencia critica (ver config/ric/NOTAS-RIC.md):
#   dbaas listo -> e2mgr conectado a Redis -> e2term registrado en RMR -> agentes E2
# Comprobar "Up" NO basta: ambos componentes pueden estar vivos pero degradados.
RIC_DIR="./oran-sc-ric"

ric_e2mgr_sano() {
    # e2mgr esta sano si, DESPUES de su ultimo arranque, aparece
    # "redis: got N elements in COMMAND reply" (conexion correcta a Redis)
    # en lugar de "connection refused".
    local started
    started=$(docker inspect ric_e2mgr --format '{{.State.StartedAt}}' 2>/dev/null)
    [ -z "$started" ] && return 1
    (cd "$RIC_DIR" && docker compose logs --since "$started" e2mgr 2>/dev/null) \
        | grep -q "redis: got"
}

ric_e2term_sano() {
    # e2term esta sano si, DESPUES de su ultimo arranque, no reporta
    # RMR_ERR_NOENDPT (que significa que no encontro a e2mgr al registrarse).
    # Se usa --since con la marca de arranque del contenedor: una ventana fija
    # abarcaria tambien el arranque anterior y daria un falso positivo.
    local started
    started=$(docker inspect ric_e2term --format '{{.State.StartedAt}}' 2>/dev/null)
    [ -z "$started" ] && return 1
    ! (cd "$RIC_DIR" && docker compose logs --since "$started" e2term 2>/dev/null) \
        | grep -q "RMR_ERR_NOENDPT"
}

# Espera a que la CU-UP complete su asociacion E1 con la CU-CP.
# Que el contenedor este "Up" NO basta: si el UE llega antes de que E1 este
# operativo, la RAN rechaza el PDU Session Resource Setup y el AMF reporta
# Cause[Group:4 Cause:3] (radio network layer), liberando el contexto del UE.
wait_e1_asociado() {
    local timeout="${1:-40}"
    local waited=0 started
    started=$(docker inspect ran-cu-up --format '{{.State.StartedAt}}' 2>/dev/null)
    [ -z "$started" ] && return 1
    while [ "$waited" -lt "$timeout" ]; do
        if docker compose logs --since "$started" ocudu-cu-up 2>/dev/null \
            | grep -q "E1: Connection to CU-CP completed"; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

# Comprueba si el UE ha establecido sesion PDU en su arranque actual.
ue_con_sesion() {
    local started
    started=$(docker inspect ue-srsue --format '{{.State.StartedAt}}' 2>/dev/null)
    [ -z "$started" ] && return 1
    docker compose logs --since "$started" ue-simulado 2>/dev/null \
        | grep -q "PDU Session Establishment successful"
}

if [ -d "$RIC_DIR" ]; then
    (cd "$RIC_DIR" && docker compose up -d >/dev/null 2>&1)
    echo "Esperando a que Redis y e2mgr esten operativos..."
    sleep 20

    if ric_e2mgr_sano; then
        ok "e2mgr conectado a Redis"
    else
        warn "e2mgr no conecto a Redis (carrera) - relanzando..."
        (cd "$RIC_DIR" && docker compose restart e2mgr >/dev/null 2>&1)
        sleep 20
        if ric_e2mgr_sano; then
            ok "e2mgr conectado a Redis tras relanzar"
        else
            err "e2mgr sigue sin conectar a Redis."
            echo "    Revisa: cd $RIC_DIR && docker compose logs e2mgr"
        fi
    fi

    # e2term SIEMPRE se reinicia despues de e2mgr: es la unica forma de
    # garantizar que se registra en RMR con el gestor E2 ya operativo.
    echo "Reiniciando e2term para que se registre con e2mgr..."
    (cd "$RIC_DIR" && docker compose restart e2term >/dev/null 2>&1)
    sleep 20

    if ric_e2term_sano; then
        ok "e2term registrado en RMR y escuchando en SCTP 36421"
    else
        err "e2term reporta RMR_ERR_NOENDPT (no encontro a e2mgr)."
        echo "    Revisa: cd $RIC_DIR && docker compose logs e2term"
    fi
else
    warn "No se encuentra $RIC_DIR - se omite el RIC (la CU-CP y la DU fallaran si ric_net no existe)"
fi

echo ""
echo "=== 3. Core 5G (Open5GS) + WebUI ==="
docker compose up -d mongodb open5gs-nrf open5gs-ausf open5gs-udm open5gs-udr \
    open5gs-pcf open5gs-bsf open5gs-nssf open5gs-amf open5gs-upf open5gs-smf open5gs-webui

echo "Esperando a que el Core quede sano..."
if wait_healthy open5gs-amf 40; then
    ok "Core 5G sano (AMF healthy)"
else
    err "El AMF no reporta 'healthy' tras 40s. Revisa: docker compose logs -n 40 open5gs-amf"
fi

echo ""
echo "=== 4. OCUDU: CU-CP y CU-UP ==="
# Los tiempos de esta seccion no son arbitrarios: comprobar "Up"/"healthy" no
# garantiza que las asociaciones entre componentes esten operativas. Si el UE
# llega antes de que E1 (CU-CP <-> CU-UP) este establecido, la RAN rechaza el
# establecimiento de la sesion PDU.
docker compose up -d ocudu-cu-cp
if wait_healthy ocudu-cu-cp 40; then
    ok "CU-CP sana"
else
    err "CU-CP no arranco bien tras 40s. Revisa: docker compose logs -n 40 ocudu-cu-cp"
fi

# Margen para que la CU-CP termine de inicializar su servidor E1
sleep 15

docker compose up -d ocudu-cu-up
if wait_up ocudu-cu-up 10; then
    ok "CU-UP arriba"
else
    err "CU-UP no arranco bien. Revisa: docker compose logs -n 40 ocudu-cu-up"
fi

echo "Esperando a que se establezca la asociacion E1..."
if wait_e1_asociado 40; then
    ok "E1 establecido (CU-UP asociada a CU-CP)"
else
    err "No se confirmo la asociacion E1 tras 40s."
    echo "    El UE no podra establecer sesion de datos."
    echo "    Revisa: docker compose logs ocudu-cu-up"
fi

echo ""
echo "=== 5. OCUDU: DU ==="
docker compose up -d ocudu-du
if wait_up ocudu-du 20; then
    ok "DU arriba"
else
    err "DU no se quedo arriba. Revisa: cat ~/tfg-openran-lab/logs/ran/du/du.log"
fi

echo ""
echo "=== 6. UE simulado (srsUE, radio ZMQ) ==="
# IMPORTANTE: el UE hace connect contra el socket ZMQ de la DU (que hace bind),
# asi que la celda tiene que estar activa ANTES de arrancarlo. Si no, ambos
# extremos se quedan esperandose mutuamente sin emparejarse.
#
# La comprobacion NO puede buscar "Cell was activated" en todo el fichero: ese
# log se conserva entre arranques y encontraria el mensaje de una sesion
# anterior, dando via libre al UE antes de tiempo. Se compara con la marca de
# arranque del contenedor de la DU.
echo "Esperando a que la celda de la DU este activa..."
du_started=$(docker inspect ran-du --format '{{.State.StartedAt}}' 2>/dev/null | cut -c1-19)
cell_ok=0
for i in $(seq 1 20); do
    # Lineas de activacion de celda posteriores al arranque del contenedor
    if [ -f logs/ran/du/du.log ] && \
       awk -v ts="$du_started" '/Cell was activated/ { if (substr($0,1,19) >= ts) found=1 } END { exit !found }' \
           logs/ran/du/du.log 2>/dev/null; then
        cell_ok=1; break
    fi
    sleep 3
done
if [ "$cell_ok" = "1" ]; then
    ok "Celda activa (posterior al arranque de la DU)"
else
    warn "No se confirmo una activacion de celda posterior al arranque de la DU."
    echo "    El UE puede no emparejarse por ZMQ. Si falla, ver config/NOTAS-ARRANQUE.md"
fi

# Margen adicional: la celda esta activa, pero la cadena F1/E1 necesita unos
# segundos mas para quedar plenamente operativa antes de que llegue el UE.
echo "Margen para que la cadena RAN se estabilice..."
sleep 20

docker compose up -d ue-simulado
if wait_up ue-simulado 25; then
    ok "UE arriba"
    # Esperar activamente a la sesion PDU (puede tardar ~15-20 s)
    sesion_ok=0
    for i in $(seq 1 12); do
        if ue_con_sesion; then sesion_ok=1; break; fi
        sleep 3
    done

    if [ "$sesion_ok" = "1" ]; then
        ok "Sesion PDU establecida (registro end-to-end OK)"
    else
        # Reintento automatico: la receta conocida es reiniciar la DU (que hace
        # bind del socket ZMQ) y despues el UE (que hace connect).
        warn "Sin sesion PDU. Reintentando con reinicio ordenado DU -> UE..."
        docker compose stop ue-simulado >/dev/null 2>&1
        docker compose restart ocudu-du >/dev/null 2>&1
        echo "    Esperando a la DU (incluye el time-to-wait de 60 s del RIC)..."
        sleep 75
        docker compose up -d ue-simulado >/dev/null 2>&1
        sleep 25

        sesion_ok=0
        for i in $(seq 1 10); do
            if ue_con_sesion; then sesion_ok=1; break; fi
            sleep 3
        done

        if [ "$sesion_ok" = "1" ]; then
            ok "Sesion PDU establecida tras el reintento"
        else
            err "El UE no consigue establecer sesion PDU."
            echo "    Diagnostico: ver config/NOTAS-ARRANQUE.md"
            echo "    docker compose logs ue-simulado | grep -i 'pdu session\\|rrc release'"
            echo "    docker compose logs open5gs-amf | tail -25"
        fi
    fi
else
    err "UE no se quedo arriba. Revisa: docker compose logs ue-simulado"
fi

echo ""
echo "=== Verificacion del plano de usuario (end-to-end) ==="
if docker exec ue-srsue ping -c 2 -W 3 10.45.0.1 >/dev/null 2>&1; then
    ok "Ping UE -> UPF correcto: trafico de datos circulando de extremo a extremo"
else
    warn "El ping UE -> UPF no responde. Comprueba la sesion PDU:"
    echo "    docker exec ue-srsue ip addr show tun_srsue"
    echo "    docker exec -it ue-srsue ping -c 4 10.45.0.1"
fi

echo ""
echo "=== Verificacion del registro E2 en el RIC ==="
if [ -d "$RIC_DIR" ]; then
    e2_states=$(docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states 2>/dev/null)
    if echo "$e2_states" | grep -q '"connectionStatus":"CONNECTED"'; then
        n_conn=$(echo "$e2_states" | grep -o '"CONNECTED"' | wc -l)
        ok "Nodos E2 conectados: $n_conn"
    elif echo "$e2_states" | grep -q "DISCONNECTED"; then
        warn "Hay nodos E2 registrados pero DISCONNECTED. Los agentes reintentan solos;"
        echo "    espera 1-2 min y vuelve a comprobar con:"
        echo "    docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states"
    else
        warn "Ningun nodo E2 registrado todavia (puede tardar). Comprueba con:"
        echo "    docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states"
    fi
fi

echo ""
echo "=== Estado final de todos los contenedores ==="
docker compose ps

echo ""
echo "=== Verificacion rapida del suscriptor de prueba ==="
docker exec -it core-mongodb mongosh open5gs --quiet --eval '
print("Suscriptores:", db.subscribers.countDocuments());
print("Cuentas WebUI:", db.accounts.countDocuments());
' 2>/dev/null || warn "No se pudo consultar Mongo todavia (puede tardar unos segundos mas en arrancar)"

echo ""
echo "WebUI disponible en: http://localhost:9999  (o via tunel SSH si trabajas en remoto)"
