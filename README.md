# Niri GPU hot-remove repro
[![repro](https://github.com/meatcar/niri-egpu-repro/actions/workflows/repro.yml/badge.svg)](https://github.com/meatcar/niri-egpu-repro/actions/workflows/repro.yml)

Failing NixOS test, showing Niri never cleans up the outputs of a hot-removed GPU.

The [`repro` workflow](https://github.com/meatcar/niri-egpu-repro/actions/workflows/repro.yml)
runs weekly against Niri main.

## Instructions

On x86_64 Linux with Nix and KVM, run

```sh
nix build github:meatcar/niri-egpu-repro#checks.x86_64-linux.repro -L
```

> Note: Patch in `./allow-software-egl.patch` is needed to run Niri on virtio GPUs.
The first run **compiles Niri from source**.

To verify a fix: add your patch to `./flake.nix` and re-run.

## What happens

The VM runs a Niri session on two virtio GPUs, then removes the second one
from inside the guest via sysfs (`echo 1 > /sys/bus/pci/devices/…/remove`).

The test asserts that:

1. `WARN niri::backend::tty: error creating DrmNode` is never logged
2. The removed GPU's outputs disappear from `niri msg outputs`.

