# Multi-UE: historial del diagnóstico

Registro de cómo se llegó a la configuración que funciona. Se conserva por su
valor metodológico: la mayor parte del tiempo invertido no se fue en construir
el broker, sino en diagnosticar mal.

Para el procedimiento operativo, ver `MULTIUE-RECETA.md`.

---

## Resumen

| Fase | Qué se probó | Resultado |
|---|---|---|
| 1 | Broker propio en Python con GNU Radio | Aparentemente sin tráfico |
| 2 | Flujo oficial de srsRAN con interfaz gráfica | Igual |
| 3 | Terminales como procesos nativos del anfitrión | Igual |
| 4 | Reguladores de ritmo, siguiendo el modelo de EdgeRIC | Igual |
| 5 | Vuelta al estado estable y **un solo cambio** | **Funciona** |

---

## Las tres causas reales

Ninguna era el broker.

### 1. Se medía la interfaz equivocada

La DU está conectada a tres redes: la principal (10.0.0.24), la de F1-U
(172.20.0.3) y la del RIC (10.0.2.31). **Docker no garantiza el orden de las
interfaces al recrear un contenedor**: la red principal podía ser `eth0` en un
arranque y `eth1` en el siguiente.

Durante semanas se midió `eth0` dando por hecho que era la radio, cuando en
varios arranques correspondía a F1-U. De ahí conclusiones como «la DU
transmite 0 bytes» o «378 bytes en 10 segundos», que llevaron a descartar
hipótesis correctas.

Cuando se midió por dirección IP en lugar de por nombre, apareció el dato real:
**159 MB/s en cada sentido** en el enlace directo.

### 2. El fichero de superposición recreaba la DU

`docker-compose.multiue.yml` sobreescribía el volumen de configuración de la
DU. Al levantar los terminales con él, la DU se recreaba con otra
configuración, y al levantar el terminal base con el compose sin superposición,
se recreaba otra vez con la original. La DU cambiaba de configuración a mitad
del arranque, dos veces seguidas.

Se eliminó la sobreescritura: la DU usa siempre la configuración del compose
base.

### 3. Se cambiaban varias cosas a la vez

Siguiendo el ejemplo oficial de srsRAN para multi-UE se modificaron de golpe:
el ancho de banda (20 → 10 MHz), la frecuencia de muestreo, el número de PRB,
los parámetros de PRACH, el `coreset0_index` y las direcciones ZMQ. Cuando
dejó de funcionar, era imposible saber cuál de los seis cambios lo había roto.

En la fase 5 se volvió al último estado bueno y se cambió **una sola cosa**:
las dos direcciones de recepción. Funcionó a la primera.

---

## Hallazgos colaterales

Problemas reales encontrados y resueltos por el camino.

**`coreset0_index` con 10 MHz.** El valor 12, heredado del archivo de
referencia de 20 MHz, no es válido con 10 MHz y la DU aborta con `Unable to
derive a valid SSB pointA and k_SSB`. La solución es no declarar el parámetro:
el software lo deriva del ancho de banda. En la configuración final, al volver
a 20 MHz, el valor 12 es válido y se mantiene.

**Reinicio de un solo extremo del enlace ZMQ.** Si se reinicia la DU sin
reiniciar los terminales (o al revés), el emparejamiento no se rehace y ambos
quedan esperándose. Y no solo afecta a la sincronización: también impide que
se cree la portadora de datos, de modo que el terminal puede obtener dirección
IP y aun así no cursar tráfico.

**Ficheros con mayúscula inicial.** Al guardar `Ue1.conf` en lugar de
`ue1.conf`, Docker no encontraba el fichero y creaba un directorio vacío con
ese nombre, montándolo sobre la configuración del terminal. srsUE arrancaba
con valores por defecto, sin radio ZMQ.

**Contenedores huérfanos.** Terminales de pruebas anteriores que seguían vivos
ocupando direcciones IP, impidiendo arrancar los nuevos.

**Red del RIC creada a mano.** Para poder arrancar la CU-CP y la DU sin el RIC
se creó su red con `docker network create`. Después, el compose del RIC no
levantaba bien al encontrarse una red que él no había creado.

---

## Conclusiones de método

**Un cambio cada vez.** Es la lección principal. Todas las fases fallidas
tienen en común haber modificado varias cosas simultáneamente.

**Verificar el instrumento de medida antes que la hipótesis.** Se construyeron
y descartaron al menos cinco hipótesis sobre la causa del fallo basándose en
mediciones que resultaron no corresponder a la interfaz correcta.

**Una prueba de aislamiento mal planteada puede ser peor que ninguna.** Se
concluyó que GNU Radio no podía dialogar con OCUDU a partir de una prueba que
conectaba solo el lado de bajada. Como el enlace de radio es un bucle, la DU
no transmite si no recibe, de modo que la prueba no podía dar otro resultado.
Esa conclusión errónea cerró durante un tiempo la vía que acabó funcionando.

**Las fuentes externas ayudaron, pero no por lo que se esperaba.** La búsqueda
en foros y repositorios aportó precedentes valiosos (EdgeRIC y OAIC ejecutan
multi-UE sobre ZMQ con 2, 4 y 5 terminales) y una advertencia del mantenedor
de srsRAN sobre que este escenario excede el diseño de ZMQ. Esa advertencia es
cierta como aviso de fragilidad, pero no implica imposibilidad: pesó
demasiado en la decisión de abandonar, que se propuso dos veces y en ambas
resultó prematura.

---

## Referencias consultadas

| Fuente | Aportación |
|---|---|
| srsRAN Project, tutorial srsUE, sección Multi-UE | Reparto de puertos, orden de arranque, ajustes de PRACH y flujo de GNU Radio de referencia |
| srsRAN Project, discusión #1015 | El mantenedor señala que ZMQ está pensado para una pareja celda-terminal y que el escenario multi-UE excede ese diseño |
| srsRAN Project, discusión #499 | Caso equivalente al nuestro: el tutorial funciona de forma nativa pero falla al llevarlo a Docker Compose |
| srsRAN Project, incidencia #1467 | gNB y srsUE en contenedores: tráfico en los puertos ZMQ pero el terminal nunca sincroniza |
| srsRAN Project, discusión #40 | Varios usuarios con el broker oficial: solo un terminal obtiene dirección IP |
| EdgeRIC (`ushasigh/srsran-edgeric-5g`) | Broker multi-UE sin interfaz gráfica, con un regulador de ritmo por salida. Demuestra que el escenario es viable |
| OAIC, ejemplo multi-UE | Escenario con cinco terminales; parámetros adicionales `id=` y `fail_on_disconnect` |
| comnetsemu-srsran | Explica que el enlace ZMQ es una pareja petición-respuesta simple y las alternativas posibles |

---

## Lo que no se llegó a probar

- **Modo publicación-suscripción** (`tx_type=pub, rx_type=sub`): existe en
  srsRAN_4G pero **OCUDU no lo implementa**, comprobado en su código fuente.
  Como ambos extremos deben usar el mismo patrón, la vía está descartada.
- **Más de tres terminales.** La literatura sugiere que a partir de cuatro o
  cinco la latencia se degrada apreciablemente.
- **Atenuación por terminal.** El broker admite el parámetro `UE_GAINS`, que
  permite degradar la señal de un terminal concreto. No se ha ensayado, pero
  es la vía natural para inducir degradación controlada en los experimentos de
  detección de anomalías.
