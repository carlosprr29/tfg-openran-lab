#!/bin/bash
# =============================================================================
# TFG OpenRAN Lab - analisis de las capturas de una sesion
# -----------------------------------------------------------------------------
# Extrae de los ficheros PCAP las cifras que no da iperf3: numero de paquetes,
# tamaños, reparto entre terminales, reintentos de acceso y evolucion temporal.
#
# Uso:
#   ./analiza.sh data/capturas/20261021-1219-base
#   ./analiza.sh --todas          compara todas las sesiones guardadas
#
# Genera un fichero analisis.md en cada carpeta de sesion y, con --todas,
# una tabla comparativa en data/capturas/COMPARATIVA.md
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# Tipo de enlace propio de srsRAN: hay que indicarle que el contenido es UDP
UDLT='uat:user_dlts:"User 2 (DLT=149)","udp","0","","0",""'

ts() { tshark -r "$1" -o "$UDLT" 2>/dev/null; }

analizar() {
    local dir="$1"
    local nombre
    nombre=$(basename "$dir")
    local out="$dir/analisis.md"

    [ -f "$dir/du_mac.pcap" ] || { echo "  (sin captura de la DU)"; return 1; }

    echo "# Analisis de la captura: $nombre" > "$out"
    echo "" >> "$out"
    echo "Generado el $(date '+%Y-%m-%d %H:%M')." >> "$out"
    echo "" >> "$out"

    # --- Volumen por terminal ------------------------------------------------
    echo "## Volumen capturado por terminal" >> "$out"
    echo "" >> "$out"
    echo "| Terminal | Paquetes | Bytes | Tamaño medio |" >> "$out"
    echo "|---|---|---|---|" >> "$out"
    for n in 1 2 3; do
        f="$dir/ue${n}_mac_nr.pcap"
        [ -f "$f" ] || continue
        pk=$(tshark -r "$f" -o "$UDLT" 2>/dev/null | wc -l)
        by=$(stat -c%s "$f" 2>/dev/null)
        med=$(awk -v p="${pk:-0}" -v b="${by:-0}" 'BEGIN{if(p>0) printf "%.0f B", b/p; else print "-"}')
        printf "| UE%s | %s | %s | %s |\n" "$n" "${pk:-0}" "${by:-0}" "$med" >> "$out"
    done
    echo "" >> "$out"

    # --- Reparto en la captura agregada de la DU -----------------------------
    echo "## Reparto de tráfico en la DU" >> "$out"
    echo "" >> "$out"
    local tot
    tot=$(ts "$dir/du_mac.pcap" | wc -l)
    echo "Paquetes totales en la captura agregada: **$tot**" >> "$out"
    echo "" >> "$out"
    echo "| Terminal | Paquetes | Porcentaje |" >> "$out"
    echo "|---|---|---|" >> "$out"
    local tmp; tmp=$(mktemp)
    ts "$dir/du_mac.pcap" > "$tmp"

    # El reparto se cuenta por el identificador que la celda asigna a cada
    # terminal (C-RNTI), presente en todas las tramas. El campo UEId solo
    # aparece en unas pocas lineas de control y no sirve para esto.
    local rnti_tmp; rnti_tmp=$(mktemp)
    # El nombre del campo varia segun la version del analizador
    local campo=""
    for cand in mac-nr.context.rnti mac-nr.rnti mac_nr.rnti; do
        if tshark -r "$dir/du_mac.pcap" -o "$UDLT" -T fields -e "$cand" -c 50 2>/dev/null \
             | grep -qE "^[0-9]+$"; then
            campo="$cand"; break
        fi
    done
    if [ -n "$campo" ]; then
        tshark -r "$dir/du_mac.pcap" -o "$UDLT" -T fields -e "$campo" 2>/dev/null \
            | grep -E "^[0-9]+$" | grep -v "^65535$" \
            | sort | uniq -c | sort -rn > "$rnti_tmp"
    else
        : > "$rnti_tmp"
    fi

    local i=1
    while read -r cnt id; do
        [ -z "$cnt" ] && continue
        pct=$(awk -v c="$cnt" -v t="$tot" 'BEGIN{if(t>0) printf "%.1f%%", 100*c/t; else print "-"}')
        printf "| RNTI %s | %s | %s |\n" "$id" "$cnt" "$pct" >> "$out"
        i=$((i+1))
        [ "$i" -gt 6 ] && break
    done < "$rnti_tmp"
    rm -f "$rnti_tmp"
    echo "" >> "$out"
    echo "Cada RNTI corresponde a un terminal. Se asignan de forma correlativa" >> "$out"
    echo "segun el orden de conexion." >> "$out"
    echo "" >> "$out"

    # --- Procedimiento de acceso --------------------------------------------
    echo "## Acceso a la celda" >> "$out"
    echo "" >> "$out"
    local rar rnti
    rar=$(grep -c "RAR " "$tmp" 2>/dev/null || echo 0)
    rnti=$(grep -oE "C-RNTI=[0-9]+" "$tmp" 2>/dev/null | sort -u | tr '\n' ' ')
    echo "- Respuestas de acceso aleatorio: **$rar**" >> "$out"
    echo "- Identificadores asignados: \`${rnti:-ninguno}\`" >> "$out"
    echo "" >> "$out"
    if [ "$rar" -gt 3 ]; then
        echo "Mas de tres accesos para tres terminales: hubo reintentos, señal de" >> "$out"
        echo "contienda en el canal de acceso." >> "$out"
    else
        echo "Un acceso por terminal, sin reintentos." >> "$out"
    fi
    echo "" >> "$out"

    # --- Tipos de canal ------------------------------------------------------
    echo "## Canales utilizados" >> "$out"
    echo "" >> "$out"
    echo "| Canal | Paquetes | Significado |" >> "$out"
    echo "|---|---|---|" >> "$out"
    for par in "SRB:1|Señalizacion (control)" "LCID:4|Portadora de datos" "UL-SCH|Subida compartida" "DL-SCH|Bajada compartida"; do
        pat="${par%%|*}"; desc="${par##*|}"
        c=$(grep -c "$pat" "$tmp" 2>/dev/null || echo 0)
        printf "| %s | %s | %s |\n" "$pat" "$c" "$desc" >> "$out"
    done
    echo "" >> "$out"

    # --- Evolucion temporal --------------------------------------------------
    echo "## Evolución temporal" >> "$out"
    echo "" >> "$out"
    echo "Paquetes por intervalo de 20 segundos en la captura agregada:" >> "$out"
    echo "" >> "$out"
    echo '```' >> "$out"
    tshark -r "$dir/du_mac.pcap" -o "$UDLT" -q -z io,stat,20 2>/dev/null \
        | sed -n '/Interval/,/^=\+$/p' | head -20 >> "$out"
    echo '```' >> "$out"
    echo "" >> "$out"

    # --- Relleno: recursos asignados frente a usados -------------------------
    echo "## Relleno (padding)" >> "$out"
    echo "" >> "$out"
    local pad_tot pad_n
    pad_n=$(grep -c "Padding" "$tmp" 2>/dev/null || echo 0)
    pad_tot=$(grep -oE "Padding [0-9]+ bytes" "$tmp" 2>/dev/null \
        | grep -oE "[0-9]+" | awk '{s+=$1} END{print s+0}')
    echo "- Paquetes con relleno: **$pad_n** de $tot" >> "$out"
    echo "- Bytes de relleno acumulados: **$pad_tot**" >> "$out"
    echo "" >> "$out"
    echo "El relleno mide los recursos que el planificador asigno y no se" >> "$out"
    echo "llegaron a usar. Mucho relleno con poco trafico indica holgura;" >> "$out"
    echo "poco relleno con mucho trafico indica que la celda va al limite." >> "$out"

    rm -f "$tmp"
    echo "  -> $out"
}

