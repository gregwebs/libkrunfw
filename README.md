# libkrunfw

```libkrunfw``` is a library bundling a Linux kernel in a dynamic library in a way that can be easily consumed by [libkrun](https://github.com/containers/libkrun).

By having the kernel bundled in a dynamic library, ```libkrun``` can leave to the linker the work of mapping the sections into the process, and then directly inject those mappings into the guest without any kind of additional work nor processing.

## Building

### Linux (generic variant)

#### Requirements
* The toolchain your distribution needs to build a Linux kernel.
* Python 3
* ```pyelftools``` (package ```python3-pyelftools``` in Fedora)

On Debian/Ubuntu:

```sh
apt install python3-pyelftools build-essential flex bison libelf-dev
```

#### Building and installing the library
```
make
sudo make install
```

### Linux (SEV variant)

#### Requirements
* The toolchain your distribution needs to build a Linux kernel.
* Python 3
* ```pyelftools``` (package ```python3-pyelftools``` in Fedora and Ubuntu)

#### Building and installing the library
```
make SEV=1
sudo make SEV=1 install
```

### macOS

#### Requirements

Compiling a Linux kernel natively on macOS is not practical. Use the
[Apple Container or Docker native-storage flow](#building-the-kernel-bundle-with-apple-container-or-docker)
below for the kernel bundle. `build_on_krunvm.sh` remains an alternative for
installations that already use [krunvm](https://github.com/containers/krunvm)
and its dependencies.

#### Alternative: building the library using krunvm
```
./build_on_krunvm.sh
make
```

#### Building the kernel bundle with Apple Container or Docker

`build_in_docker.sh` keeps its historical name for callers, but builds the
kernel source on container-native Linux storage. It archives the checkout,
copies that snapshot into `/work`, and copies only the completed `kernel.c`
back. It never extracts a Linux tree on a macOS bind mount.

```sh
# auto prefers Apple's CLI when installed, then Docker
./build_in_docker.sh
# select one backend without fallback
LIBKRUNFW_BUILD_BACKEND=container ./build_in_docker.sh
LIBKRUNFW_BUILD_BACKEND=docker ./build_in_docker.sh
```

Start the Apple service with `container system start` when required. Docker
remains a compatible fallback. The selected backend must be running; an
explicit selection never changes engines silently.

By default, the build environment is based on a Fedora image. There is also a Debian variant which can be selected by setting the `BUILDER` environment variable.

```
BUILDER=debian ./build_on_krunvm.sh
```

In general, `./build_on_krunvm.sh` will always delegate to `./build_on_krunvm_${BUILDER}.sh` so additional environments can be added like this if needed.

### Windows

#### Requirements
* Docker Desktop for building the Linux kernel bundle.
* Visual Studio Build Tools with the **Desktop development with C++** workload.

#### Building the DLL
The Linux kernel is built inside Docker using the existing Makefile flow. By default the script runs the Docker builder as `linux/amd64`, matching the current Windows x86_64 DLL/release path and the available SEV/TDX kernel configs. Windows then consumes the generated `kernel.c` bundle and links it into a native DLL with MSVC:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1
```

Use `-DockerPlatform` to select a different Linux builder platform when intentionally producing a different guest kernel architecture.

If `kernel.c` already exists, skip the Docker step and only link/verify the DLL:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -SkipKernelBundle
```

Build the SEV or TDX variants by selecting the variant explicitly:

```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Variant sev
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-windows.ps1 -Variant tdx
```

The scripts discover Visual Studio Build Tools with `vswhere` and initialize the MSVC environment automatically. If GNU `make` is available in the same MSVC-configured shell, `make WINDOWS_TOOLCHAIN=msvc` is also supported as a convenience wrapper. The native PowerShell scripts are the canonical Windows path.

The generic Windows build exports `krunfw_get_kernel` and `krunfw_get_version`. SEV and TDX builds use `libkrunfw-tee.def`, bundle the matching qboot firmware and initrd, and also export `krunfw_get_qboot` and `krunfw_get_initrd`.

### Windows cross-compilation from Linux

#### Requirements
* A Linux host with the toolchain needed to build a Linux kernel.
* The MinGW-w64 cross-compiler (`x86_64-w64-mingw32-gcc`), available as `mingw-w64-gcc` (Fedora) or `gcc-mingw-w64-x86-64` (Debian/Ubuntu).
* Python 3
* ```pyelftools``` (package ```python3-pyelftools``` in Fedora and Ubuntu)

#### How it works

The Windows build uses a dedicated kernel configuration (`config-libkrunfw-windows_x86_64`) that enables Hyper-V guest enlightenments (`CONFIG_HYPERV`, `CONFIG_HYPERV_TIMER`, `CONFIG_HYPERV_UTILS`), allowing the guest kernel to take advantage of the Windows Hypervisor Platform (WHP).

The resulting `libkrunfw.dll` is produced using the MinGW-w64 toolchain and can be consumed by the Windows build of [libkrun](https://github.com/containers/libkrun).

#### Building the library
```
make OS=Windows WINDOWS_TOOLCHAIN=mingw
```

This will:
1. Download and patch the kernel sources.
2. Build the kernel using the Windows-specific configuration.
3. Generate the C bundle.
4. Cross-compile `libkrunfw.dll` using `x86_64-w64-mingw32-gcc`.

## Known limitations

* To save memory, the embedded kernel is configured with a limited number of CPUS. The CPU limit depends on the config target. If this kernel runs in a VM with more CPUs than it is configured for, only the first N CPUs will be initialized and used.

| Target         | `NR_CPUS=` |
|----------------|------------|
| x86_64         | 16         |
| sev_x86_64     | 8          |
| tdx_x86_64     | 8          |
| windows_x86_64 | 16         |
| aarch64        | 16         |
| riscv64        | 16         |

## License

This library bundles a Linux kernel but does not execute any code from it, acting as a mere storage format. As a consequence, this library does not constitute a derivative work of the Linux kernel. Thus, the following licenses apply:

* **Linux kernel**: GPL-2.0-only

* **Files contained in the ```patches``` directory**: GPL-2.0-only

* **Library code, including automatically-generated code**: LGPL-2.1-only

Therefore, distributions of this library in binary form are required to be accompanied by the source code of the Linux kernel bundled in the binary along with the code of the library itself, but other programs linking against this library are not required to be licensed under the GPL-2.0-only nor the LGPL-2.1-only licenses.
