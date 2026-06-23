# Windows image build playbook

Hard-won notes for building the Windows runner images (`images/windows-2022`,
`images/windows-2025`). These cells run the upstream actions/runner-images `Install-*.ps1`
under Packer / QEMU / WinRM. Read alongside [../CLAUDE.md](../CLAUDE.md).

## Build & verify loop

- **Build**: `./build.sh windows-2022 --iso <server-2022.iso>` →
  `out/windows-2022/image/windows-2022.qcow2`. Discovery mode means the build never aborts on a
  tool failure — grep the log for `@@@FAIL` / `@@@FAILURES:` to see what broke.
- **Verify / inspect** a built image without a rebuild: `lib/common.sh verify_windows()` boots
  the qcow2 in a throwaway overlay with OVMF + WinRM and runs assertions. This is the
  **proven boot-a-built-image-over-WinRM recipe** — q35 + OVMF (fresh NVRAM; an installed disk
  boots via the ESP `bootmgfw.efi` fallback, so no saved efivars needed), IDE system disk +
  e1000 NIC, `hostfwd` for WinRM, creds `Administrator` / the `winrm_password` var. Reuse it to
  hand-run a single `Install-*.ps1` against a finished image (this is how the per-tool issues
  below should be iterated — see #16).

## Visual Studio on Server 2022 (SOLVED — preserve these)

VS is the hardest part of the Windows build; these fixes live in the windows-2022 cell and must
be kept:

- **Multi-pass install gated on the v143 toolset.** Server 2022's VS bootstrapper returns
  reboot-required codes mid-install, so `Install-VisualStudio.ps1` runs up to 4× with reboots,
  each pass *gated on the presence of* `VC\Tools\MSVC\14.4*\...\link.exe` (the v143 / 14.4x
  toolset). Do **not** accept any `link.exe` — a stray v142 (14.29) stub passes a naive check
  but then breaks Rust (it links against the modern Win11 SDK and `rustc` aborts).
- **CPU topology.** A bare `cpus=N` emits `-smp N` = N single-core *sockets*, which Server 2022
  mishandles (the post-install reboot hangs forever). Use native `sockets`/`cores`/`threads`
  (e.g. `28 = 2×14×1`).
- **NativeDesktop completion.** A `setup.exe modify --add ...Workload.NativeDesktop --add
  ...VC.Tools.x86.x64 --includeRecommended --quiet --norestart --nocache` forces the full v143
  toolset. **No `--wait`** — it's a bootstrapper-only arg and the installed `setup.exe` rejects
  it with exit 87. Expect exit 3010 (reboot-required) on success.
- **Votive / WiX v3 VS extension is not installable into VS 17.x** → `0x80131509` ×N. Drop
  `WixToolset.WixToolsetVisualStudio2022Extension` from the toolset in the staging provisioner
  (alongside the SSIS vsix), and provide WiX via the standalone CLI (`Install-Wix.ps1`) instead.
  WiX v4/v5 ship no VS extension anyway.
- **Rust's MSVC linker detection** needs the v143 `link.exe` on `PATH`. Resolve it **off disk**
  (`C:\Program Files\Microsoft Visual Studio\2022\*\VC\Tools\MSVC\14.4*\bin\Hostx64\x64\link.exe`)
  rather than via `vswhere`, which can momentarily return empty right after VSIXInstaller churn.

## Known per-tool issues (in progress)

- **Rust (#13)** — `cargo install` (release/opt-level=3) intermittently crashes `rustc.exe`
  (`0xc0000409` STATUS_STACK_BUFFER_OVERRUN) on crates like `windows-sys` under nested KVM.
  Serializing (`CARGO_BUILD_JOBS=1` + `RUSTFLAGS=-C codegen-units=1`) cuts it from ~20 crashes to
  ~1 per full install; a 4× retry is the current stopgap. Ruled out: `-cpu host`/AVX-512,
  `RUST_MIN_STACK`, Defender. Needs a real root-cause fix.
- **Android SDK (#14)** — `sdkmanager.bat`'s JVM picks the parallel GC sized to the host CPU
  count and can't allocate its mark bitmaps on a high-vCPU VM (`Unable to allocate <N>KB bitmaps
  for parallel garbage collection`). Capping `-Xmx` is insufficient. **Preferred fix: the native
  `android.exe` CLI** (`android sdk install platform-tools build-tools/<v> ...`, no JVM —
  https://developer.android.com/tools/agents). Fallback: `JAVA_TOOL_OPTIONS=-XX:+UseSerialGC`.
- **windows-2025 (#15)** — its `Install-VSExtensions`/`Install-Rust` run in a soft-tally
  `foreach` that *hid* the Votive + Rust failures (and its staging only drops the SSIS vsix, not
  the Wix one). Port the windows-2022 fixes and rebuild + verify.

## Fast iteration (#16) — checkpoint loop

Full rebuilds are ~3–4 h (VS dominates), so a per-tool fix shouldn't need one. The
`./build.sh checkpoint` helper boots a built qcow2 over WinRM (the proven
`verify_windows` recipe, but the disk WRITABLE) and snapshots each step as a qcow2
overlay chain under `out/<image>/checkpoints/`:

    ./build.sh checkpoint windows-2022 init --from out/windows-2022/image/windows-2022.qcow2
    ./build.sh checkpoint windows-2022 run  --script /path/to/fix-rust.ps1   # boot + run + clean shutdown
    ./build.sh checkpoint windows-2022 commit after-rust   # froze it as a checkpoint; or:
    ./build.sh checkpoint windows-2022 rollback            # discard the run, retry a different tweak
    ./build.sh checkpoint windows-2022 list

`run` executes the script(s) in-process with the runner-images env (`IMAGE_FOLDER`,
`IMAGE_OS`, …), so they behave like a `.pkr.hcl` provisioner — the iteration unit is a
chunk of PowerShell (the wrapper logic you're tuning), not just a bare `Install-*.ps1`.
A WinRM drop mid-run is treated as a reboot and reconnected. **Once a tweak works,
fold it back into the `.pkr.hcl` cell** — the checkpoint loop is for discovery; `main`'s
source of truth stays the Packer template. This bypasses Packer (whose *resume* path
can't reconnect WinRM to an already-installed disk); the driver is `lib/winrm_run.py`.
