#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly ROOT
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/libkrunfw-helper-test.XXXXXX")"
readonly TEMP_ROOT
trap 'find "$TEMP_ROOT" -depth -delete 2>/dev/null || :' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "missing $2"; }
assert_not_contains() { ! grep -F -- "$2" "$1" >/dev/null || fail "unexpected $2"; }
assert_count() {
    local expected="$1" pattern="$2" file="$3" actual
    actual="$(grep -Fc -- "$pattern" "$file" || :)"
    [[ "$actual" == "$expected" ]] || fail "expected $expected occurrences of $pattern in $file, found $actual"
}
assert_no_staging() {
    ! find "$FIXTURE/space source" -maxdepth 1 -name '.libkrunfw-output.*' -print -quit | grep -q . || fail 'output staging was not cleaned'
}

make_adapter() {
    local adapter="$1"
    cat >"$FIXTURE/bin/$adapter" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "$(basename "$0")" >>"$FAKE_LOG"
printf ' <%s>' "$@" >>"$FAKE_LOG"
printf '\n' >>"$FAKE_LOG"
command="$1"
case "$(basename "$0")/$command" in
    container/system)
        [[ "$2" == status && "${FAKE_FAIL:-}" != status ]] || exit 21
        ;;
    docker/info)
        [[ "${FAKE_FAIL:-}" != info ]] || exit 22
        ;;
    container/run|docker/run)
        [[ "${FAKE_FAIL:-}" != run-early ]] || exit 23
        shift
        interactive=false
        remove_when_finished=false
        volumes=()
        while [[ "$1" == --* ]]; do
            case "$1" in
                --rm) remove_when_finished=true; shift ;;
                --interactive) interactive=true; shift ;;
                --dns|--volume) option="$1"; value="$2"; shift 2; [[ "$option" == --volume ]] && volumes+=("$value") ;;
                *) exit 27 ;;
            esac
        done
        [[ "$remove_when_finished" == true && "$interactive" == true ]] || exit 28
        [[ "${#volumes[@]}" == 1 && "${volumes[0]}" == *:/output ]] || exit 29
        output_dir="${volumes[0]%:/output}"
        [[ -n "$output_dir" ]] || exit 30
        [[ "$1" == fedora:latest && "$2" == /bin/bash && "$3" == -lc ]] || exit 31
        /usr/bin/tar -tf - >"$FAKE_ARCHIVE"
        [[ "${FAKE_FAIL:-}" != run-late ]] || exit 24
        case "${FAKE_OUTPUT_TYPE:-regular}" in
            regular) printf 'kernel bundle\n' >"$output_dir/kernel.c" ;;
            missing) ;;
            empty) : >"$output_dir/kernel.c" ;;
            symlink) ln -s /dev/null "$output_dir/kernel.c" ;;
            directory) mkdir "$output_dir/kernel.c" ;;
            *) exit 32 ;;
        esac
        ;;
    *) exit 33 ;;
esac
SH
    chmod +x "$FIXTURE/bin/$adapter"
}

make_fixture() {
    local name="$1" adapters="$2"
    FIXTURE="$TEMP_ROOT/$name"
    mkdir -p "$FIXTURE/bin" "$FIXTURE/space source/linux-stale" \
        "$FIXTURE/space source/.git" "$FIXTURE/space source/tarballs"
    cp "$ROOT/build_in_docker.sh" "$FIXTURE/space source/build_in_docker.sh"
    chmod +x "$FIXTURE/space source/build_in_docker.sh"
    printf 'source\n' >"$FIXTURE/space source/Makefile"
    printf 'stale\n' >"$FIXTURE/space source/kernel.c"
    printf 'stale\n' >"$FIXTURE/space source/linux-stale/old"
    printf 'generated\n' >"$FIXTURE/space source/qboot.c"
    printf 'generated\n' >"$FIXTURE/space source/initrd.c"
    printf 'generated\n' >"$FIXTURE/space source/vmlinux"
    printf 'generated\n' >"$FIXTURE/space source/libkrunfw.5.dylib"
    printf 'generated\n' >"$FIXTURE/space source/libkrunfw.so.5.6.1"
    printf 'generated\n' >"$FIXTURE/space source/libkrunfw.dll"
    printf 'generated\n' >"$FIXTURE/space source/libkrunfw.lib"
    printf 'generated\n' >"$FIXTURE/space source/libkrunfw.exp"
    printf 'generated\n' >"$FIXTURE/space source/libkrunfw.obj"
    printf 'generated\n' >"$FIXTURE/space source/libkrunfw.pdb"
    printf 'generated\n' >"$FIXTURE/space source/.kernel.c.next.stale"
    printf 'cache\n' >"$FIXTURE/space source/tarballs/linux.tar.gz"
    : >"$FIXTURE/log"
    for adapter in $adapters; do make_adapter "$adapter"; done
}

