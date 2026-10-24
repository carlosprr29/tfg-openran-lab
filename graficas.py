#!/usr/bin/env python3
"""
Genera graficas a partir de los CSV de metricas de las sesiones de captura.

Lee data/capturas/<sesion>/metricas.csv y produce, en una carpeta graficas/
dentro de cada sesion:
  - caudal_subida.png     throughput UL de los tres terminales en el tiempo
  - retardo.png           retardo UL y DL en el tiempo
  - volumen.png           volumen transmitido en el tiempo
  - comparativa_*.png     (con --comparar) un perfil frente a otro

Pensado para que, cuando mas adelante se inyecte un ataque, la misma
herramienta compare la sesion normal con la sesion bajo ataque.

Uso:
  ./graficas.py data/capturas/20261022-1705-base
  ./graficas.py --todas
  ./graficas.py --comparar <sesion_normal> <sesion_ataque>
"""

import sys
import os
import glob
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import pandas as pd

# Colores fijos por terminal, coherentes en todas las graficas
COLOR = {0: '#2E5395', 1: '#E8872B', 2: '#C0392B'}
NOMBRE = {0: 'UE1 (0 dB)', 1: 'UE2 (10 dB)', 2: 'UE3 (20 dB)'}

plt.rcParams.update({
    'font.size': 11, 'font.family': 'sans-serif',
    'axes.grid': True, 'grid.alpha': 0.3,
    'figure.figsize': (10, 4.5), 'figure.dpi': 110,
})


def cargar(sesion):
    f = os.path.join(sesion, 'metricas.csv')
    if not os.path.exists(f) or os.path.getsize(f) < 50:
        return None
    try:
        df = pd.read_csv(f)
    except Exception:
        return None
    if df.empty or 'ue_id' not in df.columns:
        return None
    df = df[df['ue_id'].notna()].copy()
    df['ue_id'] = df['ue_id'].astype(int)
    return df


def _linea(ax, df, col, titulo, ylabel):
    for uid in sorted(df['ue_id'].unique()):
        d = df[(df['ue_id'] == uid) & (df[col].notna())]
        if len(d):
            ax.plot(d['t_rel'], d[col], color=COLOR.get(uid, 'gray'),
                    label=NOMBRE.get(uid, f'UE{uid}'), linewidth=1.5, marker='.', markersize=3)
    ax.set_title(titulo)
    ax.set_xlabel('Tiempo (s)')
    ax.set_ylabel(ylabel)
    ax.legend(loc='upper right', fontsize=9)


def graficar(sesion):
    df = cargar(sesion)
    if df is None:
        print(f"  (sin metricas en {sesion})")
        return
    out = os.path.join(sesion, 'graficas')
    os.makedirs(out, exist_ok=True)
    perfil = os.path.basename(sesion).split('-')[-1]

    # Caudal de subida
    if 'DRB.UEThpUl' in df.columns:
        fig, ax = plt.subplots()
        _linea(ax, df, 'DRB.UEThpUl', f'Caudal de subida — perfil {perfil}', 'Caudal (unidades E2)')
        fig.tight_layout(); fig.savefig(os.path.join(out, 'caudal_subida.png')); plt.close(fig)

    # Retardo UL y DL
    cols_ret = [c for c in ('DRB.RlcDelayUl', 'DRB.RlcSduDelayDl') if c in df.columns]
    if cols_ret:
        fig, axes = plt.subplots(1, len(cols_ret), figsize=(11, 4.2))
        if len(cols_ret) == 1:
            axes = [axes]
        tit = {'DRB.RlcDelayUl': 'Retardo de subida', 'DRB.RlcSduDelayDl': 'Retardo de bajada'}
        for ax, col in zip(axes, cols_ret):
            _linea(ax, df, col, f'{tit[col]} — {perfil}', 'Retardo (ms)')
        fig.tight_layout(); fig.savefig(os.path.join(out, 'retardo.png')); plt.close(fig)

    # Volumen de subida
    if 'DRB.RlcSduTransmittedVolumeUL' in df.columns:
        fig, ax = plt.subplots()
        _linea(ax, df, 'DRB.RlcSduTransmittedVolumeUL', f'Volumen de subida — perfil {perfil}', 'Volumen (unidades E2)')
        fig.tight_layout(); fig.savefig(os.path.join(out, 'volumen.png')); plt.close(fig)

    # Numero de muestras por terminal (actividad)
    fig, ax = plt.subplots(figsize=(7, 4))
    conteo = df.groupby('ue_id').size()
    ax.bar([NOMBRE.get(u, f'UE{u}') for u in conteo.index],
           conteo.values, color=[COLOR.get(u, 'gray') for u in conteo.index])
    ax.set_title(f'Muestras recibidas por terminal — {perfil}')
    ax.set_ylabel('Número de muestras')
    fig.tight_layout(); fig.savefig(os.path.join(out, 'muestras.png')); plt.close(fig)

    print(f"  -> {out}/ (4 graficas)")


