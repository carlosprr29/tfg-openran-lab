#!/usr/bin/env python3
"""
Broker ZMQ multi-UE para el laboratorio.

La DU tiene un solo par de puertos ZMQ, asi que no puede hablar con varios
terminales a la vez. Este broker se interpone entre ambos:

  BAJADA (DL):  DU --> broker --> copia a cada UE
  SUBIDA  (UL): cada UE --> broker --> suma --> DU

REGULACION DEL RITMO (importante)
---------------------------------
Cada salida lleva un bloque throttle a la frecuencia de muestreo. Sin el,
GNU Radio empuja las muestras tan rapido como puede y en los trozos que
decida su planificador, y la DU recibe bloques incompletos: en nuestras
pruebas aparecia "Completed 3840 of 11520 samples" o "8192 of 11520",
nunca el bloque entero, y el terminal no llegaba a sincronizar.

Esta estructura (un throttle por sumidero) se tomo de top_block_2ue_no_gui.py
del proyecto EdgeRIC (github.com/ushasigh/srsran-edgeric-5g), que ejecuta
2 y 4 terminales por ZMQ en un entorno de investigacion. El flujo oficial de
srsRAN usa un unico throttle antes del reparto; EdgeRIC pone uno en cada
rama, que es lo que se replica aqui.

ATAQUE DE JAMMING EN LA BAJADA (escenario 04)
---------------------------------------------
En cada rama de bajada, despues de la ganancia del terminal, se suma ruido
gaussiano complejo antes del throttle. Es el equivalente a un jammer que sube
el suelo de ruido del canal: la SINR en el receptor del terminal baja y
empiezan los fallos de decodificacion.

El nivel de ruido se controla en caliente, sin reiniciar el broker, leyendo un
fichero (JAM_CTRL, por defecto /tmp/jam_nivel) en un hilo aparte. Un 0 deja el
laboratorio exactamente como sin ataque (la fuente de ruido a amplitud 0 emite
ceros). El ataque.sh del escenario escribe el nivel en la fase de ataque y
vuelve a poner 0 al terminar.

Como el ruido se suma DESPUES de la ganancia, el terminal mas atenuado recibe
el mismo ruido sobre una senal mas debil: es el primero en degradarse, igual
que un jammer real muerde antes al terminal con menos margen.

Configuracion por variables de entorno:
  DU_ADDR        IP de la DU                      (10.0.0.24)
  DU_TX_PORT     puerto donde la DU transmite     (2000)
  DU_RX_PORT     puerto donde el broker escucha   (2001)
  UE_ADDRS       IPs de los UEs, separadas por coma
  UE_TX_PORTS    puertos donde transmite cada UE
  UE_RX_PORTS    puertos donde el broker sirve a cada UE
  UE_GAINS       ganancia por UE (1.0 = sin atenuacion)
  SAMP_RATE      frecuencia de muestreo en Hz     (11.52e6)
  SLOW_DOWN      factor de ralentizacion          (1 = tiempo real)
  JAM_CTRL       fichero con el nivel de ruido    (/tmp/jam_nivel)
  JAM_SEED       semilla base del ruido           (0)
"""

