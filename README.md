# tfg-openran-lab

Laboratorio 5G Open RAN íntegramente software, construido con contenedores
Docker. Sirve como entorno experimental para estudiar la detección de anomalías
de ciberseguridad mediante Inteligencia Artificial.

Todo el laboratorio corre en una máquina virtual, sin hardware de radio ni
espectro licenciado.

## Qué incluye

El laboratorio son 23 contenedores repartidos en cuatro bloques:

| Bloque | Software | Contenedores |
|---|---|---|
| Núcleo de red 5G | Open5GS v2.8.0 | 12 |
| Red de acceso radio | OCUDU (CU-CP, CU-UP, DU) | 3 |
| Terminal de usuario | srsUE, enlace ZMQ | 1 |
| Near-RT RIC | O-RAN SC (i-release) | 7 |

Las interfaces implementadas son las estándar: N2 y N3 entre el núcleo y la
red de acceso, F1 entre CU y DU, E1 entre los dos planos de la CU, y E2 entre
la red de acceso y el controlador inteligente.

El enlace radio se emula con ZMQ: la DU y el terminal intercambian muestras IQ
por sockets TCP en lugar de por antena. Todo lo que hay por encima funciona
igual que con radio real.

## Requisitos

- Linux con Docker y Docker Compose
- Módulo de kernel `sctp` (el script de arranque lo carga si falta)
- Unos 30 GB de disco y 8 GB de RAM

## Instalación

Clonar este repositorio y, dentro, los dos repositorios de terceros que no se
versionan aquí:

```bash
git clone https://github.com/carlosprr29/tfg-openran-lab.git
cd tfg-openran-lab
```

Los tres repositorios de terceros se clonan fijando el commit exacto con el que
se desarrolló el laboratorio. Son proyectos en desarrollo activo: sin fijar la
versión, una descarga posterior puede traer cambios de comportamiento que
rompan la configuración de este repositorio.

```bash
git clone https://gitlab.com/ocudu/ocudu.git
git -C ocudu checkout 185b2396d655380f82b856799d5f13343b5d81da

git clone https://github.com/srsran/oran-sc-ric.git
git -C oran-sc-ric checkout 621ade26251f69a4ad079ba98bb708d8e5aeeb98

git clone https://github.com/srsran/srsRAN_4G.git
git -C srsRAN_4G checkout 6bcbd9e5bf8686aa7085202cd847c5ddd64a9c16
```

| Componente | Origen | Versión |
|---|---|---|
| OCUDU | gitlab.com/ocudu/ocudu | `185b2396d6` · 1 jul 2026 |
| O-RAN SC RIC | github.com/srsran/oran-sc-ric | `621ade2625` · 25 jul 2025 |
| srsRAN_4G (srsUE) | github.com/srsran/srsRAN_4G | `6bcbd9e5bf` · 18 ene 2026 |
| Open5GS | ppa:open5gs/latest | v2.8.0 (paquete) |

Open5GS es la excepción: se instala como paquete desde su repositorio oficial,
no se compila desde fuente. El PPA sirve siempre la última versión disponible,
así que una instalación posterior puede traer una versión distinta a la v2.8.0
usada aquí. Conviene comprobarlo tras construir la imagen:

```bash
docker run --rm local/open5gs:latest open5gs-amfd -v
```

Aplicar los parches (ver más abajo qué hace cada uno):

```bash
python3 patch_dockerfile.py
python3 patch_dockerfile2.py
python3 patch-ric-compose.py
```

Construir las imágenes:

```bash
docker build -t local/open5gs:latest -f Dockerfile.open5gs .

docker build -t ocudu/gnb -f ocudu/docker/Dockerfile ocudu \
  --build-arg EXTRA_CMAKE_ARGS="-DENABLE_ZEROMQ=ON -DENABLE_EXPORT=ON" \
  --build-arg NUM_JOBS=2

docker build -t local/srsue:latest srsRAN_4G
```

La compilación de OCUDU tarda bastante: compila UHD, DPDK, ROHC y el propio
proyecto desde el código fuente.

Por último, dar de alta el suscriptor de prueba en MongoDB (los datos están en
`config/open5gs/subscriber-test.md`).

