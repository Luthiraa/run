# Run

Run is a single-process x86-64 Linux VMM. It loads a 64-bit `bzImage`, sets
boot parameters, identity maps and ACPI, then starts KVM vCPU threads. Guests
get irqchip/PIT, 8250 serial, block at `0xd0000000` (IRQ 5), and optional TAP
networking at `0xd0001000` (IRQ 6).

## Practical work

Run boots appliances, CI workers, test systems, recovery images and services
from a kernel, raw root image and optional initrd. It supports eight VM slots,
1–8 vCPUs and 16–3072 MiB per VM. Private disk mappings preserve the base;
checkpoints store cumulative changed pages for golden images and reproducers.
They are disk-only, not CPU/RAM/device snapshots or live migration.

With TAP privileges, VM `N` creates `mcN`, host `10.0.N.1/24`, guest
`10.0.N.2`. Routing/NAT is host setup; no DHCP, firewall, offload or multiqueue.

## Build and boot

Requires Zig 0.16, Linux x86-64, `/dev/kvm`, and a kernel with Linux boot
protocol ≥2.12. Build virtio-mmio, virtio-blk, serial console and root drivers
into the kernel or pass an initrd.

```sh
zig build
zig build size       # proves executable + source + docs ≤100 KB
./zig-out/bin/run --no-net --disk root.img --cmdline 'root=/dev/vda rw' bzImage
```

`zig build test` runs on x86-64 Linux; `zig build test-build` emits a runner.
The service listens only on `127.0.0.1:8080`; `--api` changes it. Boot options:
`--disk`, `--initrd`, `--overlay`, `--cpus`, `--mem`, `--cmdline`, `--no-net`.

## Control and state

`POST /vms` accepts URL-encoded `kernel`, `disk`, `initrd`, `overlay`, `cpus`,
`mem`, `cmdline`, and `net`. `POST /vms/<id>/start|stop|snap` controls a VM.
`GET /vms` returns NDJSON, `GET /vms/<id>` returns one VM, and
`GET /vms/<id>/console` returns serial output. `DELETE /vms/<id>` stops it.

Snapshots are exclusive-created and synced as `vm<ID>.disk.<generation>.snap`.
Quiesce the guest filesystem, then restart against the same base with
`--overlay PATH`. Stop discards unsaved private writes.

Guest addresses, queues, disk ranges, kernel placement and HTTP framing are
checked; vCPU threads install a syscall allowlist. This is trusted local
administration: VMs share a process, HTTP has no authentication, and it is not
a hostile multi-tenant boundary. Qualify boot and performance on the target host.
