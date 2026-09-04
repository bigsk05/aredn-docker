# AREDN supernode/tunnelserver container image
#
# Key design: the rootfs is a PRE-BUILT OpenWrt root filesystem, not source.
# This Dockerfile therefore has only ADD/ENV/ENTRYPOINT and no RUN — so cross-arch
# builds only need BuildKit to unpack the tarball, no QEMU emulation is required.
#
# ROOTFS_TAR is produced by scripts/build-rootfs-tar.sh from the official/fork
# ext4 rootfs image; it is a .tar.gz (ADD auto-extracts it).
# Supported platforms: linux/amd64 (x86_64), linux/arm64 (arm64), linux/arm/v7 (armv7l)
#
# The tarball is a build artifact: it is gitignored and also excluded from the
# docker context by .dockerignore (rootfs-*.tar.gz), so the default below can
# never exist inside a build context. A bare `docker build .` therefore fails
# loudly at ADD rather than silently baking a stale or wrong-arch rootfs — the
# builder must pass its own tarball. CI passes ROOTFS_TAR=out/<arch>.tar.gz
# (build.yml); build locally the same way:
#   ./scripts/build-rootfs-tar.sh <rootfs .img.gz URL> out/x86_64.tar.gz
#   docker build --build-arg ROOTFS_TAR=out/x86_64.tar.gz .
FROM scratch
ARG ROOTFS_TAR=rootfs-x86_64.tar.gz
ADD ${ROOTFS_TAR} /

# Bake the babel hook into the firmware's own extension file so a supernode
# deploy is a single compose file with NO host-side file. The rootfs already
# ships /etc/aredn_include/babel-user.conf as an empty (comment-only) include
# that babeld_wrapper officially appends; adding `skip-kernel-setup true` here
# makes babeld skip writing /proc/sys for wg interfaces created at runtime
# (the container's /proc/sys is read-only). Identical content for all three
# architectures; mount your own babel-user.conf over it to add per-line options.
COPY compose/babel-user.conf /etc/aredn_include/babel-user.conf

ENV PATH=/usr/sbin:/usr/bin:/sbin:/bin
ENTRYPOINT ["/sbin/init"]