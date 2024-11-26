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
        default = self.packages.${system}.my-microvm;
        my-microvm = self.nixosConfigurations.my-microvm.config.microvm.declaredRunner;
      };

      nixosConfigurations = {
        my-microvm = nixpkgs.lib.nixosSystem {
          inherit system;

          modules = [
            # for declarative MicroVM management
            microvm.nixosModules.host
            # this runs as a MicroVM that nests MicroVMs
            microvm.nixosModules.microvm

            ({ config, lib, pkgs, ... }:
              let
                inherit (microvm.lib) hypervisors;

                k3sSecret = "AAAAAAAAAAAAAAAAAA";

                hypervisorMacAddrs = builtins.listToAttrs (
                  map (hypervisor:
                    let
                      hash = builtins.hashString "sha256" hypervisor;
                      c = off: builtins.substring off 2 hash;
                      mac = "${builtins.substring 0 1 hash}2:${c 2}:${c 4}:${c 6}:${c 8}:${c 10}";
                    in {
                      name = hypervisor;
                      value = mac;
                    }) hypervisors
                );

                hypervisorIPv4Addrs = builtins.listToAttrs (
                  lib.imap0 (i: hypervisor: {
                    name = hypervisor;
                    value = "10.0.0.${toString (2 + i)}";
                  }) hypervisors
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

                # Make alioth available
                nixpkgs.overlays = [ microvm.overlay ];

                # MicroVM settings
                microvm = {
                  mem = 8192;
                  vcpu = 4;
                  # Use QEMU because nested virtualization and user networking
                  # are required.
                  hypervisor = "qemu";
                  interfaces = [ {
                    type = "user";
                    id = "qemu";
                    mac = "02:00:00:01:01:01";
                  } ];
                };

                # Nested MicroVMs (a *host* option)
                microvm.vms = builtins.mapAttrs (hypervisor: mac: {
                  config = {
                    system.stateVersion = config.system.nixos.version;
                    networking.hostName = "${hypervisor}-microvm";

                    microvm = {
                      mem = 1024;
                      inherit hypervisor;
                      interfaces = [ {
                        type = "tap";
                        id = "vm-${builtins.substring 0 12 hypervisor}";
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
                      role = "agent"; # Or "agent" for worker only nodes
                      token = "${k3sSecret}";
                      serverAddr = "https://10.0.0.1:6443";
                    };
                    networking.firewall.allowedTCPPorts = [
                      6443
                    ];
                  };
                }) hypervisorMacAddrs;

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
                    dhcpServerStaticLeases = lib.imap0 (i: hypervisor: {
                      MACAddress = hypervisorMacAddrs.${hypervisor};
                      Address = hypervisorIPv4Addrs.${hypervisor};
                    }) hypervisors;
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
                networking.firewall.allowedUDPPorts = [ 67 6443 ];
                # Allow Internet access
                networking.nat = {
                  enable = true;
                  enableIPv6 = true;
                  internalInterfaces = [ "virbr0" ];
                };

                services.k3s = {
                  enable = true;
                  role = "server";
                  token = "${k3sSecret}";
                  clusterInit = true;
                };

                networking.extraHosts = lib.concatMapStrings (hypervisor: ''
                  ${hypervisorIPv4Addrs.${hypervisor}} ${hypervisor}
                '') hypervisors;
              })
          ];
        };
      };
    };
}
