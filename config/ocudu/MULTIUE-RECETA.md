# Multi-UE: receta de despliegue

Procedimiento verificado para levantar el laboratorio con varios terminales
simultáneos. Probado con uno, dos y tres; los tres obtienen sesión de datos y
cursan tráfico sin pérdidas.

Para el historial del diagnóstico y los intentos fallidos, ver
`MULTIUE-HISTORIAL.md`.

---

## 1. Idea general

La DU expone un único par de puertos ZMQ, de modo que no puede atender a
varios terminales a la vez. Se interpone un **broker** que se comporta como la
DU ante los terminales y como un terminal ante la DU:

- **En bajada** recibe la señal de la DU y envía una copia idéntica a cada
  terminal, igual que una estación base emite para todos los que están en
  cobertura.
- **En subida** recibe la señal de cada terminal, las suma en una sola y la
  entrega a la DU, igual que las transmisiones se superponen en el aire.

Esa suma es lo que aporta realismo: cuando varios terminales transmiten a la
vez compiten por los recursos radio, y el planificador de la DU tiene que
repartirlos. Es la variabilidad necesaria para estudiar anomalías.

---

## 2. Requisitos previos

| Elemento | Comprobación |
|---|---|
| Imagen del broker | `docker images \| grep ue-broker` |
| Suscriptores dados de alta | Uno por terminal, con el mismo tipo de sesión |
| Configuración de los terminales | Misma frecuencia de muestreo y PRB que la celda |
| Laboratorio base operativo | `./check-lab.sh` sin fallos |

Construir la imagen del broker si no existe:

```bash
docker build -t local/ue-broker:latest broker/intento-propio/
```

### Suscriptores

Un IMSI por terminal, con las mismas claves. **Todos con el mismo tipo de
sesión**: tenerlos mezclados (unos IPv4, otros IPv4v6) no impide el registro
pero introduce diferencias de comportamiento innecesarias.

```bash
docker exec -it core-mongodb mongosh open5gs --quiet --eval '
db.subscribers.find({}, {imsi:1,"slice.session.type":1,_id:0}).forEach(printjson)
'
```

Los tres deben mostrar el mismo valor en `type`.

### Configuración de los terminales

Los tres ficheros (`config/ue/ue_zmq_lab.conf`, `ue2.conf`, `ue3.conf`) deben
coincidir en todo salvo en el IMSI, los puertos y los nombres de fichero:

| | UE1 | UE2 | UE3 |
|---|---|---|---|
| IMSI | `...001` | `...002` | `...003` |
| IP | 10.0.0.30 | 10.0.0.31 | 10.0.0.32 |
| Transmite en | 2001 | 2201 | 2301 |
| Recibe del broker en | 2100 | 2200 | 2300 |
| Frecuencia de muestreo | 23.04e6 | 23.04e6 | 23.04e6 |
| PRB | 106 | 106 | 106 |

La frecuencia de muestreo y los PRB tienen que corresponderse con la celda de
la DU: 20 MHz equivale a 23.04e6 y 106 PRB.

---

## 3. Qué cambia respecto al escenario de un terminal

**Únicamente dos direcciones.** Nada más: ni ancho de banda, ni PRACH, ni
`coreset0_index`.

En `config/ocudu/du_zmq_lab.yml`, la DU deja de recibir del terminal y pasa a
recibir del broker:

```
rx_port=tcp://10.0.0.35:2001        (antes 10.0.0.30:2001)
```

En cada fichero de terminal, deja de recibir de la DU y pasa a recibir del
broker:

```
rx_port=tcp://10.0.0.35:2100        (antes 10.0.0.24:2000)
```

Los puertos de transmisión no cambian en ningún caso.

---

## 4. Secuencia de arranque

**El orden importa y no es negociable.** El broker va siempre el último: los
terminales no pueden conectar hasta que exista el camino de bajada y subida.

```bash
cd ~/tfg-openran-lab
C="docker compose -f docker-compose.yaml -f docker-compose.multiue.yml"

# 1. Partir de limpio
docker rm -f ue-broker
$C stop ue-simulado ue2 ue3

# 2. DU recreada, esperando a que la celda quede activa
$C restart ocudu-du
sleep 70
grep -i "Cell was activated" logs/ran/du/du.log | tail -1

# 3. Todos los terminales a la vez
$C up -d ue-simulado ue2 ue3
sleep 25

# 4. El broker, el último
docker run -d --name ue-broker \
  --network tfg-openran-lab_oran_5g_net --ip 10.0.0.35 \
  -e PYTHONUNBUFFERED=1 \
  -e DU_ADDR=10.0.0.24 -e DU_TX_PORT=2000 -e DU_RX_PORT=2001 \
  -e UE_ADDRS=10.0.0.30,10.0.0.31,10.0.0.32 \
  -e UE_TX_PORTS=2001,2201,2301 \
  -e UE_RX_PORTS=2100,2200,2300 \
  -e UE_GAINS=1.0,1.0,1.0 -e SAMP_RATE=23.04e6 \
  local/ue-broker:latest

sleep 60
```

