#!/usr/bin/env python3
"""
xApp MALICIOSA de recoleccion de metricas E2SM-KPM (escenario 05).

Es una copia de kpm_csv_xapp.py con una sola diferencia: puede falsear las
metricas antes de escribirlas. Modela una xApp de recoleccion comprometida,
que recibe del nodo E2 los valores reales pero entrega al detector valores
manipulados. En O-RAN las xApps son software de terceros, asi que una xApp
comprometida es un vector realista.

Como conoce el valor real (lo acaba de recibir) y el que decide reportar,
escribe los dos en el CSV: la columna <metrica> lleva el valor REPORTADO (lo
que veria la victima) y la columna <metrica>_real lleva la verdad. Asi la
deteccion se puede medir comparando ambas.

Envenenamiento:
  --poison_mode    none  -> no toca nada (igual que la xApp legitima)
                   scale -> multiplica por poison_factor en la ventana
  --poison_factor  factor multiplicativo. >1 fabrica una anomalia falsa sobre
                   trafico normal; <1 enmascara (tira los valores hacia abajo)
  --poison_metrics metricas a envenenar, separadas por coma (vacio = todas)
  --poison_start   inicio de la ventana de envenenamiento (s, t_rel)
  --poison_end     fin de la ventana

El resto es identico a kpm_csv_xapp.py.
"""

import argparse
import csv
import os
import signal
import sys
import time
from datetime import datetime

from lib.xAppBase import xAppBase


class KpmCsvXappMalicioso(xAppBase):
    def __init__(self, config, http_server_port, rmr_port, output, metrics, duration,
                 poison_mode, poison_factor, poison_metrics, poison_start, poison_end):
        super(KpmCsvXappMalicioso, self).__init__(config, http_server_port, rmr_port)

        self.metricas = metrics
        self.salida = output
        self.duracion = duration
        self.t_inicio = None
        self.n_filas = 0
        self.n_indicaciones = 0

        # Parametros del envenenamiento
        self.poison_mode = poison_mode
        self.poison_factor = poison_factor
        self.poison_metrics = poison_metrics if poison_metrics else list(metrics)
        self.poison_start = poison_start
        self.poison_end = poison_end

        os.makedirs(os.path.dirname(self.salida) or '.', exist_ok=True)
        self.fichero = open(self.salida, 'w', newline='', buffering=1)
        self.csv = csv.writer(self.fichero)
        # Columnas: primero las reportadas (lo que ve la victima), luego las reales
        cabecera = (['timestamp', 't_rel', 'e2_node', 'ue_id']
                    + self.metricas
                    + [m + '_real' for m in self.metricas])
        self.csv.writerow(cabecera)

        print("Escribiendo metricas en: {}".format(self.salida))
        print("Envenenamiento: modo={} factor={} metricas={} ventana=[{},{}]s".format(
            self.poison_mode, self.poison_factor, self.poison_metrics,
            self.poison_start, self.poison_end))

    # -----------------------------------------------------------------------
    def _envenenar(self, nombre, v, t_rel):
        """Devuelve el valor a reportar: el real, o el falseado si procede."""
        if self.poison_mode == 'none' or v == '':
            return v
        if not (self.poison_start <= t_rel <= self.poison_end):
            return v
        if nombre not in self.poison_metrics:
            return v
        try:
            return round(float(v) * self.poison_factor, 3)
        except (ValueError, TypeError):
            return v

    # -----------------------------------------------------------------------
    def _fila(self, e2_node, ue_id, med):
        """Escribe una fila: valores reportados (quiza falseados) y reales."""
        ahora = datetime.now()
        if self.t_inicio is None:
            self.t_inicio = ahora
        t_rel = (ahora - self.t_inicio).total_seconds()

        reales = []
        for m in self.metricas:
            v = med.get(m, None)
            if isinstance(v, list):
                utiles = [x for x in v if x is not None]
                if not utiles:
                    v = ''
                elif len(utiles) == 1:
                    v = utiles[0]
                else:
                    v = round(sum(utiles) / len(utiles), 3)
            elif v is None:
                v = ''
            reales.append(v)

        reportados = [self._envenenar(m, v, t_rel) for m, v in zip(self.metricas, reales)]

        self.csv.writerow([ahora.isoformat(timespec='milliseconds'),
                           round(t_rel, 3), e2_node, ue_id] + reportados + reales)
        self.n_filas += 1

    # -----------------------------------------------------------------------
    def callback(self, e2_agent_id, subscription_id, indication_hdr,
                 indication_msg, kpm_report_style, ue_id):
        self.n_indicaciones += 1

        try:
            self.e2sm_kpm.extract_hdr_info(indication_hdr)
            datos = self.e2sm_kpm.extract_meas_data(indication_msg)
        except Exception as e:
            print("Indicacion descartada: {}".format(e), file=sys.stderr)
            return

        if kpm_report_style in (1, 2):
            self._fila(e2_agent_id, ue_id if ue_id is not None else 'celda',
                       datos.get("measData", {}))
        else:
            for uid, med_ue in datos.get("ueMeasData", {}).items():
                self._fila(e2_agent_id, uid, med_ue.get("measData", {}))

        if self.n_indicaciones % 10 == 0:
            print("  {} indicaciones, {} filas escritas".format(
                self.n_indicaciones, self.n_filas))

        if self.duracion and self.t_inicio:
            if (datetime.now() - self.t_inicio).total_seconds() >= self.duracion:
                print("\nDuracion alcanzada ({} s)".format(self.duracion))
                self.cerrar()
                os.kill(os.getpid(), signal.SIGTERM)

    # -----------------------------------------------------------------------
    def cerrar(self):
        if not self.fichero.closed:
            self.fichero.close()
            print("\n{} filas escritas en {}".format(self.n_filas, self.salida))

    # -----------------------------------------------------------------------
    @xAppBase.start_function
    def start(self, e2_node_id, kpm_report_style, ue_ids, metric_names):
        periodo = 1000
        granularidad = 1000

        cb = lambda a, s, h, m: self.callback(a, s, h, m, kpm_report_style, None)

        if kpm_report_style == 1:
            self.e2sm_kpm.subscribe_report_service_style_1(
                e2_node_id, periodo, metric_names, granularidad, cb)
        elif kpm_report_style == 2:
            cb = lambda a, s, h, m: self.callback(a, s, h, m, kpm_report_style, ue_ids[0])
            self.e2sm_kpm.subscribe_report_service_style_2(
                e2_node_id, periodo, ue_ids[0], metric_names, granularidad, cb)
        elif kpm_report_style == 3:
            if len(metric_names) > 1:
                print("El estilo 3 admite una sola metrica; se usa {}".format(metric_names[0]))
                metric_names = [metric_names[0]]
            cond = [{'matchingCondChoice': ('testCondInfo', {
                'testType': ('ul-rSRP', 'true'),
                'testExpr': 'lessthan',
                'testValue': ('valueInt', 1000)})}]
            self.e2sm_kpm.subscribe_report_service_style_3(
                e2_node_id, periodo, cond, metric_names, granularidad, cb)
        elif kpm_report_style == 4:
            cond = [{'matchingUeCondReport': {'testCondInfo': {
                'testType': ('ul-rSRP', 'true'),
                'testExpr': 'lessthan',
                'testValue': ('valueInt', 1000)}}}]
            self.e2sm_kpm.subscribe_report_service_style_4(
                e2_node_id, periodo, cond, metric_names, granularidad, cb)
        elif kpm_report_style == 5:
            self.e2sm_kpm.subscribe_report_service_style_5(
                e2_node_id, periodo, ue_ids, metric_names, granularidad, cb)
        else:
            print("Estilo de informe no soportado: {}".format(kpm_report_style))
            sys.exit(1)

        print("Suscrito al nodo {} (estilo {}). Recogiendo metricas...".format(
            e2_node_id, kpm_report_style))


