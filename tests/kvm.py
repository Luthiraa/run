"""Real KVM integration: distro kernel -> SMP userspace -> private disk write.
Run as root on an x86-64 Linux test host with busybox-static, cpio and a kernel.
"""
import hashlib
import json
import pathlib
import os
import stat
import shutil
import subprocess as sp
import tempfile
import time
import urllib.request

REPO = pathlib.Path(__file__).resolve().parents[1]
EVIDENCE = REPO / "evidence"


def command(*args, **kwargs):
    return sp.run(args, check=True, **kwargs)


def request(path, method="GET", data=None):
    req = urllib.request.Request("http://127.0.0.1:18080" + path, data=data, method=method)
    with urllib.request.urlopen(req, timeout=3) as response:
        return response.read()


def main():
    assert pathlib.Path("/dev/kvm").exists(), "real KVM is required; emulation is not proof"
    EVIDENCE.mkdir(exist_ok=True)
    kernel = sorted(pathlib.Path("/boot").glob("vmlinuz-*"))[-1]
    version = kernel.name.removeprefix("vmlinuz-")
    with tempfile.TemporaryDirectory(prefix="run-kvm-") as tmp:
        work = pathlib.Path(tmp)
        root = work / "root"
        for name in ("bin", "proc", "sys", "dev", "disk", "lib/modules/" + version):
            (root / name).mkdir(parents=True, exist_ok=True)
        shutil.copy2("/bin/busybox", root / "bin/busybox")
        (root / "bin/sh").symlink_to("busybox")
        os.mknod(root / "dev/console", stat.S_IFCHR | 0o600, os.makedev(5, 1))
        os.mknod(root / "dev/null", stat.S_IFCHR | 0o666, os.makedev(1, 3))
        for module in ("virtio_mmio", "virtio_blk", "virtio_net", "ext4"):
            deps = sp.check_output(["modprobe", "-S", version, "--show-depends", module], text=True)
            for line in deps.splitlines():
                if not line.startswith("insmod "):
                    continue
                source = pathlib.Path(line.split()[1])
                dest = root / "lib/modules" / version / source.name
                if source.suffix in (".zst", ".xz", ".gz"):
                    with dest.with_suffix("").open("wb") as out:
                        command({".zst": "zstd", ".xz": "xz", ".gz": "gzip"}[source.suffix], "-dc", str(source), stdout=out)
                else:
                    shutil.copy2(source, dest)
        for name in ("modules.builtin", "modules.builtin.modinfo", "modules.order"):
            source = pathlib.Path("/lib/modules") / version / name
            if source.exists():
                shutil.copy2(source, root / "lib/modules" / version / name)
        command("depmod", "-b", str(root), version)
        (root / "init").write_text('''#!/bin/sh
export PATH=/bin
/bin/busybox --install -s /bin
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
exec </dev/console >/dev/console 2>&1
set -ex
modprobe virtio_mmio
modprobe virtio_blk
modprobe virtio_net
modprobe ext4
mount /dev/vda /disk
echo run-private-write >/disk/proof
sync
test "$(cat /sys/devices/system/cpu/online)" = 0-1
echo RUN_USERSPACE_SMP_DISK_OK
while true; do sleep 3600; done
''')
        (root / "init").chmod(0o755)
        initrd = work / "initrd"
        with initrd.open("wb") as out:
            entries = "\n".join(str(p.relative_to(root)) for p in root.rglob("*")) + "\n"
            command("cpio", "-o", "-H", "newc", cwd=root, input=entries.encode(), stdout=out)
        disk = work / "disk.img"
        with disk.open("wb") as out:
            out.truncate(64 << 20)
        command("mkfs.ext4", "-q", "-F", str(disk))
        before = hashlib.sha256(disk.read_bytes()).hexdigest()
        serial = EVIDENCE / "serial.log"
        with serial.open("wb") as out:
            vm = sp.Popen([str(REPO / "zig-out/bin/run"), "--no-net", "--api", "18080", "--mem", "256", "--cpus", "2", "--disk", str(disk), "--initrd", str(initrd), str(kernel)], cwd=work, stdout=out, stderr=sp.STDOUT)
            try:
                for _ in range(600):
                    text = serial.read_text(errors="replace")
                    if "RUN_USERSPACE_SMP_DISK_OK" in text:
                        break
                    assert vm.poll() is None, text
                    time.sleep(0.1)
                else:
                    raise AssertionError(serial.read_text(errors="replace"))
                request("/vms/0/snap", "POST")
                assert list(work.glob("*.snap")), "checkpoint missing"
                assert hashlib.sha256(disk.read_bytes()).hexdigest() == before
                request("/vms/0/stop", "POST")
                assert json.loads(request("/vms/0"))["state"] == "off"
                (EVIDENCE / "result.json").write_text(json.dumps({"kernel": version, "kernel_sha256": hashlib.sha256(kernel.read_bytes()).hexdigest(), "binary_bytes": (REPO / "zig-out/bin/run").stat().st_size, "smp": 2, "private_disk": True, "checkpoint": True}, indent=2) + "\n")
            finally:
                vm.terminate()
                try:
                    vm.wait(timeout=5)
                except sp.TimeoutExpired:
                    vm.kill()
                    vm.wait()


if __name__ == "__main__":
    main()
