# run — system guide

Run is a single-process x86-64 Linux/KVM monitor. The core is one Zig source
file using the standard library and Linux syscalls directly. No libc, device
framework, guest daemon or language runtime is linked into the executable.
The optional agent client uses Python's standard library; host routing uses
iproute2 and iptables. Those tools, Linux, KVM and guest images are separate.

## Practical work

Boot a disposable worker from a shared raw base, grant only its required network
destinations, execute commands, collect output and exit status, then discard
changes—or keep a disk checkpoint. Useful for local agent jobs, appliance tests,
reproducible bug environments and small CI workers. Applications and compilers
run inside the guest; Run does not package them or translate container images.

Eight VM slots support 1–8 vCPUs and 16–3072 MiB each. These are configuration
limits, not a promise that a distribution boots in 16 MiB. The integration
fixture uses two vCPUs and 256 MiB.
The process also requests a 12 GiB virtual-address limit, shared across VM RAM,
disk mappings and other allocations; maximum slot settings are not additive.

## Build and boot

Build with Zig 0.16. Run on x86-64 Linux with accessible `/dev/kvm`; networking
also needs `/dev/net/tun` and CAP_NET_ADMIN. No-network operation does not need
root if device and image permissions allow it.

```sh
zig build
zig build size             # reports bytes; no hard budget
zig build test             # tests on x86-64 Linux
./zig-out/bin/run --disk root.img --cmdline 'root=/dev/vda rw' bzImage
```

The kernel needs the 64-bit Linux boot protocol ≥2.12, ACPI, 8250 serial and
virtio-mmio. Include virtio-blk, virtio-net and filesystem drivers in the kernel
or pass `--initrd initrd`. Other options: `--cpus`, `--mem` (MiB), `--overlay`,
`--allow`, `--no-net`, `--api` (port, default 8080), and `--cmdline`.
Without a kernel argument, only the control service starts.

## Agent commands

Run a shell on guest ttyS0. For a disposable BusyBox initramfs, after mounting
proc, sysfs and devtmpfs, use `exec setsid cttyhack sh` with standard streams
connected to `/dev/console`. A production image should configure its own login
policy. `tests/kvm.py` constructs a complete example initramfs.

```sh
python3 tools/agent.py --vm 0 'uname -a; printf hello'
```

Returns JSON containing `stdout` and `exit_code`, and exits with the guest
status. The client uses serial I/O, unique delimiters and a deadline: no guest
RPC daemon. Allow one command owner per VM. Output is text; encoded shell lines
are limited to 3000 bytes and collected output to 1 MiB. The serial ring retains
only the newest 64 KiB; an overrun fails explicitly. A timeout does **not**
cancel the command: stop/delete the VM to terminate the job. This is a trusted
shell convenience protocol, not authenticated RPC against a malicious guest.

## Explicit network permissions

Networking is absent by default. A grant enables a TAP-backed virtio NIC:

```sh
sudo ./zig-out/bin/run --allow 'tcp:198.18.0.2:18081' \
  --initrd initrd --disk root.img bzImage
sudo sh tools/egress.sh up 0 eth0    # replace eth0 with your host uplink
```

VM N gets TAP `runN`, host `10.0.N.1/24`, guest `10.0.N.2`, gateway `10.0.N.1`.
Configure this static address in the guest. Run also supplies Linux's `ip=`
parameter, but not every kernel enables IP autoconfiguration. No DHCP or DNS
server is provided.

Rules are comma-separated `protocol:IPv4[/prefix]:port`. Protocol is `tcp`,
`udp` or `icmp`; default prefix is /32. Port 0 means any port and is required
for ICMP. Maximum 16 rules. DNS requires a separate resolver grant, usually
UDP and TCP port 53. Permissions are IP-based, not domain-based.

Before each outbound frame reaches TAP, Run checks source MAC/IP, bounds,
protocol, destination CIDR and port. Only gateway ARP is permitted. IPv6, VLANs,
IPv4 options, fragments and other Ethernet protocols are dropped. Every packet
is checked, including existing connections. Revocation blocks subsequent
transmission but cannot retract packets already sent or buffered. This is an
egress policy, not an inbound firewall or stateful connection tracker. Do not
bridge TAP onto an untrusted network.

```sh
curl -X POST --data-binary 'tcp:198.18.0.2:18081' \
  http://127.0.0.1:8080/vms/0/permissions
curl -X POST --data-binary '' http://127.0.0.1:8080/vms/0/permissions
sudo sh tools/egress.sh down 0 eth0
```

