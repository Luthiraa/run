


<img width="150" alt="run-logo-cropped" src="https://github.com/user-attachments/assets/9f0795a9-748b-4491-85b4-a8b22ba3b51e" />


# run

Linux in a process.

One static binary. KVM, virtio, copy-on-write disks, explicit network
grants. No libc. No daemons. No cluster.

```sh
zig build
./zig-out/bin/run --disk root.img --cmdline 'root=/dev/vda rw' bzImage
```

Zig 0.16. x86-64 Linux. `/dev/kvm`.

## Usage

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

No kernel argument: just the API.

## Network

Off. You grant destinations.

```sh
sudo ./zig-out/bin/run --allow 'tcp:1.2.3.4:443' --disk root.img bzImage
sudo sh tools/egress.sh up 0 eth0
```

VM `N` → TAP `runN`, guest `10.0.N.2`, gateway `10.0.N.1`.
Everything else is dropped.

## Disks

The base is mapped private. Guest writes never touch it.

```sh
curl -X POST http://127.0.0.1:8080/vms/0/snap
./zig-out/bin/run --disk root.img --overlay vm0.disk.1.snap bzImage
```

Same base. Disk delta. Not a live snapshot.

## Commands

Guest needs a shell on `ttyS0`.

```sh
python3 tools/agent.py --vm 0 'uname -a'
```

Returns `stdout` and `exit_code`.

## API

Localhost. No auth. Don't proxy it.

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
