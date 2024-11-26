{
  description = "NixOS in MicroVMs";

  nixConfig = {
    extra-substituters = [ "https://microvm.cachix.org" ];
    extra-trusted-public-keys = [ "microvm.cachix.org-1:oXnBc6hRE3eX5rSYdRyMYXnfzcCxC7yKPTbZXALsqys=" ];
  };

  inputs.microvm = {
    url = "github:astro/microvm.nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, microvm }:
    let
      system = "x86_64-linux";
    in {
      packages.${system} = {
        default = self.packages.${system}.nested-vm-setup;
        nested-vm-setup = self.nixosConfigurations.nested-vm-setup.config.microvm.declaredRunner;
      };

      nixosConfigurations = {
        nested-vm-setup = nixpkgs.lib.nixosSystem {
          inherit system;

          modules = [
            # for declarative MicroVM management
            microvm.nixosModules.host
            # this runs as a MicroVM that nests MicroVMs
            microvm.nixosModules.microvm

            ({ config, lib, pkgs, ... }:
              let
                hostnames = [ "worker-1" "worker-2" "worker-3" ];
                k3sSecret = "AAAAAAAAAAAAAAAAAA";

                hostnameMacAddrs = builtins.listToAttrs (
                  map (hostname:
                    let
                      hash = builtins.hashString "sha256" hostname;
                      c = off: builtins.substring off 2 hash;
                      mac = "${builtins.substring 0 1 hash}2:${c 2}:${c 4}:${c 6}:${c 8}:${c 10}";
                    in {
                      name = hostname;
                      value = mac;
                    }) hostnames
                );

                hostnameIPv4Addrs = builtins.listToAttrs (
                  lib.imap0 (i: hostname: {
                    name = hostname;
                    value = "10.0.0.${toString (2 + i)}";
                  }) hostnames
                );

              in {
                networking.hostName = "microvms-host";
                system.stateVersion = config.system.nixos.version;
                users.users.root.password = "";
                users.motd = ''
                  Once nested MicroVMs have booted you can look up DHCP leases:
                  networkctl status virbr0

                  They are configured to allow SSH login with root password:
                  toor
                '';
                services.getty.autologinUser = "root";

                services.k3s = {
                  enable = true;
                  role = "server";
                  token = "${k3sSecret}";
                  clusterInit = true;
                };

                # Make alioth available
                nixpkgs.overlays = [ microvm.overlay ];

                # MicroVM settings
                microvm = {
                  mem = 8192;
                  vcpu = 4;
                  hypervisor = "qemu";
                  interfaces = [ {
                    type = "user";
                    id = "qemu";
                    mac = "02:00:00:01:01:01";
                  } ];
                };

                # Nested MicroVMs (a *host* option)
                microvm.vms = builtins.mapAttrs (hostname: mac: {
                  config = {
                    system.stateVersion = config.system.nixos.version;
                    networking.hostName = "${hostname}-microvm";
                    networking.firewall.allowedTCPPorts = [ 6443 ];

                    microvm = {
                      mem = 2024;
                      hypervisor = "qemu";
                      interfaces = [ {
                        type = "tap";
                        id = "vm-${hostname}";
                        inherit mac;
                      } ];
                    };
                    # Just use 99-ethernet-default-dhcp.network
                    systemd.network.enable = true;

                    users.users.root.password = "toor";
                    services.openssh = {
                      enable = true;
                      settings.PermitRootLogin = "yes";
                    };
                    services.k3s = {
                      enable = true;
                      role = "agent";
                      token = "${k3sSecret}";
                      serverAddr = "https://10.0.0.1:6443";
                    };
                  };
                }) hostnameMacAddrs;

                systemd.network = {
                  enable = true;
                  netdevs.virbr0.netdevConfig = {
                    Kind = "bridge";
                    Name = "virbr0";
                  };
                  networks.virbr0 = {
                    matchConfig.Name = "virbr0";

                    addresses = [ {
                      Address = "10.0.0.1/24";
                    } {
                      Address = "fd12:3456:789a::1/64";
                    } ];
                    # Hand out IP addresses to MicroVMs.
                    # Use `networkctl status virbr0` to see leases.
                    networkConfig = {
                      DHCPServer = true;
                      IPv6SendRA = true;
                    };
                    # Let DHCP assign a statically known address to the VMs
                    dhcpServerStaticLeases = lib.imap0 (i: hostname: {
                      MACAddress = hostnameMacAddrs.${hostname};
                      Address = hostnameIPv4Addrs.${hostname};
                    }) hostnames;
                    # IPv6 SLAAC
                    ipv6Prefixes = [ {
                      Prefix = "fd12:3456:789a::/64";
                    } ];
                  };
                  networks.microvm-eth0 = {
                    matchConfig.Name = "vm-*";
                    networkConfig.Bridge = "virbr0";
                  };
                };
                # Allow DHCP server
                networking.firewall = {
                  allowedTCPPorts = [ 6443 ];
                  allowedUDPPorts = [ 67 ];
                };

                # Allow Internet access
                networking.nat = {
                  enable = true;
                  enableIPv6 = true;
                  internalInterfaces = [ "virbr0" ];
                };

                networking.extraHosts = lib.concatMapStrings (hostname: ''
                  ${hostnameIPv4Addrs.${hostname}} ${hostname}
                '') hostnames;
              })
          ];
        };
      };
    };
}
