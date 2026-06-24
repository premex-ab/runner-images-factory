# Upgrading the host QEMU (parked fix for #23 / #13)

The windows-build crash family — `VSIXInstaller.exe` `STATUS_STACK_OVERFLOW` (`0xC00000FD`) on win25
(**#23**) and `rustc` `STATUS_STACK_BUFFER_OVERRUN` (`0xC0000409`) on win22 (**#13**) — is **not** a cell
bug. Evidence (gathered with the #16 checkpoint loop) points to the **KVM↔guest CPU/state emulation**:
the faulting module is the .NET Framework CLR (`clr.dll`) at *random* offsets, only at high vCPU under
KVM. Disabling CET, switching CPU model (`-cpu EPYC`), and forcing workstation GC all had no effect;
`accel=tcg` (which removes KVM CPU passthrough entirely) sidesteps it but is far too slow to boot.

Our host QEMU is **8.2.2** (the only version Ubuntu 24.04 ships). A **newer QEMU** has materially better
x86 CPU/state emulation and may expose maskable CET (`shstk`) features 8.2 lacks. This is the most
likely real fix — **but it is unverified**; validate with the loop *before* committing to a full rebuild.

> Requires `sudo` on the build host. The steps install a newer QEMU to its own prefix (`/opt/qemu-<ver>`),
> so the distro's `qemu-system-x86_64` is left untouched and you can fall back instantly.

## 1. Build dependencies (sudo)

```sh
sudo apt-get update
sudo apt-get install -y ninja-build meson python3-venv pkg-config libglib2.0-dev libpixman-1-dev libslirp-dev
# (or, if you have deb-src enabled: `sudo apt-get build-dep -y qemu-system-x86`)
```

## 2. Build a recent stable QEMU to a prefix (the build itself needs no sudo until `make install`)

```sh
cd /tmp
QV=9.2.0                       # or the latest stable from https://download.qemu.org/
wget https://download.qemu.org/qemu-$QV.tar.xz
tar xf qemu-$QV.tar.xz && cd qemu-$QV
./configure --target-list=x86_64-softmmu --prefix=/opt/qemu-$QV --enable-kvm --enable-slirp
make -j"$(nproc)"              # ~10-30 min
sudo make install
```

## 3. Verify

```sh
/opt/qemu-9.2.0/bin/qemu-system-x86_64 --version
# did this version gain a maskable CET/shadow-stack property (8.2 had none)?
/opt/qemu-9.2.0/bin/qemu-system-x86_64 -cpu help | grep -iE 'shstk|cet|ibt' || echo "no CET property in this build either"
```

## 4. Validate with the checkpoint loop (no full rebuild)

Point the loop/build at the new binary via `PATH` — both Packer's qemu plugin and `lib/common.sh`'s
`_winrm_boot` resolve `qemu-system-x86_64` from `PATH`:

```sh
export PATH=/opt/qemu-9.2.0/bin:$PATH
qemu-system-x86_64 --version          # confirm it's the new one

# re-run VSExtensions on the existing built image at the failing config:
./build.sh checkpoint windows-2025 rollback
RIF_CP_SMP="cores=14,sockets=2,threads=1" RIF_CP_MEM=16384 \
  ./build.sh checkpoint windows-2025 run --script <re-run Install-VSExtensions>
```

**Success** = `Install-VSExtensions` exits 0 with **no `0xC00000FD` `clr.dll` crashes** in the
`Application Error` event log. If so, the same newer QEMU should also be retested against #13 (rustc on
a win22 build), and then a full rebuild can run with `/opt/qemu-<ver>/bin` on `PATH`.

**If it still crashes** under the newer QEMU, the cause is not the QEMU version — fall back to a
VSIXInstaller crash-dump analysis (procdump on `0xC00000FD`) to read the actual managed stack.
