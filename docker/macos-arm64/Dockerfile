ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash build-essential bzip2 ca-certificates cmake curl file git gnupg \
      ninja-build openssh-client pkg-config python3 rsync util-linux xz-utils zstd \
    && rm -rf /var/lib/apt/lists/*

COPY docker/macos-arm64/entrypoint.sh /usr/local/bin/jetson-entrypoint
RUN chmod 0755 /usr/local/bin/jetson-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/jetson-entrypoint"]
CMD ["bash"]
