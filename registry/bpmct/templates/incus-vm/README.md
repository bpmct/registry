---
display_name: Incus VM
description: Develop inside a full QEMU/KVM virtual machine managed by Incus
icon: ../../../../.icons/lxc.svg
verified: false
tags: [local, incus, vm, qemu, kvm, raspberry-pi]
---

# Incus VM

Provision a full QEMU/KVM virtual machine via [Incus](https://linuxcontainers.org/incus/) on your local infrastructure. Unlike the Incus container template, this creates a proper VM with its own kernel — ideal for KVM-capable hosts such as the Raspberry Pi 5.

## Prerequisites

1. Install [Incus](https://linuxcontainers.org/incus/) on the same machine as Coder.
   - On Debian/Raspberry Pi OS, use the [Zabbly repo](https://github.com/zabbly/incus):
     ```bash
     curl -fsSL https://pkgs.zabbly.com/key.asc | sudo gpg --dearmor -o /etc/apt/keyrings/zabbly.gpg
     echo "deb [signed-by=/etc/apt/keyrings/zabbly.gpg] https://pkgs.zabbly.com/incus/stable $(. /etc/os-release && echo $VERSION_CODENAME) main" \
       | sudo tee /etc/apt/sources.list.d/zabbly-incus-stable.list
     sudo apt update && sudo apt install incus
     ```

2. Initialize Incus:
   ```bash
   sudo incus admin init --minimal
   ```

3. Create a storage pool named `coder`:
   ```bash
   incus storage create coder btrfs
   ```
   > `dir` also works if btrfs is unavailable — just slower.

4. Allow Coder to access the Incus socket:
   - Running Coder as a system service: `sudo usermod -aG incus-admin coder` then restart Coder.
   - Running Coder directly as your user: `sudo usermod -aG incus-admin $USER` then log out and back in.

5. Verify KVM is available (required for full hardware acceleration):
   ```bash
   ls /dev/kvm
   ```
   > KVM is available on Raspberry Pi 5 out of the box with a 6.x kernel. Without KVM, QEMU falls back to software emulation.

## Usage

1. Run `coder templates init -id incus-vm`
2. Follow the on-screen instructions

## Notes

- VM images are sourced from the `images:` remote (e.g. `images:ubuntu/24.04`). The `ubuntu:` remote does **not** have ARM64 images.
- Disk size is immutable after workspace creation.
- On workspace **stop**, the VM is powered off but the disk is preserved.
- On workspace **delete**, the VM and all its data are permanently removed.

## Extending this template

See the [lxc/incus](https://registry.terraform.io/providers/lxc/incus/latest/docs) Terraform provider documentation to add:

- Bridged networking
- Additional disk devices
- GPU passthrough
- Snapshot policies
