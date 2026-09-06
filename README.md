# run

A static x86-64 Linux/KVM monitor in Zig: direct Linux boot, SMP, serial,
virtio block/TAP networking, private COW disks and disk checkpoints.

```sh
zig build && ./zig-out/bin/run --no-net --disk root.img \
  --cmdline 'root=/dev/vda rw' bzImage
```

`zig build size` enforces a 100 KB executable-plus-source budget. See
[SYSTEM.md](SYSTEM.md) for operations, API, capability boundaries and design.
