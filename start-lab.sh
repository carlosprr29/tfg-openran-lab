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
RIC_DIR="./oran-sc-ric"
if [ -d "$RIC_DIR" ]; then
    (cd "$RIC_DIR" && docker compose up -d >/dev/null 2>&1)
    sleep 20
    # e2mgr suele morir en el primer intento por una condicion de carrera con
    # Redis (dbaas). Se relanza y luego se reinicia e2term para que se registre.
    if (cd "$RIC_DIR" && docker compose ps e2mgr 2>/dev/null | grep -q "Up"); then
        ok "RIC arriba (e2mgr sano a la primera)"
    else
        warn "e2mgr no arranco a la primera (carrera con Redis) - relanzando..."
        (cd "$RIC_DIR" && docker compose up -d e2mgr >/dev/null 2>&1)
        sleep 15
        (cd "$RIC_DIR" && docker compose restart e2term >/dev/null 2>&1)
        sleep 15
        if (cd "$RIC_DIR" && docker compose ps e2mgr 2>/dev/null | grep -q "Up"); then
            ok "RIC arriba tras relanzar e2mgr"
        else
            err "e2mgr sigue caido. Revisa: cd $RIC_DIR && docker compose logs e2mgr"
        fi
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
docker compose up -d ocudu-cu-cp
if wait_healthy ocudu-cu-cp 30; then
    ok "CU-CP sana"
else
    err "CU-CP no arranco bien tras 30s. Revisa: docker compose logs -n 40 ocudu-cu-cp"
fi

docker compose up -d ocudu-cu-up
if wait_up ocudu-cu-up 8; then
    ok "CU-UP arriba"
else
    err "CU-UP no arranco bien. Revisa: docker compose logs -n 40 ocudu-cu-up"
fi

echo ""
echo "=== 5. OCUDU: DU ==="
docker compose up -d ocudu-du
if wait_up ocudu-du 15; then
    ok "DU arriba (F1 establecido, celda activa)"
else
    err "DU no se quedo arriba. Revisa: cat ~/tfg-openran-lab/logs/ran/du/du.log"
fi

echo ""
echo "=== 6. UE simulado (srsUE, radio ZMQ) ==="
# IMPORTANTE: el UE hace connect contra el socket ZMQ de la DU (que hace bind),
# asi que la celda tiene que estar activa ANTES de arrancarlo. Si no, ambos
# extremos se quedan esperandose mutuamente sin emparejarse.
echo "Esperando a que la celda de la DU este activa..."
cell_ok=0
for i in $(seq 1 15); do
    if grep -q "Cell was activated" logs/ran/du/du.log 2>/dev/null; then
        cell_ok=1; break
    fi
    sleep 2
done
[ "$cell_ok" = "1" ] && ok "Celda activa" || warn "No se confirmo 'Cell was activated' en el log de la DU"

docker compose up -d ue-simulado
if wait_up ue-simulado 20; then
    ok "UE arriba"
    if docker compose logs ue-simulado 2>/dev/null | grep -q "PDU Session Establishment successful"; then
        ok "Sesion PDU establecida (registro end-to-end OK)"
    else
        warn "UE arriba pero sin confirmar sesion PDU todavia - dale unos segundos mas y revisa:"
        echo "    docker compose logs ue-simulado | grep -i 'pdu session\\|rrc release'"
    fi
else
    err "UE no se quedo arriba. Revisa: docker compose logs ue-simulado"
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