### Para menos terminales

Basta con arrancar solo los que se quieran y ajustar las tres listas del
broker. Con dos:

```bash
$C up -d ue-simulado ue2
...
  -e UE_ADDRS=10.0.0.30,10.0.0.31 \
  -e UE_TX_PORTS=2001,2201 \
  -e UE_RX_PORTS=2100,2200 \
  -e UE_GAINS=1.0,1.0 \
```

**El número de terminales arrancados y el configurado en el broker deben
coincidir.** El broker suma las subidas con un bloque que necesita datos de
todas sus entradas: si configura tres y solo hay dos, se queda esperando al
que falta y no sale nada hacia la DU.

---

## 5. Verificación

```bash
./caudal.sh
```

Debe mostrar las sesiones de los terminales y un caudal del orden de:

| Componente | Caudal en 10 s (cada sentido) |
|---|---|
| DU | ~1 GB |
| Broker | ~1 GB × (nº terminales + 1) |
| Cada terminal | ~980 MB |

El broker mueve aproximadamente la suma de todos los demás, porque recibe de
un lado y reparte al otro.

Y el plano de usuario:

```bash
for c in ue-srsue ue-srsue2 ue-srsue3; do
  echo "=== $c ==="
  docker exec $c ping -c 5 10.45.0.1 2>&1 | tail -3
done
```

---

## 6. Medidas de referencia

Obtenidas en este laboratorio, útiles para comparar:

| Escenario | Caudal DU (10 s) | Latencia media |
|---|---|---|
| Enlace directo, 1 terminal, sin broker | 1,59 GB | 46 ms |
| Con broker, 1 terminal | 0,55 GB | 112 ms |
| Con broker, 2 terminales | 1,01 GB | 56 ms |
| Con broker, 3 terminales | 1,02 GB | 61 ms |

El caso de un solo terminal con broker es el peor de los tres: el bloque que
suma las subidas está pensado para varias entradas y con una sola no fluye con
la misma soltura.

---

## 7. Cómo medir correctamente

**Localizar siempre la interfaz por su dirección IP, nunca por su nombre.**
La DU está conectada a tres redes y Docker no garantiza el orden de las
interfaces al recrear un contenedor: la red principal puede ser `eth0` en un
arranque y `eth1` en el siguiente.

Medir por nombre fue la causa de semanas de diagnósticos erróneos: se
concluyó que no circulaban muestras cuando en realidad se estaba observando la
interfaz de F1-U.

El script `caudal.sh` ya lo resuelve. A mano:

```bash
docker exec ran-du sh -c '
  IF=$(ip -o addr show | grep "10.0.0.24" | awk "{print \$2}")
  grep "$IF" /proc/net/dev | awk -v i="$IF" "{print i\" rx=\"\$2\" tx=\"\$10}"
'
```

---

## 8. Problemas habituales

**Un terminal se queda en `Attaching UE...` y no obtiene dirección.**
El emparejamiento ZMQ se ha perdido. Hay que reiniciar ambos extremos en
orden: primero la DU, esperar a que la celda quede activa, y después los
terminales. Reiniciar solo el terminal no basta.

**El terminal obtiene IP pero el ping no responde.**
La portadora de datos no llegó a crearse. Se comprueba buscando `Add DRB1` en
el registro del terminal; si solo aparece tráfico con `lcid=1`, es
señalización y no hay portadora de datos. La solución es la misma: reinicio
ordenado de DU y terminales.

**La DU cambia de configuración a mitad del arranque.**
Ocurría cuando el fichero de superposición sobreescribía el volumen de la DU.
Se eliminó esa sobreescritura: la DU usa siempre la configuración del compose
base. Comprobarlo con:

```bash
docker inspect ran-du --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}'
```

**Un contenedor huérfano ocupa una dirección.**
Si un terminal de una prueba anterior sigue vivo, el nuevo falla con
`Address already in use`. Se limpia con
`docker compose down --remove-orphans`.

---

## 9. Las direcciones de los terminales van subiendo

Cada reinicio asigna la siguiente dirección libre del rango (10.45.0.2,
luego .3, .4...). No son restos: el UPF lleva un contador que no vuelve atrás
hasta reiniciarse. No afecta al funcionamiento.
