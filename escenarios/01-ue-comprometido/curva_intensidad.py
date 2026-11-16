#!/usr/bin/env python3
# =============================================================================
# curva_intensidad.py - Curva de detectabilidad de un ataque por intensidad
# -----------------------------------------------------------------------------
# Recorre todas las sesiones de un barrido de intensidades y, para cada una,
# calcula el factor de subida de una metrica durante la ventana de ataque
# respecto al trafico normal:
#
#     factor = media(metrica | fase ataque) / media(metrica | fases normales)
#
# Despues dibuja factor frente a intensidad. La grafica muestra donde el ataque
# deja de separarse del trafico normal y un umbral simple empieza a fallar, que
# es el punto en el que un detector basado en IA aporta valor.
#
# Uso:
#     ./curva_intensidad.py 01-ue-comprometido           (metrica por defecto)
#     ./curva_intensidad.py 01-ue-comprometido 2          (filtra por ue_id=2)
#     ./curva_intensidad.py 01-ue-comprometido 2 DRB.UEThpUl
#
# Las sesiones se buscan en:
#     data/escenarios/<prefijo>-<intensidad>-<fecha>/metricas.csv
#
# Cabecera esperada del CSV:
#     timestamp,t_rel,e2_node,ue_id,DRB.UEThpDl,DRB.UEThpUl,
#     DRB.RlcSduDelayDl,DRB.RlcDelayUl,
#     DRB.RlcSduTransmittedVolumeDL,DRB.RlcSduTransmittedVolumeUL
# =============================================================================
import csv
import glob
import os
import statistics
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
import numpy as np

# --- Parametros de la ventana de ataque (coinciden con ataque.sh) -----------
ATAQUE_INI = 60.0
ATAQUE_FIN = 120.0

# --- Argumentos -------------------------------------------------------------
if len(sys.argv) < 2:
    print("Uso: ./curva_intensidad.py <prefijo> [ue_id] [metrica]")
    print("Ej.: ./curva_intensidad.py 01-ue-comprometido 2 DRB.UEThpUl")
    sys.exit(1)

PREFIJO = sys.argv[1]
UE_ID = sys.argv[2] if len(sys.argv) > 2 else None
METRICA = sys.argv[3] if len(sys.argv) > 3 else "DRB.UEThpUl"

def localizar_base():
    """Busca data/escenarios subiendo desde el directorio actual.

    Asi da igual ejecutar el script desde la raiz del repo o desde la
    carpeta del escenario: encuentra la carpeta de datos en cualquier caso.
    """
    d = os.getcwd()
    while True:
        cand = os.path.join(d, "data", "escenarios")
        if os.path.isdir(cand):
            return cand
        padre = os.path.dirname(d)
        if padre == d:          # hemos llegado a la raiz del sistema
            return os.path.join(os.getcwd(), "data", "escenarios")
        d = padre


BASE = localizar_base()


import re

ETQ_VALIDA = re.compile(r"^\d+(\.\d+)?[KM]$", re.IGNORECASE)


def etiqueta_a_bits(etq):
    """Convierte '500K', '1M', '80K' en bits/s. None si no es una intensidad."""
    etq = etq.strip().upper()
    if not ETQ_VALIDA.match(etq):
        return None          # descarta sesiones antiguas sin etiqueta (fechas, etc.)
    mult = 1
    if etq.endswith("M"):
        mult, etq = 1_000_000, etq[:-1]
    elif etq.endswith("K"):
        mult, etq = 1_000, etq[:-1]
    return int(float(etq) * mult)


def factor_de_sesion(csv_path):
    """Devuelve (media_normal, media_ataque) de la metrica en una sesion.

    La referencia 'normal' es SOLO la fase previa al ataque (t < 60 s). La fase
    posterior no se usa como referencia: los buffers y el generador tardan en
    bajar y dejarian la base artificialmente alta, hundiendo el factor.

    La base normal se toma como MEDIANA de la fase previa, no como media: los
    primeros segundos tienen un transitorio de arranque que dispara la media de
    forma puntual. El ataque se toma como media, porque es un nivel sostenido.
    """
    normal, ataque = [], []
    with open(csv_path, newline="") as f:
        lector = csv.DictReader(f)
        campos = lector.fieldnames
        if campos is None or METRICA not in campos:
            print(f"      metrica '{METRICA}' no esta en la cabecera: {campos}")
            return None
        ue_vistos = set()
        for fila in lector:
            ue_vistos.add(fila.get("ue_id"))
            if UE_ID is not None and fila.get("ue_id") != UE_ID:
                continue
            try:
                t = float(fila["t_rel"])
                v = float(fila[METRICA])
            except (ValueError, KeyError):
                continue
            if ATAQUE_INI <= t <= ATAQUE_FIN:
                ataque.append(v)
            elif t < ATAQUE_INI:
                normal.append(v)
            # t > ATAQUE_FIN (fase de recuperacion): se ignora
    if not normal or not ataque:
        print(f"      filas normal={len(normal)} ataque={len(ataque)} "
              f"| ue_id pedido={UE_ID!r} | ue_id presentes={sorted(ue_vistos)}")
        return None
    return (statistics.median(normal), sum(ataque) / len(ataque))


