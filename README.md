# K8s via k3s in nested microVMs

This project uses [microVMs](https://github.com/astro/microvm.nix) to setup a k8s cluster inside a microVM. The control plane is running in the host VM. Worker nodes are running in independend nested microVMs. [k3s](https://k3s.io/) is installed and configured via [nix](https://nixos.org).

# Setup

```bash
make run
```

After the image is build you will end up inside the host vm.
