#!/bin/bash
# =============================================================================
# Barrido de intensidades - jamming en la bajada (escenario 04)
# -----------------------------------------------------------------------------
# Lanza el ataque de jamming a varios niveles de ruido, de sutil a fuerte, para
# trazar la curva de detectabilidad. Cada sesion son 180 s (60 normal, 60 de
# ruido, 60 normal) y queda guardada aparte, con el nivel en el nombre.
#
# Niveles elegidos a partir de la calibracion: por debajo de ~0.004 apenas se
# nota, y a 0.015-0.020 UE3 ya se cae. El rango cubre la transicion completa.
#
# Uso:
#   ./escenarios/04-jamming-dl/barrido.sh
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

NIVELES=("0.003" "0.005" "0.008" "0.011" "0.015" "0.020")
DUR=180

echo ""
echo "############################################################"
echo "  Barrido de intensidades - jamming en la bajada"
echo "  Niveles: ${NIVELES[*]}"
echo "  ${#NIVELES[@]} sesiones de ${DUR}s cada una"
echo "############################################################"
echo ""
echo "Esto tardara un rato (unos 6-8 min por nivel)."
echo "Entre sesion y sesion se vuelve al escenario limpio."
echo ""

i=1
for N in "${NIVELES[@]}"; do
    echo "=== [$i/${#NIVELES[@]}] nivel $N ==="
    ./escenarios/04-jamming-dl/ataque.sh "$DUR" "$N"
    echo "nivel $N completado"
    echo ""
    i=$((i + 1))
done

echo "############################################################"
echo "  Barrido completo."
echo "  Sesiones en: data/escenarios/04-jamming-dl-<nivel>-<fecha>"
echo "############################################################"
