# Broker multi-UE: origen, diseño y fuentes

## Por qué hace falta

La DU expone un único par de puertos ZMQ, así que no puede hablar con varios
terminales a la vez. La documentación oficial de srsRAN lo plantea así: para
conectar varios UEs a un mismo gNB con dispositivos de radio ZMQ hace falta un
intermediario que reciba la señal de bajada del gNB y envíe una copia a cada
UE conectado, y que reciba la señal de subida de cada UE, las agregue y mande
el resultado al gNB.

Ellos implementan ese intermediario con **GNU Radio Companion**, porque trae de
serie bloques compatibles con ZMQ que permiten conectarse a procesos externos
por sockets TCP.

## Advertencia del propio creador

La documentación oficial avisa expresamente de que su escenario multi-UE **no
pretende ser una solución optimizada, eficiente ni escalable**, sino un ejemplo
sencillo para demostrar cómo conectar varios UEs a un mismo gNB usando ZMQ y
srsUE, y que extender el montaje más allá de lo descrito puede no funcionar
como se espera. Para escenarios exigentes recomiendan otras soluciones, como
AmariUE.

Esto hay que tenerlo presente: el multi-UE sobre ZMQ es frágil por diseño.

## Fuentes consultadas

| Fuente | Qué se tomó de ella |
|---|---|
| srsRAN Project — tutorial "srsRAN gNB with srsUE", sección Multi-UE. https://docs.srsran.com/projects/project/en/latest/tutorials/source/srsUE/source/index.html | La función del broker, el reparto de puertos, los ajustes de PRACH, el orden de arranque y la advertencia sobre escalabilidad |
| srsRAN 4G — nota de aplicación "ZMQ Virtual Radios". https://docs.srsran.com/projects/4g/en/latest/app_notes/source/zeromq/source/index.html | Comportamiento del emparejamiento ZMQ: el UE no conecta hasta que el broker arranca, y hay que reiniciar el broker cada vez que se reinicia la red |
| OAIC — "Multiple UEs with ZMQ Example". https://openaicellular.github.io/oaic/multi_ue_example.html | Confirmación de que el patrón escala a más terminales (su ejemplo usa cinco), aunque su flujo está hecho para el eNB de 4G |
| srsRAN_4G, discusión #1203 | Caso reportado idéntico al que nos puede ocurrir: dos UEs con conexión RRC establecida pero ninguno obtiene dirección IP |

## Qué se hizo aquí y en qué se aparta del ejemplo oficial

El ejemplo oficial distribuye un fichero `.grc`, que es el formato de GNU Radio
Companion: al ejecutarlo se genera un script de Python con la interfaz gráfica
incluida. En este laboratorio **no se usa ese fichero**. En su lugar se ha
escrito directamente el script de Python (`broker.py`), por tres razones:

1. **Sin interfaz gráfica.** El laboratorio debe arrancar con un solo comando,
   sin que nadie tenga que abrir una ventana y pulsar un botón. Esto responde
   al requisito de reproducibilidad del proyecto.
2. **Número de terminales configurable.** El ejemplo oficial fija tres UEs en
   el propio flujo. Aquí el número se deriva de las variables de entorno, así
   que añadir un terminal no exige rehacer nada.
3. **Encaje con los contenedores.** El ejemplo usa `localhost` porque lo
   ejecutan todo en la misma máquina. Aquí cada componente tiene su IP en la
   red Docker.

La estructura de señal es la misma que la del flujo oficial: un grafo para la
bajada y otro para la subida, con control de atenuación independiente por
terminal. Lo que en la versión gráfica son deslizadores, aquí es la variable
`UE_GAINS`.

## Reparto de puertos

Se respeta el esquema del ejemplo oficial.

| Quién | Transmite en (bind) | Recibe de (connect) |
|---|---|---|
| DU | `10.0.0.24:2000` | `10.0.0.35:2001` (broker) |
| UE1 | `10.0.0.30:2101` | `10.0.0.35:2100` (broker) |
| UE2 | `10.0.0.31:2201` | `10.0.0.35:2200` (broker) |
| UE3 | `10.0.0.32:2301` | `10.0.0.35:2300` (broker) |

Ningún terminal habla con la DU directamente: todos pasan por el broker.

## Ancho de banda

Se bajó de 20 a 10 MHz (frecuencia de muestreo de 23.04 a 11.52), siguiendo el
ejemplo oficial, que usa ese ancho para aligerar la carga de CPU. Con tres
terminales, la DU, el broker y el RIC compartiendo una misma máquina virtual,
el procesado de señal es el mayor consumidor de recursos del laboratorio.

