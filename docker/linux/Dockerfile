# Linux Docker base for the jetson-cross build. The same image works on
# x86_64 hosts (cross-compiling to aarch64) and on aarch64 hosts (building
# natively for the same arch); the offline build flow itself branches
# based on the host architecture inside the container.
#
# Most of the offline build's host prerequisites (qemu-user-static,
# binfmt-support, build-essential, the aarch64 binutils) are installed by
# the build script itself; the image only needs the bare minimum to run
# the build script and unpack BSP archives.
ARG UBUNTU_VERSION=22.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
         bash bzip2 ca-certificates cmake curl file git gnupg \
         ninja-build openssh-client pkg-config python3 rsync \
         sudo util-linux xz-utils zstd \
    && rm -rf /var/lib/apt/lists/*

# Mounting the SDK volume and apt-installing inside the container needs
# root inside the container. Build users on the host still talk to the
# container as their normal user; only the initial setup uses privileged.
COPY docker/linux/entrypoint.sh /usr/local/bin/jetson-entrypoint
RUN chmod 0755 /usr/local/bin/jetson-entrypoint

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/jetson-entrypoint"]
CMD ["bash"]