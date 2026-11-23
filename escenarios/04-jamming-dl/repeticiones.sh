#!/bin/bash
# =============================================================================
# Repeticiones del barrido - jamming en la bajada (escenario 04)
# -----------------------------------------------------------------------------
# Repite unos niveles clave varias veces para que la curva deje de ser una sola
# toma y pase a ser una media con dispersion. Se eligen los niveles de la zona
# interesante (sutil y arranque de la caida), que son los que mas bailan.
#
# Cada repeticion queda guardada como una sesion aparte (el nombre lleva fecha y
# hora al minuto), asi que no se pisan entre si. Con la del barrido original,
# cada nivel acaba teniendo REPS+1 tomas.
#
# Uso:
#   ./escenarios/04-jamming-dl/repeticiones.sh        2 repeticiones por nivel
#   ./escenarios/04-jamming-dl/repeticiones.sh 3      3 repeticiones por nivel
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

NIVELES=("0.005" "0.008" "0.011")
REPS="${1:-2}"
DUR=180

echo ""
echo "############################################################"
echo "  Repeticiones del barrido - jamming en la bajada"
echo "  Niveles: ${NIVELES[*]}   |   repeticiones por nivel: $REPS"
echo "  Total: $(( ${#NIVELES[@]} * REPS )) sesiones de ${DUR}s"
echo "############################################################"
echo ""

for N in "${NIVELES[@]}"; do
    for r in $(seq 1 "$REPS"); do
        echo "=== nivel $N, repeticion $r/$REPS ==="
        ./escenarios/04-jamming-dl/ataque.sh "$DUR" "$N"
        echo "nivel $N, repeticion $r completada"
        echo ""
    done
done

echo "############################################################"
echo "  Repeticiones completas."
echo "############################################################"