Implica ajustar también los terminales: 52 PRBs en lugar de 106.

## PRACH

El ejemplo oficial ajusta el canal de acceso aleatorio para que varios
terminales no colisionen al conectarse. Al consultar las opciones del binario
de OCUDU se comprobó que `total_nof_ra_preambles` ya vale 64 por defecto y que
`nof_ssb_per_ro` solo admite el valor 1; el único que carecía de valor por
defecto era `nof_cb_preambles_per_ssb`. Los tres se declaran explícitamente
para dejar constancia de la intención.

## Orden de arranque

Cambia respecto al laboratorio de un solo terminal. Según la documentación
oficial: primero el core, luego el gNB, luego todos los UEs, y **el broker el
último**. Los terminales no conectarán hasta que el broker arranque, porque los
canales de subida y bajada no están conectados directamente entre ellos.

Además, hay que **reiniciar el broker cada vez que se reinicia la red**.

## Riesgos conocidos

- **Fragilidad del montaje**, reconocida por el propio creador (ver arriba).
- **Terminales que conectan pero no obtienen IP.** Es un caso reportado en la
  comunidad. Si aparece, conviene descartar primero que los suscriptores estén
  correctamente dados de alta, que es la causa que documenta el propio
  tutorial para ese síntoma.
- **El broker es código propio**, no un fichero distribuido por el proyecto.
  Es el componente con más probabilidad de necesitar ajustes.

---

# Bitácora: intento de broker propio y cambio de enfoque

Esta sección documenta el primer intento de implementación del broker, que no
llegó a funcionar, y las razones del cambio de enfoque. Se conserva por su
valor diagnóstico: el código está en `broker/intento-propio/`.

## Qué se intentó

Escribir el broker desde cero en Python usando los bloques ZMQ de GNU Radio
(`broker.py`), ejecutado en un contenedor sin interfaz gráfica, en lugar de
emplear el fichero `.grc` que distribuye srsRAN.

El motivo era el requisito de reproducibilidad del proyecto: el fichero oficial
se abre con GNU Radio Companion y se ejecuta pulsando un botón, lo que impide
automatizar el arranque del laboratorio en un único comando.

La estructura reproducía la del flujo oficial:

- **Bajada**: una fuente conectada al puerto de transmisión de la DU, con una
  copia por terminal, cada una con su propia atenuación configurable.
- **Subida**: una fuente por terminal, todas sumadas y entregadas a la DU.

## Qué funcionó

- La imagen se construyó correctamente (GNU Radio 3.10.1.1, con los bloques
  `req_source` y `rep_sink` disponibles).
- El broker arrancó, leyó su configuración de las variables de entorno y dejó
  los cuatro puertos en escucha (2001 para la DU, y 2100/2200/2300 para los
  terminales).
- Las ocho conexiones TCP se establecieron: con la DU en ambos sentidos y con
  los tres terminales en ambos sentidos (verificado con `ss -tn`).
- Los terminales leyeron su configuración y abrieron el dispositivo ZMQ con los
  puertos y la frecuencia de muestreo correctos.

## Qué no funcionó

Las muestras no llegaban a destino. El síntoma constante en el registro de la
DU era:

```
[zmq:rx] Waiting for reading samples. Completed 0 of 11520 samples.
[zmq:tx] Waiting for data.
```

y los terminales quedaban detenidos indefinidamente en `Attaching UE...`, sin
llegar a iniciar el procedimiento de acceso aleatorio.

En una de las pruebas el contador llegó a `Completed 8191 of 11520 samples` y
se quedó ahí. Es decir, el broker **sí entregó datos**, pero no llegó a
completar un bloque. Ese dato descarta que el problema fuera de conectividad y
sitúa el fallo en el ritmo o el formato de la entrega.

## Hipótesis descartadas

Se documentan porque consumieron tiempo y para no repetirlas:

| Hipótesis | Cómo se descartó |
|---|---|
| El bloque sumador de la subida se bloqueaba esperando a los tres terminales | Con un solo terminal, sin sumador de varias entradas, el fallo persistía |
| Los roles del patrón petición-respuesta estaban invertidos | Las ocho conexiones se establecían correctamente y circulaba tráfico |
| Bloqueo total, ninguna muestra en tránsito | Los contadores de `/proc/net/dev` mostraban tráfico circulando, y la DU llegó a recibir 8191 muestras |
| Falta de memoria compartida para los búferes de GNU Radio | Asignar 2 GB con `shm_size` no eliminó el aviso ni cambió el comportamiento |

