# Hardware-backed validation

Passed [GitHub Actions run 34007715380](https://github.com/Luthiraa/run/actions/runs/34007715380)
on an x86-64 Ubuntu runner with real `/dev/kvm`, not CPU emulation.
Tested commit: `e3d393fc9bf2fc7fc9b79f0e7ef10ed58b933f5e`.

The static Linux executable was **39,584 bytes**. Source at that commit was
1,713 lines including nine unit tests. The macOS-hosted cross-build measured
39,592 bytes; size is toolchain/host-output specific, not an invariant.
Neither figure includes Linux, the guest filesystem or optional host helpers.

The unmodified Ubuntu `6.8.0-139-generic` kernel reached the fixture's userspace
marker with two online CPUs and a mounted ext4 virtio disk. Observed wall time
was 1.008 seconds, including launch and 100 ms polling granularity; this is not
a controlled boot-speed benchmark.

The same test then verified:

- Serial agent execution returned `from_agent` and exit status 7.
- Guest HTTP reached a server across TAP, host routing and a network namespace.
- Replacing grants with an empty policy made a subsequent HTTP request fail.
- Private writes left the base image's SHA-256 unchanged.
- A disk checkpoint restored `agent-persist` after deletion and a fresh VM boot.
- Stop retained console output; deleting the final VM left the API list empty.

[Serial transcript](serial.log) contains both boots and command output (carriage
returns normalized for repository readability). [Machine-readable results](result.json)
record kernel and binary SHA-256, tested commit and assertion results. CI retains
the original raw transcript as an artifact. Reproduce using `.github/workflows/kvm.yml`
or run `sudo python3 tests/kvm.py` on an expendable, prepared Linux/KVM host.

This proves these operations on this fixture—not arbitrary kernel compatibility,
production hardening, throughput superiority or a size world record.
