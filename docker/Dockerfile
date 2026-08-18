FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    xorriso \
    curl \
    ca-certificates \
    gnupg \
    qemu-system-x86 \
    qemu-utils \
    openssh-client \
    python3 \
    python3-yaml \
    shellcheck \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /repo
