#!/usr/bin/env bash
set -euo pipefail

# Build the kernel bundle on Linux-native container storage. macOS shared
# filesystems cannot safely host a fresh Linux source extraction.
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_PATH
readonly BACKEND_REQUEST="${LIBKRUNFW_BUILD_BACKEND:-auto}"
readonly BUILD_DNS="${LIBKRUNFW_BUILD_DNS:-}"
readonly IMAGE="fedora:latest"

backend=
output_dir=

fail() {
    echo "error: $*" >&2
    exit 1
}

cleanup() {
    local status=$?
    [[ -z "$output_dir" ]] || find "$output_dir" -depth -delete >/dev/null 2>&1 || :
    exit "$status"
}
trap cleanup EXIT

validate_dns_override() {
    local octet
    local -a octets

    [[ -z "$BUILD_DNS" ]] && return
    [[ "$BUILD_DNS" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "LIBKRUNFW_BUILD_DNS must be an IPv4 address (got $BUILD_DNS)"
    IFS=. read -r -a octets <<<"$BUILD_DNS"
    for octet in "${octets[@]}"; do
        ((10#$octet <= 255)) || fail "LIBKRUNFW_BUILD_DNS must be an IPv4 address (got $BUILD_DNS)"
    done
}

select_backend() {
    case "$BACKEND_REQUEST" in
        auto)
            if command -v container >/dev/null 2>&1; then
                backend=container
            elif command -v docker >/dev/null 2>&1; then
                backend=docker
            else
                fail "no supported container backend found; install Apple's container CLI or Docker"
            fi
            ;;
        container|docker) backend="$BACKEND_REQUEST" ;;
        *) fail "LIBKRUNFW_BUILD_BACKEND must be auto, container, or docker (got $BACKEND_REQUEST)" ;;
    esac

    if [[ "$backend" == container ]]; then
        command -v container >/dev/null 2>&1 || fail "Apple container CLI is unavailable; install it or select docker"
        container system status >/dev/null 2>&1 || fail "Apple container service is unavailable; run 'container system start'"
    else
        command -v docker >/dev/null 2>&1 || fail "Docker is unavailable; install Docker or select container"
        docker info >/dev/null 2>&1 || fail "Docker daemon is unavailable; start Docker Desktop"
    fi
}

create_source_archive() {
    # Keep tarball caches but never use extracted kernels or generated bundles
    # as source inputs to this native-storage build.
    tar -C "$SCRIPT_PATH" \
        --exclude=.git --exclude='./.git' \
        --exclude=kernel.c --exclude='./kernel.c' --exclude='.kernel.c.next.*' \
        --exclude='.libkrunfw-output.*' --exclude='./.libkrunfw-output.*' \
        --exclude='linux-*' --exclude='./linux-*' \
        --exclude=qboot.c --exclude=initrd.c --exclude=vmlinux \
        --exclude='*.dylib' --exclude='./*.dylib' \
        --exclude='*.so' --exclude='./*.so' \
        --exclude='*.so.*' --exclude='./*.so.*' \
        --exclude='*.dll' --exclude='./*.dll' \
        --exclude='*.exp' --exclude='./*.exp' \
        --exclude='*.lib' --exclude='./*.lib' \
        --exclude='*.obj' --exclude='./*.obj' \
        --exclude='*.pdb' --exclude='./*.pdb' \
        -cf - .
}

main() {
    local -a run_options

    validate_dns_override
    select_backend

    [[ ! -d "$SCRIPT_PATH/kernel.c" ]] || fail "cannot publish kernel.c: $SCRIPT_PATH/kernel.c is a directory"
    output_dir="$(mktemp -d "$SCRIPT_PATH/.libkrunfw-output.XXXXXX")"
    run_options=(run --rm --interactive --volume "$output_dir:/output")
    [[ -z "$BUILD_DNS" ]] || run_options+=(--dns "$BUILD_DNS")

    echo "==> libkrunfw backend: $backend"
    echo "==> Streaming filtered source snapshot to container-native /work"
    echo "==> Building kernel bundle in container-native /work"
    # shellcheck disable=SC2016 # The quoted program intentionally runs inside the container.
    create_source_archive | "$backend" "${run_options[@]}" "$IMAGE" /bin/bash -lc 'mkdir -p /work && tar -xf - -C /work && cd /work && dnf install -y "dnf-command(builddep)" python3-pyelftools curl && dnf builddep -y kernel && make -j"$(nproc)" kernel.c && cp kernel.c /output/kernel.c'

    echo "==> Publishing kernel.c result"
    [[ -f "$output_dir/kernel.c" && ! -L "$output_dir/kernel.c" && -s "$output_dir/kernel.c" ]] || fail "container did not produce a non-empty regular /work/kernel.c"
    mv -f "$output_dir/kernel.c" "$SCRIPT_PATH/kernel.c"
    echo "==> Published $SCRIPT_PATH/kernel.c"
}

main "$@"