# --- Recorrer sesiones y agrupar por intensidad -----------------------------
# Puede haber repeticiones de una misma intensidad: se promedian sus factores.
por_intensidad = defaultdict(list)
patron = os.path.join(BASE, f"{PREFIJO}-*")
sesiones = sorted(glob.glob(patron))

print(f"BASE  = {BASE}")
print(f"patron= {patron}")
print(f"sesiones encontradas: {len(sesiones)}")

if not sesiones:
    print(f"No hay sesiones que encajen con {patron}")
    sys.exit(1)

for ses in sesiones:
    nombre = os.path.basename(ses)                 # 01-ue-comprometido-500K-20261116-1012
    resto = nombre[len(PREFIJO) + 1:]              # 500K-20261116-1012
    etiqueta = resto.split("-")[0]                 # 500K
    if etiqueta_a_bits(etiqueta) is None:
        print(f"  (omitida) {nombre}: sin etiqueta de intensidad")
        continue
    csv_path = os.path.join(ses, "metricas.csv")
    if not os.path.isfile(csv_path):
        print(f"  (sin csv) {nombre}: no existe {csv_path}")
        continue
    res = factor_de_sesion(csv_path)
    if res is None:
        print(f"  (aviso) sin datos utiles en {nombre}")
        continue
    media_normal, media_ataque = res
    if media_normal <= 0:
        continue
    factor = media_ataque / media_normal
    por_intensidad[etiqueta].append(factor)
    print(f"  {etiqueta:>5}  normal {media_normal:7.0f}  "
          f"ataque {media_ataque:7.0f}  factor x{factor:.1f}")

if not por_intensidad:
    print("No se pudo calcular ningun factor. Revisa la metrica o el ue_id.")
    sys.exit(1)

# --- Preparar los puntos ordenados por intensidad ---------------------------
puntos = []
for etq, factores in por_intensidad.items():
    puntos.append((etiqueta_a_bits(etq), sum(factores) / len(factores), etq))
puntos.sort()
x = np.array([p[0] for p in puntos])
y = np.array([p[1] for p in puntos])

# --- Dibujo -----------------------------------------------------------------
fig, ax = plt.subplots(figsize=(9, 5.4))

# Zona donde un umbral deja de separar ataque de una subida legitima de carga.
ax.axhspan(1, 4, color="#c0392b", alpha=0.08, zorder=0)
ax.axhline(4, color="#c0392b", lw=1, ls="--", alpha=0.6, zorder=1)
ax.text(0.5, 0.11, "zona dificil para un umbral", transform=ax.transAxes,
        color="#c0392b", fontsize=9.5, ha="center", va="center")

ax.axhline(1, color="#7f8c8d", lw=1, ls=":", zorder=1)

ax.plot(x, y, "-o", color="#1f4e79", lw=1.8, ms=6.5, zorder=3,
        markerfacecolor="#2e6da4", markeredgecolor="#1f4e79")
for xi, yi in zip(x, y):
    ax.annotate(f"x{yi:.0f}", (xi, yi), textcoords="offset points",
                xytext=(0, 9), ha="center", fontsize=8.5, color="#1f4e79")

ax.set_xscale("log")
ax.set_xlabel(f"Intensidad del ataque  (caudal de subida del UE, bits/s)")
ax.set_ylabel(f"Factor de subida de {METRICA}\n(ataque / trafico normal)")
ax.set_title("Curva de detectabilidad del terminal comprometido", fontsize=13)

ax.set_xticks(x)
ax.set_xticklabels([p[2] for p in puntos])
ax.xaxis.set_minor_formatter(mticker.NullFormatter())
ax.set_ylim(0, max(y) * 1.1 + 1)
ax.grid(True, which="major", axis="y", alpha=0.25)

fig.tight_layout()
salida_dir = os.path.join(BASE, "curvas")
os.makedirs(salida_dir, exist_ok=True)
salida = os.path.join(salida_dir, f"curva_{PREFIJO}.png")
fig.savefig(salida, dpi=150)
print(f"\nGuardado: {salida}")