import os
import sys
import time
import signal
import threading
from gnuradio import gr, blocks, zeromq, analog


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

        samp_rate = float(os.environ.get("SAMP_RATE", "11.52e6"))
        slow_down = float(os.environ.get("SLOW_DOWN", "1"))
        ritmo = samp_rate / slow_down

        jam_seed = int(os.environ.get("JAM_SEED", "0"))

        n = len(ue_addrs)
        if not (len(ue_tx) == len(ue_rx) == len(ue_gains) == n):
            print("ERROR: UE_ADDRS, UE_TX_PORTS, UE_RX_PORTS y UE_GAINS "
                  "deben tener el mismo numero de elementos", file=sys.stderr)
            sys.exit(1)

        print(f"Broker multi-UE: {n} terminal(es)")
        print(f"  Frecuencia de muestreo: {samp_rate/1e6:.2f} MHz")
        print(f"  Ralentizacion: x{slow_down}  ->  ritmo {ritmo/1e6:.2f} MHz")
        print(f"  DU:  recibe DL de tcp://{du_addr}:{du_tx}")
        print(f"       sirve  UL en tcp://*:{du_rx}")
        for i in range(n):
            print(f"  UE{i+1}: recibe UL de tcp://{ue_addrs[i]}:{ue_tx[i]}")
            print(f"        sirve  DL en tcp://*:{ue_rx[i]}  "
                  f"(ganancia {ue_gains[i]})")
        print(f"  Jamming DL: ruido controlado por fichero, amplitud inicial 0")

        tam = gr.sizeof_gr_complex

        # --- BAJADA: una fuente desde la DU, una copia por terminal ---
        # Cada rama lleva su propio throttle, como en el broker de EdgeRIC.
        # Entre la ganancia y el throttle se suma ruido gaussiano (jammer).
        dl_origen = zeromq.req_source(tam, 1, f"tcp://{du_addr}:{du_tx}", 100, False, -1)

        self.dl_gan = []
        self.dl_thr = []
        self.jam_fuentes = []   # fuentes de ruido, una por rama de bajada
        for i in range(n):
            gan = blocks.multiply_const_cc(ue_gains[i])
            mezcla = blocks.add_vcc(1)
            ruido = analog.noise_source_c(analog.GR_GAUSSIAN, 0.0, jam_seed + i)
            thr = blocks.throttle(tam, ritmo, True)
            destino = zeromq.rep_sink(tam, 1, f"tcp://*:{ue_rx[i]}", 100, False, -1)
            self.connect(dl_origen, gan, (mezcla, 0))
            self.connect(ruido, (mezcla, 1))
            self.connect(mezcla, thr, destino)
            self.dl_gan.append(gan)
            self.dl_thr.append(thr)
            self.jam_fuentes.append(ruido)

        # --- SUBIDA: una fuente por terminal, sumadas hacia la DU ---
        # Sin cambios: por ahora el ataque solo toca la bajada.
        sumador = blocks.add_vcc(1)
        ul_thr = blocks.throttle(tam, ritmo, True)
        ul_destino = zeromq.rep_sink(tam, 1, f"tcp://*:{du_rx}", 100, False, -1)

        self.ul_gan = []
        for i in range(n):
            origen = zeromq.req_source(tam, 1, f"tcp://{ue_addrs[i]}:{ue_tx[i]}", 100, False, -1)
            gan = blocks.multiply_const_cc(ue_gains[i])
            self.connect(origen, gan, (sumador, i))
            self.ul_gan.append(gan)

        self.connect(sumador, ul_thr, ul_destino)
        self.ul_thr = ul_thr


def vigilar_jam(fuentes, ctrl_path, intervalo=0.2):
    """Lee el nivel de ruido del fichero de control y lo aplica en caliente.

    Un valor ausente, ilegible o no numerico se trata como 0 (sin ataque).
    Solo actua cuando el nivel cambia, para no tocar los bloques en cada vuelta.
    """
    ultimo = None
    while True:
        try:
            with open(ctrl_path) as f:
                amp = float(f.read().strip())
        except (FileNotFoundError, ValueError, OSError):
            amp = 0.0
        if amp != ultimo:
            for s in fuentes:
                s.set_amplitude(amp)
            print(f"[jam] nivel de ruido en la bajada -> {amp}", flush=True)
            ultimo = amp
        time.sleep(intervalo)


def main():
    tb = BrokerMultiUE()
    ctrl = os.environ.get("JAM_CTRL", "/tmp/jam_nivel")

    hilo = threading.Thread(target=vigilar_jam,
                            args=(tb.jam_fuentes, ctrl), daemon=True)
    hilo.start()

    def parar(sig, frame):
        print("\nDeteniendo el broker...")
        tb.stop()
        tb.wait()
        sys.exit(0)

    signal.signal(signal.SIGINT, parar)
    signal.signal(signal.SIGTERM, parar)

    print(f"Broker en marcha. Control de jamming en {ctrl}. "
          "Los terminales ya pueden conectarse.")
    tb.start()
    tb.wait()


if __name__ == "__main__":
    main()