run_helper() {
    PATH="$FIXTURE/bin:/usr/bin:/bin" FAKE_LOG="$FIXTURE/log" FAKE_ARCHIVE="$FIXTURE/archive" \
        LIBKRUNFW_BUILD_BACKEND="$1" LIBKRUNFW_BUILD_DNS="${2:-}" \
        "$FIXTURE/space source/build_in_docker.sh" >"$FIXTURE/out" 2>"$FIXTURE/err"
}

assert_filtered_archive() {
    assert_contains "$FIXTURE/archive" './Makefile'
    assert_contains "$FIXTURE/archive" './tarballs/linux.tar.gz'
    for excluded in './kernel.c' linux-stale .git qboot.c initrd.c vmlinux \
        libkrunfw.5.dylib libkrunfw.so.5.6.1 libkrunfw.dll libkrunfw.lib libkrunfw.exp \
        libkrunfw.obj libkrunfw.pdb .kernel.c.next.stale .libkrunfw-output.; do
        assert_not_contains "$FIXTURE/archive" "$excluded"
    done
}

assert_common_transport() {
    local adapter="$1"
    assert_count 1 "$adapter <run>" "$FIXTURE/log"
    assert_contains "$FIXTURE/log" "$adapter <run> <--rm> <--interactive>"
    assert_contains "$FIXTURE/log" '<--volume>'
    assert_contains "$FIXTURE/log" ':/output>'
    assert_not_contains "$FIXTURE/log" '<--detach>'
    assert_not_contains "$FIXTURE/log" '<--name>'
    assert_not_contains "$FIXTURE/log" '<exec>'
    assert_not_contains "$FIXTURE/log" '<copy>'
    assert_not_contains "$FIXTURE/log" '<cp>'
    assert_not_contains "$FIXTURE/log" '<delete>'
    assert_not_contains "$FIXTURE/log" '<rm>'
    assert_not_contains "$FIXTURE/log" ':/work>'
    assert_contains "$FIXTURE/log" 'tar -xf - -C /work'
    # shellcheck disable=SC2016 # The container program must retain this literal expansion.
    assert_contains "$FIXTURE/log" 'make -j"$(nproc)" kernel.c'
    assert_contains "$FIXTURE/log" 'cp kernel.c /output/kernel.c'
    assert_not_contains "$FIXTURE/log" '<--dns>'
    assert_contains "$FIXTURE/out" 'container-native /work'
    assert_contains "$FIXTURE/out" 'Publishing kernel.c result'
    assert_filtered_archive
    [[ "$(cat "$FIXTURE/space source/kernel.c")" == 'kernel bundle' ]] || fail 'kernel.c was not published'
    assert_no_staging
}

# Explicit selectors use their requested backend and both share the one-shot
# stdin-to-/work-to-one-artifact public transport contract.
make_fixture container container
run_helper container
assert_contains "$FIXTURE/log" 'container <system> <status>'
assert_common_transport container

make_fixture docker docker
run_helper docker
assert_contains "$FIXTURE/log" 'docker <info>'
assert_common_transport docker

# DNS remains inherited by default. A caller may opt in to one validated
# resolver for a broken container runtime without hardcoding a public DNS.
make_fixture container-dns container
run_helper container 1.1.1.1
assert_contains "$FIXTURE/log" '<--dns> <1.1.1.1>'
assert_not_contains "$FIXTURE/out" 'DNS override'

make_fixture docker-dns docker
run_helper docker 192.0.2.53
assert_contains "$FIXTURE/log" '<--dns> <192.0.2.53>'

for invalid_dns in resolver.example 999.1.1.1; do
    make_fixture "invalid-dns-$invalid_dns" container
    if run_helper container "$invalid_dns"; then fail "invalid DNS override $invalid_dns unexpectedly succeeded"; fi
    assert_contains "$FIXTURE/err" 'LIBKRUNFW_BUILD_DNS must be an IPv4 address'
    assert_not_contains "$FIXTURE/log" 'container <run>'
done

