#!/usr/bin/env python3
"""
Broker ZMQ multi-UE para el laboratorio.

La DU tiene un solo par de puertos ZMQ, asi que no puede hablar con varios
terminales a la vez. Este broker se interpone entre ambos:

  BAJADA (DL):  DU --> broker --> copia a cada UE
  SUBIDA  (UL): cada UE --> broker --> suma --> DU

Ademas aplica una atenuacion configurable por terminal (path loss), lo que
permite degradar la senal de un UE concreto para experimentos.

Basado en el esquema del broker oficial de srsRAN, reescrito en Python sin
interfaz grafica para poder ejecutarlo en un contenedor.

Configuracion por variables de entorno:
  DU_ADDR        IP de la DU                      (por defecto 10.0.0.24)
  DU_TX_PORT     puerto donde la DU transmite     (2000)
  DU_RX_PORT     puerto donde el broker escucha   (2001)
  UE_ADDRS       IPs de los UEs, separadas por coma
  UE_TX_PORTS    puertos donde transmite cada UE, separados por coma
  UE_RX_PORTS    puertos donde el broker sirve a cada UE
  UE_GAINS       ganancia por UE (1.0 = sin atenuacion), separadas por coma
"""

import os
import sys
import signal
from gnuradio import gr, blocks, zeromq


def lista(nombre, por_defecto, conv=str):
    valor = os.environ.get(nombre, por_defecto)
    return [conv(x.strip()) for x in valor.split(",") if x.strip()]


class BrokerMultiUE(gr.top_block):
    def __init__(self):
        gr.top_block.__init__(self, "Broker multi-UE")

        du_addr = os.environ.get("DU_ADDR", "10.0.0.24")
        du_tx = os.environ.get("DU_TX_PORT", "2000")
        du_rx = os.environ.get("DU_RX_PORT", "2001")

        ue_addrs = lista("UE_ADDRS", "10.0.0.30,10.0.0.31,10.0.0.32")
        ue_tx = lista("UE_TX_PORTS", "2101,2201,2301")
        ue_rx = lista("UE_RX_PORTS", "2100,2200,2300")
        ue_gains = lista("UE_GAINS", ",".join(["1.0"] * len(ue_addrs)), float)

        n = len(ue_addrs)
        if not (len(ue_tx) == len(ue_rx) == len(ue_gains) == n):
            print("ERROR: UE_ADDRS, UE_TX_PORTS, UE_RX_PORTS y UE_GAINS "
                  "deben tener el mismo numero de elementos", file=sys.stderr)
            sys.exit(1)

        print(f"Broker multi-UE: {n} terminales")
        print(f"  DU:  recibe DL de tcp://{du_addr}:{du_tx}")
        print(f"       sirve  UL en tcp://0.0.0.0:{du_rx}")
        for i in range(n):
            print(f"  UE{i+1}: recibe UL de tcp://{ue_addrs[i]}:{ue_tx[i]}")
            print(f"        sirve  DL en tcp://0.0.0.0:{ue_rx[i]}  "
                  f"(ganancia {ue_gains[i]})")

        tam = gr.sizeof_gr_complex

        # --- BAJADA: una fuente desde la DU, una copia por terminal ---
        dl_origen = zeromq.req_source(tam, 1, f"tcp://{du_addr}:{du_tx}", 100, False, -1)

        self.dl_gan = []
        for i in range(n):
            gan = blocks.multiply_const_cc(ue_gains[i])
            destino = zeromq.rep_sink(tam, 1, f"tcp://0.0.0.0:{ue_rx[i]}", 100, False, -1)
            self.connect(dl_origen, gan, destino)
            self.dl_gan.append(gan)

        # --- SUBIDA: una fuente por terminal, sumadas hacia la DU ---
        sumador = blocks.add_vcc(1)
        ul_destino = zeromq.rep_sink(tam, 1, f"tcp://0.0.0.0:{du_rx}", 100, False, -1)

        self.ul_gan = []
        for i in range(n):
            origen = zeromq.req_source(tam, 1, f"tcp://{ue_addrs[i]}:{ue_tx[i]}", 100, False, -1)
            gan = blocks.multiply_const_cc(ue_gains[i])
            self.connect(origen, gan, (sumador, i))
            self.ul_gan.append(gan)

        self.connect(sumador, ul_destino)


def main():
    tb = BrokerMultiUE()

    def parar(sig, frame):
        print("\nDeteniendo el broker...")
        tb.stop()
        tb.wait()
        sys.exit(0)

    signal.signal(signal.SIGINT, parar)
    signal.signal(signal.SIGTERM, parar)

    print("Broker en marcha. Los terminales ya pueden conectarse.")
    tb.start()
    tb.wait()


if __name__ == "__main__":
    main()