The second request revokes all IP egress. Updates atomically replace the entire
policy; malformed policies fail. They do not hot-plug a missing NIC. Create
with `net=1` for a NIC with initially empty grants.

The helper explicitly enables host IPv4 forwarding and adds idempotent,
VM-specific NAT/forwarding rules. Existing firewall rules can still block traffic.
`down` removes only its exact rules and leaves forwarding enabled for other
workloads. Host routing never bypasses the VMM's packet checks.

## HTTP API

The service binds only `127.0.0.1`. It is trusted local administration, without
authentication or TLS; never expose it through an unauthenticated proxy.
Paths refer to host files, not uploads.

| Request | Effect |
| --- | --- |
| `POST /vms` | Create; URL-encoded `kernel`, `initrd`, `disk`, `overlay`, `cpus`, `mem`, `cmdline`, `net`, `allow` |
| `GET /vms` | List as newline-delimited JSON |
| `GET /vms/N` | State, configuration, grant count, denied frames and console cursor |
| `POST /vms/N/start` | Start |
| `POST /vms/N/stop` | Stop; discard unsaved writes |
| `POST /vms/N/snap` | Save cumulative disk changes |
| `DELETE /vms/N` | Stop and release slot |
| `GET /vms/N/console?since=C` | Read serial bytes after cursor C |
| `POST /vms/N/console` | Raw serial input; 409 if stopped or 255-byte queue is full |
| `POST /vms/N/permissions` | Replace grants with raw rule text; empty revokes |

Console responses carry `X-Run-Cursor`. Omit `since` to read the retained tail;
expired cursors get 410. Logs survive stop but reset on restart or deletion.

```sh
curl --data-urlencode kernel=/images/bzImage \
  --data-urlencode disk=/images/root.img \
  --data-urlencode 'cmdline=root=/dev/vda rw' \
  -d 'cpus=2&mem=256' http://127.0.0.1:8080/vms
curl -X POST http://127.0.0.1:8080/vms/0/start
```

## Disk semantics

Raw bases are mapped `MAP_PRIVATE`: guest writes never modify the base. A bitmap
tracks cumulative changed 4 KiB pages. Checkpoints are exclusively created and
synced as `vmN.disk.GENERATION.snap` in the working directory. Quiesce/unmount
guest filesystems first; pausing device access does not flush guest buffers.
Restart with the **same unchanged base** and `--overlay checkpoint.snap`.
Never modify a mapped base in place. This is a disk delta, not a CPU/RAM/device
snapshot, incremental chain, portable image format or live migration. Deleting
a VM does not delete its checkpoint files; callers manage their lifetime.

## Architecture and trust

The loader validates and places bzImage/initrd, constructs boot parameters,
E820, identity maps and ACPI, then enters Linux's 64-bit entry point. MADT
describes CPUs and IOAPIC; DSDT describes device memory/IRQ resources. KVM
supplies execution, irqchip and PIT. One thread per vCPU handles exits; a VM
lock serializes device state. The host loop handles API and TAP receive traffic.

Devices: serial at 0x3f8/IRQ4, block at 0xd0000000/IRQ5, optional network at
0xd0001000/IRQ6. Virtqueues validate addresses, lengths, chaining, descriptor
directions and negotiated features. No PCI, GPU, USB, firmware boot, NIC
offloads, multiqueue, ballooning or hot-plug.

vCPU threads install a syscall allowlist, but VMs and the API share one process
and address space. This is **not** a security-reviewed hostile multi-tenant
boundary. There is no per-VM UID, cgroup policy, whole-process jail, scheduler,
distributed storage or high availability. A public cloud needs those layers
and a wider security review; a small binary does not make them unnecessary.

## Evidence

[Recorded validation](docs/validation.md) includes actual serial output and
kernel/binary hashes. `tests/kvm.py` requires root and real KVM on an expendable
x86-64 Linux test host; it temporarily creates a namespace, veth pair and routing
rules. It checks SMP userspace, private writes, shell output/nonzero exit status,
routed HTTP, live revocation, checkpoint restore and API cleanup. CI publishes
serial logs and JSON results. Unit tests additionally cover malformed boot
images, virtqueues, disk deltas, HTTP, topology, policy bypass attempts and UART.

One kernel and this suite are not a security audit or compatibility matrix.
Boot time is a fixture observation, not a controlled benchmark. No smallest,
fastest or record-breaking claim is made without comparative evidence.
