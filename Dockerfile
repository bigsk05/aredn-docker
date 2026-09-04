# AREDN supernode/tunnelserver container image
#
# Key design: the rootfs is a PRE-BUILT OpenWrt root filesystem, not source.
# This Dockerfile therefore has only ADD/ENV/ENTRYPOINT and no RUN — so cross-arch
# builds only need BuildKit to unpack the tarball, no QEMU emulation is required.
#
# ROOTFS_TAR is produced by scripts/build-rootfs-tar.sh from the official/fork
# ext4 rootfs image; it is a .tar.gz (ADD auto-extracts it).
# Supported platforms: linux/amd64 (x86_64), linux/arm64 (arm64), linux/arm/v7 (armv7l)
FROM scratch
ARG ROOTFS_TAR=rootfs-x86_64.tar.gz
ADD ${ROOTFS_TAR} /
ENV PATH=/usr/sbin:/usr/bin:/sbin:/bin
ENTRYPOINT ["/sbin/init"]