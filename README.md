# run

A tiny VMM for disposable Linux machines. One static executable, no runtime
dependencies: KVM, SMP, private disks, explicit network grants, and a local API
that agents can use to run commands and keep disk checkpoints.

```sh
zig build && ./zig-out/bin/run --no-net --disk root.img \
  --cmdline 'root=/dev/vda rw' bzImage
```

Built with Zig 0.16 for x86-64 Linux. `zig build size` reports size without an
artificial cutoff. Kernels, guest images and host tools are separate.

[Real-KVM validation](https://github.com/Luthiraa/run/actions/runs/34007715380)
passes with an unmodified Ubuntu kernel: SMP userspace, agent commands, routed
HTTP, live permission revocation, private disk writes and checkpoint restore.
See [SYSTEM.md](SYSTEM.md) for operations, architecture and capability boundaries.

Small is a design constraint, not a substitute for proof. Run is a VMM and a
building block for a personal microcloud—not a multi-tenant cloud platform.
