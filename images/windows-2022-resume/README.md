# windows-2022-resume — fast post-VS iteration

Iterating the **Rust** / **VSExtensions** steps of the windows-2022 image used to mean a
full ~80–90 min rebuild (Windows install + Visual Studio's 4-pass reboot dance). This cell
cuts that to **~15 min** by booting a pre-built **VS-complete checkpoint** as its base disk and
running only the cheap tail of the pipeline.

## The pieces

- **`images/windows-2022-checkpoint/`** — the windows-2022 (debug) cell pruned to **stop right
  after Visual Studio is complete**: staging → group 1 (base config) → group 3a (the 4-pass VS
  install) → group 3a-fix (NativeDesktop / MSVC linker completion) → group 3b (vswhere tally +
  KubernetesTools). It produces a **VS-complete** qcow2. **No** VSExtensions, **no** Rust.
- **`checkpoint-save.sh`** (repo root) — copies that finished qcow2 to
  `checkpoints/windows-2022-vsbase.qcow2`, the resume base.
- **`images/windows-2022-resume/`** (this dir) — boots the checkpoint qcow2 as a **backing disk**
  (`disk_image=true` + `use_backing_file=true`) and runs **only** VSExtensions + Rust + a final
  verify. Each run is a throwaway overlay; the checkpoint is never mutated.

## Workflow

```sh
# 1) Build the VS-complete checkpoint once (~80 min). Bring your own Server 2022 ISO.
./build.sh windows-2022-checkpoint --iso /path/to/win-2022.iso
#    (until build.sh has a windows-2022-checkpoint case, run the cell directly:)
#    cd images/windows-2022-checkpoint && packer init . && \
#      packer build -var windows_iso=/path/to/win-2022.iso \
#        -var output_dir="$PWD/../../out/windows-2022-checkpoint/image" .

# 2) Promote it to the resume base (~1 min copy).
./checkpoint-save.sh
#    -> writes checkpoints/windows-2022-vsbase.qcow2

# 3) Iterate Rust / VSExtensions as many times as you like (~15 min each).
cd images/windows-2022-resume && packer init . && packer build .
#    or, from repo root:  packer build images/windows-2022-resume/windows-2022-resume.pkr.hcl
#    override the base ad-hoc:  packer build -var checkpoint_qcow2=/abs/path/to/base.qcow2 .
```

Edit `Install-VSExtensions.ps1` / `Install-Rust.ps1` handling in
`windows-2022-resume.pkr.hcl`, re-run step 3 — no need to touch the checkpoint. Rebuild the
checkpoint (step 1) only when something **before** VSExtensions changes (the OS, base config, or
Visual Studio itself).

## How the disk is wired (don't "fix" this)

- `disk_image = true` → Packer treats `iso_url` (the checkpoint qcow2) as a **bootable disk**, not
  install media. There is no Autounattend / `cd_files` / `boot_command` — the OS is already
  installed; the resume cell just boots it and connects over WinRM with the same creds.
- `use_backing_file = true` (qcow2 only) → Packer makes a **new** qcow2 with the checkpoint as its
  backing file. Only changed blocks are written, so the **pristine checkpoint is never mutated**
  (every run is a throwaway overlay). This also forces `skip_compaction = true`.
- `iso_checksum = "none"` — the base is a local, trusted build artifact.

## OVMF / UEFI boot of an installed disk (the make-or-break detail)

The resume cell boots with a **fresh `OVMF_VARS` template** (`var.ovmf_vars`, default
`/usr/share/OVMF/OVMF_VARS_4M.fd`) — it does **not** carry a saved per-build NVRAM.

This is exactly what `lib/common.sh`'s `verify_windows()` does: it boots the *finished* install
with `cp /usr/share/OVMF/OVMF_VARS_4M.fd "$wd/vars.fd"` (a pristine template) and it boots fine.
An installed Windows disk doesn't need a saved boot entry — OVMF's removable-media **fallback**
finds `\EFI\Microsoft\Boot\bootmgfw.efi` (and `\EFI\Boot\bootx64.efi`) on the ESP and boots it.
So:

- `checkpoint-save.sh` saves **only the qcow2** — no efivars file to carry.
- The resume cell supplies a fresh `var.ovmf_vars` and lets the firmware find Windows on the ESP.

Same machine shape as the install cell throughout: `q35` + `accel=kvm`, OVMF code/vars pflash,
`disk_interface=ide` + `net_device=e1000` (Windows inbox drivers → WinRM works on boot),
`-cpu host` (Server 2022 needs SSE4.2 + POPCNT), 28 vCPU / 48 GiB. The runtime launcher must boot
it the same way (IDE + e1000).
