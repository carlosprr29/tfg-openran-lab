# Broker ZMQ multi-UE basado en GNU Radio, sin interfaz grafica.
#
# GNU Radio trae los bloques ZMQ que necesitamos para hablar con los
# dispositivos de radio virtual de OCUDU y srsUE. Se instala el paquete
# completo de Ubuntu por simplicidad: la imagen resultante es grande
# (~1.5 GB), pero evita compilar GNU Radio desde fuente.

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        gnuradio \
        python3 \
        python3-numpy \
        iproute2 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY broker.py /opt/broker.py
RUN chmod +x /opt/broker.py

CMD ["python3", "/opt/broker.py"]