## Uso

```bash
./start-lab.sh
```

El script levanta los cuatro bloques en orden, comprueba que cada componente
esté realmente operativo antes de seguir, y verifica al final la conectividad
de extremo a extremo y el registro de los nodos E2.

Comprobaciones manuales:

```bash
# Tráfico de datos entre el terminal y el núcleo de red
docker exec -it ue-srsue ping -c 4 10.45.0.1

# Nodos E2 registrados en el controlador
docker exec ric_e2mgr curl -s http://localhost:3800/v1/nodeb/states

# Métricas en tiempo real vía xApp
cd oran-sc-ric
docker compose exec python_xapp_runner ./kpm_mon_xapp.py \
  --e2_node_id=gnbd_999_070_00019b_0 \
  --metrics=DRB.UEThpDl,DRB.UEThpUl,DRB.RlcSduDelayDl \
  --kpm_report_style=5
```

Para parar todo, el orden importa: primero el laboratorio, que libera la red
del RIC, y después el RIC.

```bash
docker compose down
cd oran-sc-ric && docker compose down
```

## Los parches

Los repositorios de OCUDU y del RIC no se versionan aquí, así que los cambios
que necesitan se reproducen con estos scripts. Cada uno comprueba si ya está
aplicado, así que se pueden ejecutar más de una vez sin problema.

**`patch_dockerfile.py`** instala `libzmq3-dev` en la etapa de compilación del
Dockerfile de OCUDU. El flag `-DENABLE_ZEROMQ=ON` no basta por sí solo: si
CMake no encuentra la librería, desactiva el soporte ZMQ sin avisar y el build
termina sin errores pero sin el driver de radio.

**`patch_dockerfile2.py`** instala `libzmq5` en la etapa de ejecución del mismo
Dockerfile. La imagen final parte de una base distinta a la de compilación y no
hereda sus paquetes, así que el binario quedaba compilado con soporte ZMQ pero
no arrancaba.

Estos dos solo hacen falta al construir la imagen. Una vez construida, sus
efectos están dentro de ella.

**`patch-ric-compose.py`** añade un healthcheck a Redis y una dependencia sobre
él en `e2mgr`, dentro del `docker-compose.yml` del RIC. Sin esto, `e2mgr`
intenta conectarse a Redis antes de que esté listo, falla y no reintenta: queda
en ejecución pero sin poder registrar los nodos E2. Este parche sí afecta a
cada arranque, porque modifica un fichero que se lee cada vez.

## Parámetros de red

| Parámetro | Valor |
|---|---|
| PLMN | MCC 999 / MNC 70 |
| TAC | 1 |
| Slice | SST 1 |
| DNN | internet |
| Direcciones de terminal | 10.45.0.0/16 |
| Red del laboratorio | 10.0.0.0/24 |
| Red del RIC | 10.0.2.0/24 |
| Red F1-U | 172.20.0.0/24 |

## Estructura

```
config/
  open5gs/     configuración de las 10 funciones de red del núcleo
  ocudu/       configuración de CU-CP, CU-UP y DU
  ue/          configuración del terminal
  ric/         notas operativas del RIC
docker-compose.yaml
Dockerfile.open5gs
start-lab.sh
patch_dockerfile.py
patch_dockerfile2.py
patch-ric-compose.py
```

## Notas

`config/ric/NOTAS-RIC.md` y `config/NOTAS-ARRANQUE.md` recogen los problemas
encontrados durante el desarrollo y cómo se resolvieron. Merece la pena leerlos
antes de tocar el orden de arranque o reiniciar componentes sueltos: varios
fallos difíciles de diagnosticar vienen de dependencias temporales entre
servicios que ninguna herramienta declara.

Sobre las imágenes que no se construyen aquí: las del RIC llevan su versión
fijada en el fichero `.env` de `oran-sc-ric`, y `mongo:7.0` y
`gradiant/open5gs-webui:2.7.5` están fijadas en el `docker-compose.yaml`. La
única que no queda atada a una versión concreta es la base `ubuntu:22.04` del
Dockerfile de Open5GS, que recibe actualizaciones dentro de la misma etiqueta.