## Causa probable, no confirmada

El fallo parece estar en cómo se encadenan los bloques ZMQ de GNU Radio con la
implementación de srsRAN: la entrega se produce, pero no con el tamaño de
bloque o la cadencia que la DU espera para completar sus 11520 muestras. No se
llegó a identificar el detalle concreto.

## Decisión adoptada

Emplear el fichero de flujo que distribuye srsRAN, ejecutado con GNU Radio
Companion, en lugar del broker propio. El criterio fue que se trata de código
probado por los propios desarrolladores del sistema, frente a una
reimplementación cuyo comportamiento no se consiguió igualar.

Se acepta a cambio una pérdida de automatización: el flujo hay que lanzarlo a
mano y no puede incluirse en el script de arranque. Si más adelante se
identifica la diferencia entre ambos, la implementación automatizada podría
retomarse tomando el flujo oficial como referencia.

## Qué se conserva del intento

Todo lo demás del trabajo de multi-UE sigue siendo válido y no depende del
broker: los tres suscriptores dados de alta, las tres configuraciones de
terminal, los ajustes de la DU (10 MHz, PRACH, `coreset0_index` derivado) y los
servicios del `docker-compose.yaml`.

El código del intento se conserva en `broker/intento-propio/` y el servicio
`ue-broker` queda comentado en el `docker-compose.yaml`.

## Hallazgo colateral: coreset0_index

Durante este trabajo se detectó que el valor `coreset0_index: 12`, heredado del
archivo de referencia de 20 MHz, **no es válido con 10 MHz**. La DU abortaba
con:

```
Unable to derive a valid SSB pointA and k_SSB for CORESET#0 index=12,
SearchSpace#0 index=0 and cell bandwidth=10Mhz
```

La solución fue **no declarar el parámetro**, dejando que el software lo
derive. La ayuda del binario lo respalda: `coreset0_index` no tiene valor por
defecto y existe una opción `max_coreset0_duration` descrita como el valor a
considerar «al derivar el índice de CORESET#0». El valor válido depende del
ancho de banda, la separación entre subportadoras y la posición del bloque de
sincronización, así que fijarlo a mano obliga a recalcularlo ante cualquier
cambio.

---

# Bitácora II: el flujo oficial de GNU Radio

Tras descartar el broker propio, se probó el fichero `.grc` que distribuye
srsRAN, ejecutado con GNU Radio Companion sobre el anfitrión.

## Qué se hizo

- Se instaló GNU Radio Companion 3.10.9.2 en la máquina virtual.
- Se descargó `multi_ue_scenario.grc` de la documentación oficial.
- Se adaptaron las direcciones: las cuatro fuentes apuntan a las IP de los
  contenedores (DU `10.0.0.24:2000`, terminales `.30:2101`, `.31:2201`,
  `.32:2301`) y los cuatro sumideros escuchan en `0.0.0.0`.
- En la DU y los terminales se cambió el `rx_port` para apuntar a `10.0.0.1`,
  la puerta de enlace de la red Docker, que es el propio anfitrión.
- Se respetó el orden de arranque documentado: núcleo, gNB, todos los
  terminales y el flujo en último lugar.

## Qué reveló el flujo oficial

Al abrirlo se confirmó la estructura y apareció una diferencia respecto al
broker propio: el flujo incluye un **bloque de regulación** (`throttle`)
ajustado a `samp_rate / slow_down_ratio`, es decir, 2,88 MHz con los valores
por defecto. El broker propio no regulaba el ritmo en absoluto.

También trae atenuaciones distintas por terminal (0, 10 y 20 dB), lo que
probablemente ayuda a que no compitan en igualdad al conectarse.

## Qué se observó

Se verificó que el montaje era correcto:

- Las ocho conexiones TCP establecidas, desde el anfitrión (`10.0.0.1`) hacia
  la DU y los tres terminales.
- La DU escuchando en `10.0.0.24:2000` y cada terminal en su puerto.
- El proceso del flujo en ejecución y su panel de control abierto.
- Frecuencia de muestreo coherente en los tres sitios (11,52 MHz), ancho de
  banda de 10 MHz en la DU y 52 PRB en los terminales.

Y aun así, **el resultado fue el mismo que con el broker propio**: los
terminales se detienen en `Attaching UE...`, no se crea `tun_srsue` y los
contadores de red muestran un goteo mínimo o nulo, muy lejos del volumen que
correspondería a 11,52 millones de muestras por segundo.

