path = "ocudu/docker/Dockerfile"
with open(path) as f:
    content = f.read()

old = '''    /src/docker/scripts/install_dependencies.sh build && \\
    /src/docker/scripts/install_docker_dependencies.sh build

#################################
# Stage 0b: Shared lean base     #'''

new = '''    /src/docker/scripts/install_dependencies.sh build && \\
    /src/docker/scripts/install_docker_dependencies.sh build

# TFG lab: libzmq3-dev solo esta en el modo "extra" del script, que el
# Dockerfile nunca invoca. Lo instalamos aparte para tener el driver ZMQ.
RUN apt-get update && apt-get install -y --no-install-recommends libzmq3-dev \\
    && rm -rf /var/lib/apt/lists/*

#################################
# Stage 0b: Shared lean base     #'''

assert old in content, "No se encontro el bloque esperado - el Dockerfile no coincide con lo previsto, avisa antes de continuar"
content = content.replace(old, new, 1)
with open(path, "w") as f:
    f.write(content)
print("Dockerfile parcheado correctamente.")
