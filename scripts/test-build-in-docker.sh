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
        [[ "${FAKE_FAIL:-}" != run ]] || exit 23
        ;;
    container/exec|docker/exec)
        [[ "${FAKE_FAIL:-}" != exec ]] || exit 24
        ;;
    container/copy|docker/cp)
        if [[ "$2" == *:/work/kernel.c ]]; then
            [[ "${FAKE_FAIL:-}" != copy-out ]] || exit 25
            case "${FAKE_OUTPUT_TYPE:-regular}" in
                regular) printf 'kernel bundle\n' >"$3" ;;
                symlink) ln -s /dev/null "$3" ;;
                directory) mkdir "$3" ;;
                *) exit 28 ;;
            esac
        else
            [[ "${FAKE_FAIL:-}" != copy-in ]] || exit 26
            tar -tf "$2" >"$FAKE_ARCHIVE"
        fi
        ;;
    container/delete|docker/rm)
        ;;
    *) exit 27 ;;
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
        libkrunfw.obj libkrunfw.pdb .kernel.c.next.stale; do
        assert_not_contains "$FIXTURE/archive" "$excluded"
    done
}

assert_common_transport() {
    local adapter="$1" copy_command="$2" delete_command="$3"
    assert_contains "$FIXTURE/log" "$adapter <run> <--detach>"
    assert_contains "$FIXTURE/log" '<--name>'
    assert_contains "$FIXTURE/log" '</usr/bin/sleep> <infinity>'
    assert_contains "$FIXTURE/log" "$adapter <exec>"
    assert_contains "$FIXTURE/log" '</usr/bin/true>'
    assert_contains "$FIXTURE/log" '/work'
    # shellcheck disable=SC2016 # The container program must retain this literal expansion.
    assert_contains "$FIXTURE/log" 'make -j"$(nproc)" kernel.c'
    assert_count 1 ':/tmp/libkrunfw-source.tar' "$FIXTURE/log"
    assert_count 1 ':/work/kernel.c' "$FIXTURE/log"
    assert_contains "$FIXTURE/log" "$adapter <$copy_command>"
    assert_contains "$FIXTURE/log" "$adapter <$delete_command> <--force>"
    assert_not_contains "$FIXTURE/log" '<-v>'
    assert_not_contains "$FIXTURE/log" '<--volume>'
    assert_not_contains "$FIXTURE/log" '<--mount>'
    assert_not_contains "$FIXTURE/log" '<--dns>'
    assert_contains "$FIXTURE/out" 'Uploading filtered source snapshot'
    assert_contains "$FIXTURE/out" 'container-native /work'
    assert_contains "$FIXTURE/out" 'Publishing kernel.c result'
    assert_filtered_archive
    [[ "$(cat "$FIXTURE/space source/kernel.c")" == 'kernel bundle' ]] || fail 'kernel.c was not published'
    ! find "$FIXTURE/space source" -maxdepth 1 -name '.kernel.c.next.*' ! -name '.kernel.c.next.stale' -print -quit | grep -q . || fail 'candidate output was not cleaned'
}

# Explicit selectors use their requested backend and both share the same
# archive-to-/work-to-one-artifact public transport contract.
make_fixture container container
run_helper container
assert_contains "$FIXTURE/log" 'container <system> <status>'
assert_common_transport container copy delete

make_fixture docker docker
run_helper docker
assert_contains "$FIXTURE/log" 'docker <info>'
assert_common_transport docker cp rm

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

make_fixture unavailable-docker container
if run_helper docker; then fail 'unavailable selected Docker unexpectedly succeeded'; fi
assert_contains "$FIXTURE/err" 'Docker is unavailable'
assert_not_contains "$FIXTURE/log" 'container <'

make_fixture stopped-container container
if PATH="$FIXTURE/bin:/usr/bin:/bin" FAKE_LOG="$FIXTURE/log" FAKE_ARCHIVE="$FIXTURE/archive" FAKE_FAIL=status LIBKRUNFW_BUILD_BACKEND=container "$FIXTURE/space source/build_in_docker.sh" >"$FIXTURE/out" 2>"$FIXTURE/err"; then
    fail 'stopped container service unexpectedly succeeded'
fi
assert_contains "$FIXTURE/err" "container system start"

make_fixture stopped-docker docker
if PATH="$FIXTURE/bin:/usr/bin:/bin" FAKE_LOG="$FIXTURE/log" FAKE_ARCHIVE="$FIXTURE/archive" FAKE_FAIL=info LIBKRUNFW_BUILD_BACKEND=docker "$FIXTURE/space source/build_in_docker.sh" >"$FIXTURE/out" 2>"$FIXTURE/err"; then
    fail 'stopped Docker daemon unexpectedly succeeded'
fi
assert_contains "$FIXTURE/err" 'start Docker Desktop'

# Every lifecycle failure preserves an existing result and deletes only the
# helper's uniquely named container. The fake does not model unrelated names.
for failure in run exec copy-in copy-out; do
    make_fixture "failure-$failure" container
    printf 'prior kernel\n' >"$FIXTURE/space source/kernel.c"
    if PATH="$FIXTURE/bin:/usr/bin:/bin" FAKE_LOG="$FIXTURE/log" FAKE_ARCHIVE="$FIXTURE/archive" FAKE_FAIL="$failure" LIBKRUNFW_BUILD_BACKEND=container "$FIXTURE/space source/build_in_docker.sh" >"$FIXTURE/out" 2>"$FIXTURE/err"; then
        fail "$failure failure unexpectedly succeeded"
    fi
    [[ "$(cat "$FIXTURE/space source/kernel.c")" == 'prior kernel' ]] || fail "$failure replaced prior kernel.c"
    if [[ "$failure" != run ]]; then
        assert_contains "$FIXTURE/log" 'container <delete> <--force>'
    fi
    ! find "$FIXTURE/space source" -maxdepth 1 -name '.kernel.c.next.*' ! -name '.kernel.c.next.stale' -print -quit | grep -q . || fail "$failure left a candidate output"
done

# Result copy must be a nonempty regular file. Malformed copy results leave the
# previously published kernel untouched and remove all helper-owned staging.
for output_type in symlink directory; do
    make_fixture "malformed-$output_type" container
    printf 'prior kernel\n' >"$FIXTURE/space source/kernel.c"
    if PATH="$FIXTURE/bin:/usr/bin:/bin" FAKE_LOG="$FIXTURE/log" FAKE_ARCHIVE="$FIXTURE/archive" FAKE_OUTPUT_TYPE="$output_type" LIBKRUNFW_BUILD_BACKEND=container "$FIXTURE/space source/build_in_docker.sh" >"$FIXTURE/out" 2>"$FIXTURE/err"; then
        fail "$output_type output unexpectedly succeeded"
    fi
    [[ "$(cat "$FIXTURE/space source/kernel.c")" == 'prior kernel' ]] || fail "$output_type output replaced prior kernel.c"
    ! find "$FIXTURE/space source" -maxdepth 1 -name '.kernel.c.next.*' ! -name '.kernel.c.next.stale' -print -quit | grep -q . || fail "$output_type output left a candidate"
done

echo 'build_in_docker contract: PASS'
