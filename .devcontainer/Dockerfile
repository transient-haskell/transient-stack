# [Choice] Ubuntu version: jammy, focal, bionic
ARG VARIANT="focal"
FROM buildpack-deps:${VARIANT}-curl

LABEL dev.containers.features="common"

# Actualizar sistema y dependencias necesarias
RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get -y install --no-install-recommends \
        build-essential \
        curl \
        libffi-dev libgmp-dev libncurses-dev pkg-config \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Instalar GHCup y Haskell Language Server (HLS)
RUN curl --proto '=https' --tlsv1.2 -sSf https://get-ghcup.haskell.org | sh -s -- --yes \
    && . "/root/.ghcup/env" \
    && ghcup install hls -y 
#    && ghcup upgrade

# Configurar PATH de GHCup para Haskell
ENV PATH="/root/.ghcup/bin:${PATH}"

