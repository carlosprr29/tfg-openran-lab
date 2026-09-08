path = "ocudu/docker/Dockerfile"
with open(path) as f:
    content = f.read()

old = '''    /usr/local/etc/install_ocudu_dependencies.sh run && \\
    /usr/local/etc/install_rohc_dependencies.sh run && \\
    /usr/local/etc/install_docker_dependencies.sh run

# Register DPDK/UHD/ROHC library paths system-wide.'''

new = '''    /usr/local/etc/install_ocudu_dependencies.sh run && \\
    /usr/local/etc/install_rohc_dependencies.sh run && \\
    /usr/local/etc/install_docker_dependencies.sh run

# TFG lab: libzmq5 es la libreria de runtime que necesita el binario odu al
# estar compilado con soporte ZMQ (ver primer parche, ese instalaba solo
# libzmq3-dev en la etapa de build). install_dependencies.sh no la trae
# en modo "run", asi que la anadimos aparte.
RUN apt-get update && apt-get install -y --no-install-recommends libzmq5 \\
    && rm -rf /var/lib/apt/lists/*

# Register DPDK/UHD/ROHC library paths system-wide.'''

assert old in content, "No se encontro el bloque esperado - avisa antes de continuar"
content = content.replace(old, new, 1)
with open(path, "w") as f:
    f.write(content)
print("Dockerfile parcheado correctamente (libzmq5 en runtime).")
