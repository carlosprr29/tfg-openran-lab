#!/bin/bash
# =============================================================================
# Mide el caudal del enlace ZMQ y el estado de los terminales.
#
# IMPORTANTE: localiza la interfaz por su DIRECCION IP, no por nombre.
# Docker no garantiza el orden de las interfaces al recrear un contenedor:
# la red principal puede ser eth0 en un arranque y eth1 en el siguiente.
# Medir por nombre nos llevo semanas de diagnosticos erroneos.
#
# Uso:
#   ./caudal.sh           mide 10 segundos
#   ./caudal.sh 30        mide 30 segundos
#
# Referencias medidas en este laboratorio (en 10 s, cada sentido):
#   Enlace directo, 1 terminal ....... ~1,59 GB   (159 MB/s)
#   Con broker, 2 terminales ......... ~1,00 GB   (100 MB/s)
# =============================================================================
set -uo pipefail

SEG="${1:-10}"

# Caudal de un contenedor, buscando la interfaz por su IP
iface_bytes() {
    docker exec "$1" sh -c "
        IF=\$(ip -o addr show | grep '$2' | awk '{print \$2}')
        [ -z \"\$IF\" ] && echo 'NA NA NA' && exit
        grep \"\$IF\" /proc/net/dev | awk -v i=\"\$IF\" '{print i, \$2, \$10}'
    " 2>/dev/null || echo "NA NA NA"
}

# Contenedores a medir: nombre, IP de la red principal, etiqueta
MEDIR=(
    "ran-du|10.0.0.24|DU (radio ZMQ)"
    "ue-broker|10.0.0.35|Broker"
    "ue-srsue|10.0.0.30|UE1"
    "ue-srsue2|10.0.0.31|UE2"
    "ue-srsue3|10.0.0.32|UE3"
)

declare -A ANTES_RX ANTES_TX IFACE

for m in "${MEDIR[@]}"; do
    IFS='|' read -r cont ip etiq <<< "$m"
    docker ps --format '{{.Names}}' | grep -q "^${cont}$" || continue
    read -r i rx tx <<< "$(iface_bytes "$cont" "$ip")"
    IFACE["$cont"]="$i"; ANTES_RX["$cont"]="$rx"; ANTES_TX["$cont"]="$tx"
done

echo "Midiendo durante ${SEG} s..."
sleep "$SEG"

echo ""
printf "%-18s %-7s %12s %12s\n" "COMPONENTE" "IFAZ" "RX" "TX"
printf "%-18s %-7s %12s %12s\n" "------------------" "-------" "------------" "------------"

for m in "${MEDIR[@]}"; do
    IFS='|' read -r cont ip etiq <<< "$m"
    [ -z "${ANTES_RX[$cont]:-}" ] && continue
    read -r i rx tx <<< "$(iface_bytes "$cont" "$ip")"
    drx=$(( rx - ${ANTES_RX[$cont]} ))
    dtx=$(( tx - ${ANTES_TX[$cont]} ))

    fmt() {
        if   [ "$1" -gt 1048576 ]; then echo "$(( $1 / 1048576 )) MB"
        elif [ "$1" -gt 1024 ];    then echo "$(( $1 / 1024 )) KB"
        else echo "$1 B"; fi
    }
    printf "%-18s %-7s %12s %12s\n" "$etiq" "$i" "$(fmt $drx)" "$(fmt $dtx)"
done

echo ""
echo "Sesiones de datos:"
for c in ue-srsue ue-srsue2 ue-srsue3; do
    docker ps --format '{{.Names}}' | grep -q "^${c}$" || continue
    ip=$(docker exec "$c" ip -4 addr show tun_srsue 2>/dev/null \
        | grep -oE 'inet [0-9.]+' | awk '{print $2}')
    printf "  %-12s %s\n" "$c" "${ip:-sin sesion}"
done