Con el registro elevado a nivel `info`, los ficheros de log de los terminales
quedaron **vacíos**: la capa física no llega siquiera a iniciar su procesado.

## El único indicio de funcionamiento parcial

En una de las pruebas, con los tres terminales arrancados, el registro de uno
de ellos contenía:

```
[RRC-NR] [W] Could not finish setup request. Deallocating dedicatedInfoNAS PDU
```

Es señalización RRC real. Significa que en ese intento el terminal sí encontró
la celda, completó el acceso aleatorio y estableció la conexión de control,
quedándose atascado en la fase final del establecimiento. No fue reproducible.

## Casos equivalentes en la comunidad

La búsqueda confirmó que el problema está ampliamente reportado y no resuelto:

| Referencia | Qué reporta |
|---|---|
| srsRAN_Project, discusión #499 | El escenario multi-UE del tutorial funciona de forma nativa pero falla al llevarlo a docker compose. La respuesta del equipo fue que no proporcionan fichero de compose y que parecía un problema de GNU Radio al abrir el socket |
| srsRAN_Project, incidencia #1467 | gNB y srsUE en contenedores: la conexión TCP funciona y hay tráfico en los puertos ZMQ, pero el terminal nunca sincroniza, nunca aparece «Found SSB» y `tun_srsue` no se crea |
| srsRAN_Project, discusión #40 | Varios usuarios: con el broker de GNU Radio solo un terminal obtiene dirección IP; el otro se queda en RRC Connected. Otro usuario probó un broker propio con sockets dealer y pub/sub y nunca consiguió estabilidad: al añadir el segundo terminal, el primero se rompía |
| srsRAN_Project, incidencia #327 | No consigue conectar más de un terminal por ZMQ |
| Proyecto comnetsemu-srsran | Documenta la causa de fondo: el enlace ZMQ está implementado como una pareja petición-respuesta simple y solo admite una conexión. Las alternativas son un broker, la opción no documentada `tx_type=pub,rx_type=sub`, o reescribir la implementación ZMQ, lo que según ellos probablemente nunca se hará |

La recomendación de los propios desarrolladores para escenarios multi-UE es
emplear el simulador de Amarisoft, que simula todos los terminales con una
única capa física y no necesita broker. Es software comercial.

## Vía descartada: publicación-suscripción

Se comprobó si OCUDU soporta la opción no documentada `tx_type` / `rx_type`
que sí existe en srsRAN_4G:

```bash
grep -rni "tx_type\|rx_type\|ZMQ_PUB\|ZMQ_SUB" ocudu/lib/ | grep -i zmq
```

El resultado fue vacío: **OCUDU no la implementa**. Como ambos extremos deben
emplear el mismo patrón, la vía queda descartada.

## Conclusión provisional

La configuración del laboratorio es correcta y está verificada. El fallo no
procede de un error de configuración propio, sino de una limitación conocida
del enlace ZMQ de srsRAN cuando se interpone un broker, agravada en nuestro
caso por ejecutar los componentes en contenedores separados en lugar de como
procesos de una misma máquina, que es el escenario para el que está pensado y
probado el tutorial oficial.

---

# Bitácora III: terminales en el anfitrión y causa raíz

## Hipótesis de partida

Tras fallar el flujo oficial con los terminales en contenedores, se planteó
que la diferencia con el tutorial de srsRAN (que ejecuta todo como procesos de
una misma máquina) pudiera ser la causa. Se sacaron los terminales de sus
contenedores para reproducir el escenario oficial lo más fielmente posible.

## Qué se hizo

- **Compilación nativa de srsUE.** El binario extraído de la imagen no
  funcionaba en la máquina virtual: dependía de versiones de librerías propias
  de Ubuntu 22.04 (`libboost_program_options 1.74`, `libmbedcrypto.so.7`)
  ausentes en Ubuntu 24.04. Se compiló srsUE desde el código fuente en
  `srsRAN_4G/build-host`, verificando que CMake detectara ZeroMQ.
- **Configuraciones nativas** en `config/ue-host/`: direcciones ZMQ en
  `127.0.0.1`, como el tutorial, y un espacio de nombres de red por terminal
  (`netns = ue1`, `ue2`, `ue3`) para aislar la interfaz de datos.
- **Flujo de GNU Radio** con las fuentes de los terminales en `127.0.0.1` y la
  fuente de la DU en `10.0.0.24:2000`, que permanece en su contenedor.