# ---------------------------------------------------------------------------
if [ "${1:-}" = "--todas" ]; then
    COMP="data/capturas/COMPARATIVA.md"
    echo "# Comparativa de sesiones" > "$COMP"
    echo "" >> "$COMP"
    echo "Generada el $(date '+%Y-%m-%d %H:%M')." >> "$COMP"
    echo "" >> "$COMP"
    echo "| Sesión | Paquetes DU | UE1 | UE2 | UE3 | Accesos | Relleno (B) |" >> "$COMP"
    echo "|---|---|---|---|---|---|---|" >> "$COMP"

    for d in data/capturas/*/; do
        [ -f "$d/du_mac.pcap" ] || continue
        nombre=$(basename "$d")
        echo "Analizando $nombre..."
        analizar "$d" >/dev/null

        tmp=$(mktemp); ts "$d/du_mac.pcap" > "$tmp"
        tot=$(wc -l < "$tmp")
        rar=$(grep -c "RAR " "$tmp" || echo 0)
        pad=$(grep -oE "Padding [0-9]+ bytes" "$tmp" | grep -oE "[0-9]+" \
              | awk '{s+=$1} END{print s+0}')
        rm -f "$tmp"

        # Los tres terminales, por paquetes en su propia captura
        for n in 1 2 3; do
            f="$d/ue${n}_mac_nr.pcap"
            if [ -f "$f" ]; then
                eval "u$n=\$(tshark -r \"$f\" -o \"\$UDLT\" 2>/dev/null | wc -l)"
            else
                eval "u$n=0"
            fi
        done

        printf "| %s | %s | %s | %s | %s | %s | %s |\n" \
            "${nombre#*-}" "$tot" "${u1:-0}" "${u2:-0}" "${u3:-0}" "$rar" "$pad" >> "$COMP"
    done
    echo ""
    echo "Comparativa en $COMP"
    cat "$COMP"
else
    DIR="${1:-}"
    [ -d "$DIR" ] || { echo "Uso: ./analiza.sh <carpeta_de_sesion> | --todas"; exit 1; }
    analizar "$DIR"
    echo ""
    cat "$DIR/analisis.md"
fi