# ---------------------------------------------------------------------------
if __name__ == '__main__':
    ap = argparse.ArgumentParser(description='xApp maliciosa: recoleccion con envenenamiento de metricas')
    ap.add_argument("--config", type=str, default='')
    ap.add_argument("--http_server_port", type=int, default=8092)
    ap.add_argument("--rmr_port", type=int, default=4562)
    ap.add_argument("--e2_node_id", type=str, default='gnbd_999_070_00019b_0')
    ap.add_argument("--ran_func_id", type=int, default=2)
    ap.add_argument("--kpm_report_style", type=int, default=5)
    ap.add_argument("--ue_ids", type=str, default='0,1,2')
    ap.add_argument("--metrics", type=str,
                    default='DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl')
    ap.add_argument("--output", type=str, default='/tmp/metricas.csv')
    ap.add_argument("--duration", type=int, default=0)
    # Parametros del envenenamiento
    ap.add_argument("--poison_mode", type=str, default='none', choices=['none', 'scale'])
    ap.add_argument("--poison_factor", type=float, default=1.0)
    ap.add_argument("--poison_metrics", type=str, default='',
                    help="Metricas a envenenar, separadas por coma (vacio = todas)")
    ap.add_argument("--poison_start", type=float, default=60.0)
    ap.add_argument("--poison_end", type=float, default=120.0)
    args = ap.parse_args()

    metricas = [m.strip() for m in args.metrics.split(",") if m.strip()]
    ue_ids = [int(x.strip()) for x in args.ue_ids.split(",") if x.strip()]
    poison_metrics = [m.strip() for m in args.poison_metrics.split(",") if m.strip()]

    xapp = KpmCsvXappMalicioso(args.config, args.http_server_port, args.rmr_port,
                               args.output, metricas, args.duration,
                               args.poison_mode, args.poison_factor, poison_metrics,
                               args.poison_start, args.poison_end)
    xapp.e2sm_kpm.set_ran_func_id(args.ran_func_id)

    def parar(sig, frame):
        xapp.cerrar()
        xapp.signal_handler(sig, frame)

    signal.signal(signal.SIGQUIT, parar)
    signal.signal(signal.SIGTERM, parar)
    signal.signal(signal.SIGINT, parar)

    try:
        xapp.start(args.e2_node_id, args.kpm_report_style, ue_ids, metricas)
    finally:
        xapp.cerrar()
