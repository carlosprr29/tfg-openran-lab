#!/usr/bin/env python3
"""
xApp de recoleccion de metricas E2SM-KPM a fichero CSV.

Se suscribe a las metricas que publica la DU por el interfaz E2 y escribe una
fila por terminal y por periodo de informe. El resultado es una serie temporal
regular, apta para alimentar el bloque de deteccion de anomalias.

Derivada de kpm_mon_xapp.py del repositorio oran-sc-ric, que solo imprime por
pantalla. Se mantiene aquel intacto y esta se ejecuta como xApp propia.

Formato del CSV
---------------
    timestamp,t_rel,e2_node,ue_id,<metrica_1>,<metrica_2>,...

  timestamp  hora local con milisegundos (ISO 8601)
  t_rel      segundos desde el inicio de la recoleccion
  e2_node    identificador del nodo E2 que informa
  ue_id      identificador del terminal asignado por la celda
  <metrica>  una columna por metrica solicitada

Las metricas que la DU no implementa devuelven valores constantes o vacios;
se registran igualmente para dejar constancia de su estado.

Uso
---
    ./kpm_csv_xapp.py --e2_node_id=<id> \\
        --metrics=DRB.UEThpDl,DRB.UEThpUl \\
        --kpm_report_style=5 \\
        --output=/salida/metricas.csv \\
        --duration=180
"""

import argparse
import csv
import os
import signal
import sys
import time
from datetime import datetime

from lib.xAppBase import xAppBase


class KpmCsvXapp(xAppBase):
    def __init__(self, config, http_server_port, rmr_port, output, metrics, duration):
        super(KpmCsvXapp, self).__init__(config, http_server_port, rmr_port)

        self.metricas = metrics
        self.salida = output
        self.duracion = duration
        self.t_inicio = None
        self.n_filas = 0
        self.n_indicaciones = 0

        os.makedirs(os.path.dirname(self.salida) or '.', exist_ok=True)
        self.fichero = open(self.salida, 'w', newline='', buffering=1)
        self.csv = csv.writer(self.fichero)
        self.csv.writerow(['timestamp', 't_rel', 'e2_node', 'ue_id'] + self.metricas)

        print("Escribiendo metricas en: {}".format(self.salida))
        print("Columnas: timestamp, t_rel, e2_node, ue_id, {}".format(", ".join(self.metricas)))

    # -----------------------------------------------------------------------
    def _fila(self, e2_node, ue_id, med):
        """Escribe una fila con los valores de un terminal."""
        ahora = datetime.now()
        if self.t_inicio is None:
            self.t_inicio = ahora
        t_rel = (ahora - self.t_inicio).total_seconds()

        valores = []
        for m in self.metricas:
            v = med.get(m, None)
            # Las metricas llegan como lista de muestras del periodo de
            # granularidad. Con un unico valor se simplifica a escalar; con
            # varios se promedia, descartando los ausentes.
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
            valores.append(v)

        self.csv.writerow([ahora.isoformat(timespec='milliseconds'),
                           round(t_rel, 3), e2_node, ue_id] + valores)
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

        # Estilos 1 y 2: medidas de celda o de un unico terminal
        if kpm_report_style in (1, 2):
            self._fila(e2_agent_id, ue_id if ue_id is not None else 'celda',
                       datos.get("measData", {}))
        # Estilos 3 a 5: medidas separadas por terminal
        else:
            for uid, med_ue in datos.get("ueMeasData", {}).items():
                self._fila(e2_agent_id, uid, med_ue.get("measData", {}))

        if self.n_indicaciones % 10 == 0:
            print("  {} indicaciones, {} filas escritas".format(
                self.n_indicaciones, self.n_filas))

        # Parada automatica al cumplirse la duracion solicitada
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
        periodo = 1000      # ms entre informes
        granularidad = 1000  # ms de agregacion por muestra

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
    ap = argparse.ArgumentParser(description='Recoleccion de metricas E2SM-KPM a CSV')
    ap.add_argument("--config", type=str, default='', help="Fichero de configuracion de la xApp")
    ap.add_argument("--http_server_port", type=int, default=8092)
    ap.add_argument("--rmr_port", type=int, default=4562)
    ap.add_argument("--e2_node_id", type=str, default='gnbd_999_070_00019b_0',
                    help="Identificador del nodo E2 (la DU)")
    ap.add_argument("--ran_func_id", type=int, default=2)
    ap.add_argument("--kpm_report_style", type=int, default=5,
                    help="Estilo de informe KPM (5 = varias metricas por terminal)")
    ap.add_argument("--ue_ids", type=str, default='0,1,2',
                    help="Identificadores de terminal, separados por coma")
    ap.add_argument("--metrics", type=str,
                    default='DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl',
                    help="Metricas a solicitar, separadas por coma")
    ap.add_argument("--output", type=str, default='/tmp/metricas.csv',
                    help="Fichero CSV de salida")
    ap.add_argument("--duration", type=int, default=0,
                    help="Segundos de recoleccion (0 = sin limite)")
    args = ap.parse_args()

    metricas = [m.strip() for m in args.metrics.split(",") if m.strip()]
    ue_ids = [int(x.strip()) for x in args.ue_ids.split(",") if x.strip()]

    xapp = KpmCsvXapp(args.config, args.http_server_port, args.rmr_port,
                      args.output, metricas, args.duration)
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