# auto prefers Apple Container, but uses Docker when Container is not installed.
make_fixture auto-container 'container docker'
run_helper auto
assert_contains "$FIXTURE/log" 'container <system> <status>'
assert_not_contains "$FIXTURE/log" 'docker <info>'

make_fixture auto-docker docker
run_helper auto
assert_contains "$FIXTURE/log" 'docker <info>'
assert_not_contains "$FIXTURE/log" 'container <system> <status>'

make_fixture invalid container
if run_helper invalid; then fail 'invalid backend unexpectedly succeeded'; fi
assert_contains "$FIXTURE/err" 'must be auto, container, or docker'

make_fixture unavailable-container docker
if run_helper container; then fail 'unavailable selected container unexpectedly succeeded'; fi
assert_contains "$FIXTURE/err" 'Apple container CLI is unavailable'
assert_not_contains "$FIXTURE/log" 'docker <'

# Hosted CI exposes a real Docker binary under /usr/bin, unlike many local
# macOS setups. Shadow it with a stopped adapter so this contract never leaks
# to a host daemon while still proving explicit Docker does not fall back.
make_fixture unavailable-docker container
make_adapter docker
if FAKE_FAIL=info run_helper docker; then fail 'unavailable selected Docker unexpectedly succeeded'; fi
assert_contains "$FIXTURE/err" 'Docker daemon is unavailable'
assert_not_contains "$FIXTURE/log" 'container <'

make_fixture stopped-container container
if FAKE_FAIL=status run_helper container; then fail 'stopped container service unexpectedly succeeded'; fi
assert_contains "$FIXTURE/err" "container system start"

make_fixture stopped-docker docker
if FAKE_FAIL=info run_helper docker; then fail 'stopped Docker daemon unexpectedly succeeded'; fi
assert_contains "$FIXTURE/err" 'start Docker Desktop'

# Either side of the streaming pipeline can fail without replacing the prior
# result, and helper-owned output staging is always removed.
for failure in run-early run-late; do
    make_fixture "failure-$failure" container
    printf 'prior kernel\n' >"$FIXTURE/space source/kernel.c"
    if FAKE_FAIL="$failure" run_helper container; then fail "$failure failure unexpectedly succeeded"; fi
    [[ "$(cat "$FIXTURE/space source/kernel.c")" == 'prior kernel' ]] || fail "$failure replaced prior kernel.c"
    assert_no_staging
done

# A shadowed source tar producer proves pipefail catches producer failure; the
# fake runtime inspects input with /usr/bin/tar and cannot mask this result.
make_fixture producer-failure container
cat >"$FIXTURE/bin/tar" <<'SH'
#!/usr/bin/env bash
/usr/bin/tar "$@"
exit 33
SH
chmod +x "$FIXTURE/bin/tar"
printf 'prior kernel\n' >"$FIXTURE/space source/kernel.c"
if run_helper container; then fail 'producer failure unexpectedly succeeded'; fi
assert_contains "$FIXTURE/archive" './Makefile'
[[ "$(cat "$FIXTURE/space source/kernel.c")" == 'prior kernel' ]] || fail 'producer failure replaced prior kernel.c'
assert_no_staging

# Result publication accepts only a nonempty, non-symlink regular file.
for output_type in missing empty symlink directory; do
    make_fixture "malformed-$output_type" container
    printf 'prior kernel\n' >"$FIXTURE/space source/kernel.c"
    if FAKE_OUTPUT_TYPE="$output_type" run_helper container; then fail "$output_type output unexpectedly succeeded"; fi
    [[ "$(cat "$FIXTURE/space source/kernel.c")" == 'prior kernel' ]] || fail "$output_type output replaced prior kernel.c"
    assert_no_staging
done

# Publication works for absent and existing regular files, while a directory
# target is rejected before the expensive runtime command starts.
make_fixture absent-target container
rm "$FIXTURE/space source/kernel.c"
run_helper container
[[ "$(cat "$FIXTURE/space source/kernel.c")" == 'kernel bundle' ]] || fail 'absent target was not published'
assert_no_staging

make_fixture directory-target container
rm "$FIXTURE/space source/kernel.c"
mkdir "$FIXTURE/space source/kernel.c"
if run_helper container; then fail 'directory target unexpectedly succeeded'; fi
assert_contains "$FIXTURE/err" 'kernel.c is a directory'
assert_not_contains "$FIXTURE/log" 'container <run>'
assert_no_staging

echo 'build_in_docker contract: PASS'