def comparar(s_normal, s_ataque, col='DRB.UEThpUl'):
    """Superpone la misma metrica de dos sesiones, terminal a terminal."""
    dn = cargar(s_normal)
    da = cargar(s_ataque)
    if dn is None or da is None:
        print("Falta alguna de las dos sesiones"); return
    out = 'data/capturas/comparativas'
    os.makedirs(out, exist_ok=True)

    fig, axes = plt.subplots(1, 3, figsize=(14, 4.2), sharey=True)
    for ax, uid in zip(axes, (0, 1, 2)):
        n = dn[(dn['ue_id'] == uid) & (dn[col].notna())]
        a = da[(da['ue_id'] == uid) & (da[col].notna())]
        ax.plot(n['t_rel'], n[col], color='#2E5395', label='Normal', linewidth=1.5)
        ax.plot(a['t_rel'], a[col], color='#C0392B', label='Bajo ataque', linewidth=1.5)
        ax.set_title(NOMBRE.get(uid))
        ax.set_xlabel('Tiempo (s)')
        ax.legend(fontsize=9)
    axes[0].set_ylabel(col)
    fig.suptitle(f'{col}: normal frente a ataque', fontsize=13)
    fig.tight_layout()
    nombre = f"comp_{os.path.basename(s_ataque)}_{col.replace('.', '_')}.png"
    fig.savefig(os.path.join(out, nombre)); plt.close(fig)
    print(f"Comparativa en {out}/{nombre}")




# Orden canonico de los perfiles, de menos a mas carga
ORDEN_PERFIL = ['holgado', 'base', 'contencion', 'asimetrico']
TITULO_PERFIL = {
    'holgado': 'Holgado (100/100/50 Kbps)',
    'base': 'Base (500 Kbps los tres)',
    'contencion': 'Contencion (5 Mbps los tres)',
    'asimetrico': 'Asimetrico (5M/300/300 Kbps)',
}


def _sesion_de_perfil(perfil):
    """Devuelve la carpeta mas reciente de un perfil dado."""
    cand = sorted(glob.glob(f'data/capturas/*-{perfil}/'))
    return cand[-1].rstrip('/') if cand else None


def panel_perfiles(col, titulo_metrica, ylabel):
    """Rejilla 2x2: la misma metrica en los cuatro perfiles."""
    out = 'data/capturas/paneles'
    os.makedirs(out, exist_ok=True)

    fig, axes = plt.subplots(2, 2, figsize=(13, 8), sharex=True)
    axes = axes.flatten()
    hay_datos = False

    for ax, perfil in zip(axes, ORDEN_PERFIL):
        ses = _sesion_de_perfil(perfil)
        df = cargar(ses) if ses else None
        if df is None or col not in df.columns:
            ax.set_title(f'{TITULO_PERFIL[perfil]} (sin datos)')
            ax.text(0.5, 0.5, 'sin datos', ha='center', va='center', transform=ax.transAxes)
            continue
        hay_datos = True
        for uid in sorted(df['ue_id'].unique()):
            d = df[(df['ue_id'] == uid) & (df[col].notna())]
            if len(d):
                ax.plot(d['t_rel'], d[col], color=COLOR.get(uid, 'gray'),
                        label=NOMBRE.get(uid), linewidth=1.3)
        ax.set_title(TITULO_PERFIL[perfil])
        ax.set_ylabel(ylabel)
        ax.legend(fontsize=8, loc='upper right')

    for ax in axes[2:]:
        ax.set_xlabel('Tiempo (s)')

    fig.suptitle(f'{titulo_metrica} — comparacion entre perfiles', fontsize=14, y=0.995)
    fig.tight_layout()
    if hay_datos:
        nombre = f'panel_{col.replace(".", "_")}.png'
        fig.savefig(os.path.join(out, nombre))
        print(f"  -> {out}/{nombre}")
    plt.close(fig)


def _panel_muestras():
    """Barras de muestras por terminal en los cuatro perfiles."""
    out = 'data/capturas/paneles'
    os.makedirs(out, exist_ok=True)
    fig, axes = plt.subplots(2, 2, figsize=(11, 7), sharey=True)
    axes = axes.flatten()
    for ax, perfil in zip(axes, ORDEN_PERFIL):
        ses = _sesion_de_perfil(perfil)
        df = cargar(ses) if ses else None
        if df is None:
            ax.set_title(f'{TITULO_PERFIL[perfil]} (sin datos)'); continue
        conteo = df.groupby('ue_id').size()
        ax.bar([NOMBRE.get(u, f'UE{u}') for u in conteo.index],
               conteo.values, color=[COLOR.get(u, 'gray') for u in conteo.index])
        ax.set_title(TITULO_PERFIL[perfil])
        ax.set_ylabel('Muestras')
    fig.suptitle('Muestras recibidas por terminal — comparacion entre perfiles', fontsize=14)
    fig.tight_layout()
    fig.savefig(os.path.join(out, 'panel_muestras.png'))
    print(f"  -> {out}/panel_muestras.png")
    plt.close(fig)


def paneles():
    print("Generando paneles comparativos...")
    panel_perfiles('DRB.UEThpUl', 'Caudal de subida', 'Caudal (unidades E2)')
    panel_perfiles('DRB.RlcDelayUl', 'Retardo de subida', 'Retardo (ms)')
    panel_perfiles('DRB.RlcSduDelayDl', 'Retardo de bajada', 'Retardo (ms)')
    _panel_muestras()


if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Uso: ./graficas.py <sesion> | --todas | --perfiles | --comparar <normal> <ataque>")
        sys.exit(1)

    if sys.argv[1] == '--perfiles':
        paneles()
    elif sys.argv[1] == '--todas':
        for d in sorted(glob.glob('data/capturas/*/')):
            if os.path.exists(os.path.join(d, 'metricas.csv')):
                print(f"Graficando {os.path.basename(d.rstrip('/'))}...")
                graficar(d.rstrip('/'))
    elif sys.argv[1] == '--comparar':
        if len(sys.argv) < 4:
            print("Uso: ./graficas.py --comparar <sesion_normal> <sesion_ataque>")
            sys.exit(1)
        comparar(sys.argv[2].rstrip('/'), sys.argv[3].rstrip('/'))
    else:
        graficar(sys.argv[1].rstrip('/'))
