#!/bin/bash
# =============================================================================
# Terminal comprometido - barrido de intensidades
# -----------------------------------------------------------------------------
# Lanza el ataque a varias intensidades, de fuerte a suave, para trazar la
# curva de detectabilidad: a partir de que intensidad el ataque deja de
# distinguirse de un uso normal algo elevado.
#
# Cada intensidad genera su propia sesion en data/escenarios/ con capturas y
# metricas, etiquetada con el caudal usado.
#
# Uso:
#   ./escenarios/01-ue-comprometido/barrido.sh           intensidades por defecto
#   ./escenarios/01-ue-comprometido/barrido.sh 120       mismas, sesiones de 120 s
# =============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

VERDE='\033[0;32m'; AMAR='\033[1;33m'; NC='\033[0m'
DUR="${1:-180}"

# De mas fuerte (evidente) a mas suave (cercano a lo normal, ~50-100K).
# El terminal normalmente entrega ~50-120 Kbps, asi que 200K ya es sutil.
INTENSIDADES=("5M" "2M" "1M" "500K" "300K" "200K")

echo ""
echo "############################################################"
echo "  Barrido de intensidades - terminal comprometido"
echo "  Intensidades: ${INTENSIDADES[*]}"
echo "  ${#INTENSIDADES[@]} sesiones de ${DUR}s cada una"
echo "############################################################"
echo ""
echo "Esto tardara un rato (unos 6-7 min por intensidad)."
echo "Entre sesion y sesion se vuelve al escenario limpio."
echo ""

i=1
for intensidad in "${INTENSIDADES[@]}"; do
    echo -e "${AMAR}=== [$i/${#INTENSIDADES[@]}] Intensidad $intensidad ===${NC}"
    ./escenarios/01-ue-comprometido/ataque.sh "$DUR" "$intensidad"
    echo -e "${VERDE}Intensidad $intensidad completada${NC}"
    echo ""
    i=$((i+1))
done

echo "############################################################"
echo "  Barrido completo."
echo ""
echo "  Para generar las graficas de todas las sesiones:"
echo "    ./graficas.py --todas"
echo ""
echo "  Para comparar una intensidad con la linea base:"
echo "    ./graficas.py --comparar data/capturas/<base> \\"
echo "       data/escenarios/01-ue-comprometido-<intensidad>-<fecha>"
echo "############################################################"
