


<img width="150" alt="run-logo-cropped" src="https://github.com/user-attachments/assets/9f0795a9-748b-4491-85b4-a8b22ba3b51e" />


# run

Linux. In a process.

One static binary. KVM. virtio. private disks. explicit egress.

No libc. No daemons. No cluster. Just the machine.

```sh
zig build
./zig-out/bin/run --disk root.img --cmdline 'root=/dev/vda rw' bzImage
```

Zig 0.16 · x86-64 Linux · `/dev/kvm`

> Tiny enough to read. Real enough to boot an unmodified Ubuntu kernel.

## Start

```
run [options] [kernel]

  --disk PATH      virtio-blk image (never written)
  --initrd PATH
  --overlay PATH   restore a disk checkpoint
  --cpus N         default 2
  --mem MB         default 512
  --cmdline STR
  --api PORT       127.0.0.1, default 8080
  --no-net
  --allow RULES    tcp|udp|icmp:ip/prefix:port
```

No kernel? You get the API.

## Network is a permission

Off by default. The guest gets only what you name.

```sh
sudo ./zig-out/bin/run --allow 'tcp:1.2.3.4:443' --disk root.img bzImage
sudo sh tools/egress.sh up 0 eth0
```

`runN` → `10.0.N.2` → `10.0.N.1`.

Everything else drops. Every packet is checked. Empty permissions revoke egress.

## Disks are private

The base image is mapped `MAP_PRIVATE`. Guest writes never touch it.

```sh
curl -X POST http://127.0.0.1:8080/vms/0/snap
./zig-out/bin/run --disk root.img --overlay vm0.disk.1.snap bzImage
```

Same base. Disk delta. Not a live snapshot.

## Commands, not agents

Give the guest a shell on `ttyS0`.

```sh
python3 tools/agent.py --vm 0 'uname -a'
```

Get `stdout` and `exit_code`. No guest daemon required.

## Local API

Localhost only. No auth. Don't proxy it.

```
POST   /vms
GET    /vms
GET    /vms/N
POST   /vms/N/start
POST   /vms/N/stop
POST   /vms/N/snap
DELETE /vms/N
GET    /vms/N/console
POST   /vms/N/console
POST   /vms/N/permissions    replace grants; empty revokes
```

```sh
curl --data-urlencode kernel=/images/bzImage \
     --data-urlencode disk=/images/root.img \
     --data-urlencode 'cmdline=root=/dev/vda rw' \
     -d 'cpus=2&mem=256' http://127.0.0.1:8080/vms
curl -X POST http://127.0.0.1:8080/vms/0/start
```

## Proof, not posture

[Real KVM CI](https://github.com/Luthiraa/run/actions/workflows/kvm.yml) boots
an unmodified Ubuntu kernel into two-CPU userspace, runs commands, routes and
revokes network access, writes a private disk, and restores a checkpoint.

Read [the system guide](SYSTEM.md). Read [the validation record](docs/validation.md).

`run` is a tiny VMM. It is not a public cloud, a container runtime, or a
hostile multi-tenant boundary.