## Qué se observó

Los tres terminales arrancaron correctamente y, por primera vez, el registro a
nivel `info` mostró la actividad de la capa física:

```
Cell search: Setting SSB configuration srate=11.52 MHz; c-freq=1842.500 MHz;
             ss-freq=1842.050 MHz; scs=15kHz; pattern=A; duplex=fdd;
Cell Search: Running Cell search state
Proc "Cell Selection" - Completed with failure.
```

Los parámetros de búsqueda son correctos y coinciden con la celda de la DU. El
terminal busca, pero **no encuentra ninguna señal**.

Esto explica también el mensaje `Could not finish setup request` observado en
la Bitácora II: no se trataba de un fallo de señalización avanzada, sino de la
consecuencia de no completar la selección de celda.

## Causa raíz

El registro de la DU mostraba de forma constante:

```
[zmq:tx] Waiting for request.
[zmq:rx] Waiting for reading samples. Completed 0 of 11520 samples.
```

y su contador de transmisión permanecía inmóvil. **La DU tiene muestras listas
pero nadie se las pide**, a pesar de existir la conexión TCP con el flujo.

Se produce así un bloqueo circular: la DU no emite bajada porque no recibe
peticiones; el flujo no reparte nada porque no recibe de la DU; los terminales
no sincronizan porque no hay bajada; y al no sincronizar no transmiten subida.

## Prueba de aislamiento

Para confirmar el punto de fallo se ejecutó un programa mínimo de GNU Radio
que únicamente pide muestras a la DU y las descarta (`zeromq.req_source` hacia
`10.0.0.24:2000` conectado a un sumidero nulo), sin terminales ni reparto.

El script se ejecutó tres veces sin errores. Los contadores de transmisión de
la DU durante la prueba fueron:

| Prueba | Inicio | Tras 12 s | Diferencia |
|---|---|---|---|
| 1 | 7 330 B | 7 330 B | 0 B |
| 2 | 14 976 B | 15 082 B | 106 B |

A 11,52 millones de muestras por segundo y 8 bytes por muestra compleja, una
DU que emitiera bajada generaría del orden de decenas de megabytes por segundo.
Los 106 bytes observados corresponden a tráfico de control (previsiblemente los
latidos SCTP de la interfaz F1 con la CU-CP, que comparte interfaz de red), no
a muestras. El incremento de unos 7,6 KB entre ambas pruebas se atribuye a las
propias conexiones del script al establecerse y emitir sus peticiones.

**Se confirma que GNU Radio envía peticiones a la DU y que esta no responde
con muestras.**

## Conclusión

El fallo no depende de:

- el broker utilizado (propio o el flujo oficial: ambos usan GNU Radio);
- el número de terminales (uno o tres);
- la ubicación de los terminales (contenedor o anfitrión).

Depende de **la interacción entre los bloques ZMQ de GNU Radio y la
implementación ZMQ de OCUDU**. La prueba por contraste es concluyente: cuando
la DU y srsUE se conectan directamente, sin intermediario, el enlace funciona
correctamente. La implementación ZMQ de OCUDU funciona; lo que falla es su
diálogo con GNU Radio.

La hipótesis más plausible es que OCUDU, al evolucionar desde srsRAN Project,
haya modificado algún aspecto de su implementación ZMQ incompatible con lo que
esperan los bloques de GNU Radio, para los que se escribió el tutorial.

## Vía pendiente

Escribir un intermediario que no use GNU Radio, sino la librería ZMQ
directamente, imitando el diálogo que srsUE mantiene con la DU (que está
comprobado que funciona). Al ser un programa sencillo, permitiría devolver el
intermediario y los terminales a contenedores, restaurando la arquitectura
original del laboratorio.

## Estado en que queda el laboratorio

Las pruebas de esta fase han dejado el laboratorio base en un estado no
funcional para el escenario de un terminal:

- La DU tiene su `rx_port` apuntando al anfitrión (`10.0.0.1:2001`).
- El ancho de banda es de 10 MHz, incompatible con la configuración original
  del terminal (20 MHz, 106 PRB).
- Los scripts `start-lab.sh` y `check-lab.sh` hacen referencia a servicios que
  ya no existen (`ue-simulado`, `ue-srsue`).
- En el anfitrión quedan creados los espacios de nombres `ue1`, `ue2` y `ue3`.

Se propone restaurar el escenario estable de un terminal a partir de la
etiqueta `v3-arranque-fiable` y mantener el multi-UE como modo experimental
separado.
