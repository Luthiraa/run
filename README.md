<img width="150" alt="run-logo-cropped" src="https://github.com/user-attachments/assets/9f0795a9-748b-4491-85b4-a8b22ba3b51e" />

# run

`run` is a small KVM VMM for starting real Linux machines directly from a
kernel, initrd, and raw disk image. It is one static Zig binary with direct
64-bit Linux boot, SMP, virtio block and networking, copy-on-write disks,
explicit network permissions, and serial control for automated work.

```sh
zig build
./zig-out/bin/run --disk root.img --cmdline 'root=/dev/vda rw' bzImage
```

It runs on x86-64 Linux with Zig 0.16 and `/dev/kvm`.

## Running a machine

```text
run [options] [kernel]

  --disk PATH      virtio-blk image; guest writes stay private
  --initrd PATH
  --overlay PATH   restore a disk checkpoint
  --cpus N         default: 2
  --mem MB         default: 512
  --cmdline STR
  --api PORT       binds 127.0.0.1; default: 8080
  --no-net
  --allow RULES    tcp|udp|icmp:ip/prefix:port
```

Starting `run` without a kernel starts only the local API, so machines can be
created and controlled programmatically.

## Network permissions

Networking is opt-in. A machine receives a TAP interface only when you request
it, and outbound traffic is checked against the destinations you grant.

```sh
sudo ./zig-out/bin/run --allow 'tcp:1.2.3.4:443' --disk root.img bzImage
sudo sh tools/egress.sh up 0 eth0
```

VM `N` uses TAP `runN`, with guest address `10.0.N.2` and gateway `10.0.N.1`.
The guest can only send ARP to its gateway and IP traffic matching its rules.
Replacing permissions with an empty value revokes further egress immediately.

```sh
curl -X POST --data-binary '' http://127.0.0.1:8080/vms/0/permissions
```

## Private disks and checkpoints

The base image is mapped with `MAP_PRIVATE`, so guest writes never modify it.
You can save the changed pages as a disk checkpoint and start another machine
from the same base and checkpoint.

```sh
curl -X POST http://127.0.0.1:8080/vms/0/snap
./zig-out/bin/run --disk root.img --overlay vm0.disk.1.snap bzImage
```

Checkpoints are disk deltas. They are not live CPU or memory snapshots.

## Using it with agents

If the guest has a shell on `ttyS0`, the included client can send commands over
the serial console and return their output and exit status.

```sh
python3 tools/agent.py --vm 0 'uname -a'
```

The client is intentionally simple: it needs no guest daemon and works well for
one owner running a sequence of jobs on a disposable machine.

## Local API

The API listens on localhost and is intended for trusted local control.

```text
POST   /vms
GET    /vms
GET    /vms/N
POST   /vms/N/start
POST   /vms/N/stop
POST   /vms/N/snap
DELETE /vms/N
GET    /vms/N/console
POST   /vms/N/console
POST   /vms/N/permissions
```

```sh
curl --data-urlencode kernel=/images/bzImage \
     --data-urlencode disk=/images/root.img \
     --data-urlencode 'cmdline=root=/dev/vda rw' \
     -d 'cpus=2&mem=256' http://127.0.0.1:8080/vms
curl -X POST http://127.0.0.1:8080/vms/0/start
```

## Validation

[Real KVM CI](https://github.com/Luthiraa/run/actions/workflows/kvm.yml) boots
an unmodified Ubuntu kernel into two-CPU userspace, executes serial commands,
checks routed networking and permission revocation, writes to a private disk,
and restores a checkpoint.

The [system guide](SYSTEM.md) explains the device model, operating model, and
security boundaries. The [validation record](docs/validation.md) contains the
serial log and measured test results.
