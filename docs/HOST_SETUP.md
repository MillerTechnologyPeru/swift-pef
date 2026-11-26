# Host Setup & Build Instructions (`QEMU mac99` & `iBook G4`)

## 1. Linux Kernel Configuration (`ppc32` Big-Endian)

### Enable Zero-Page Mapping for Low-Memory Globals (`0x0000`–`0x2000`)
Classic Mac OS 9 binaries occasionally dereference low-memory global addresses directly (e.g., `Ticks` at `0x016A`, `CurrentA5` at `0x0904`). Allow unprivileged `mmap` at address `0x0`:

```bash
echo "vm.mmap_min_addr = 0" | sudo tee /etc/sysctl.d/99-bluebox.conf
sudo sysctl --system
```

### iBook G4 ATI Mobility Radeon AGP Stability
On Linux `powerpc` kernels, the iBook G4's ATI Mobility Radeon 9200 (`r200`) or 9550 (`r300`) can lock up under 3D Mesa load when AGP GART is enabled. Force PCI GART mode in `/etc/yaboot.conf` or `/etc/default/grub`:

```text
append="radeon.agpmode=-1"
```

Reboot and verify via `dmesg | grep -i agp` that PCI GART mode is active.

---

## 2. QEMU `mac99` Development Environment

Launch a 32-bit big-endian PowerPC G4 guest with AC97/Screamer audio and 2D framebuffer support:

```bash
qemu-system-ppc \
  -M mac99,via=pmu \
  -cpu 7447a \
  -m 1024 \
  -drive file=ppc32-linux.qcow2,format=qcow2,if=ide \
  -device AC97 \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device sungem,netdev=net0 \
  -display sdl
```

* **Graphics Backend**: Pass `--renderer software` to `bluebox` on QEMU `mac99` to blit QuickDraw `PixMap` dirty rects directly via SDL/DRM without software Mesa overhead.
* **GDB Debugging**: Run `gdb --args .build/debug/bluebox /path/to/App` and set breakpoints on `mora_to_sysv_thunk` or `swift_dispatch_cfm_call` to inspect `MORAInvocationFrame` registers (`r3–r10`, `f1–f13`).

---

## 3. Building with Swift on `ppc32` Linux

### Release Build (Recommended for iBook G4 & QEMU)
Enable Whole Module Optimization (`-wmo`) so Embedded Swift specializes generic big-endian memory readers and LLVM vectorizes `QuickDraw` `CopyBits` loops using AltiVec:

```bash
swift build -c release \
  -Xswiftc -wmo \
  -Xcc -O3 \
  -Xcc -maltivec
```

### Packaging Classic Mac Apps on Linux `ext4`
Because Linux `ext4` does not natively store dual-fork HFS+ files unless extended attributes are preserved, `BlueBox` accepts three formats out of the box:
1. **AppleDouble Sidecar**: Place `AppName` (data fork) and `._AppName` (resource fork) in the same directory.
2. **MacBinary Archive**: Pass `AppName.bin` directly (`bluebox AppName.bin`).
3. **Extended Attributes**: Store the resource fork in `user.com.apple.ResourceFork` via `setfattr`.
