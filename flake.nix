{
  description = "Hermes Agent MicroVM Sandbox";

  inputs = {
    nixpkgs.url    = "github:NixOS/nixpkgs/nixos-unstable";
    microvm.url    = "github:astro/microvm.nix";
    microvm.inputs.nixpkgs.follows = "nixpkgs";
    hermes-agent.url = "github:NousResearch/hermes-agent";
    hermes-agent.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, microvm, hermes-agent }:
  let
    hostUser      = "michiel";
    hostWorkspace = "/home/${hostUser}/hermes-workspace";
  in {
    nixosConfigurations.hermes-vm = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        microvm.nixosModules.microvm
        hermes-agent.nixosModules.default

        ({ pkgs, lib, config, ... }:
        let
          # Hermes package — zelfde binary als de NixOS module gebruikt
          hermesPackage = config.services.hermes-agent.package;
        in {

          networking.hostName = "hermes-agent";
          # Subnet 10.0.2.x — nanoclaw=10.0.0.x, openclaw=10.0.1.x, hermes=10.0.2.x
          networking.interfaces.eth0.ipv4.addresses = [ {
            address = "10.0.2.2";
            prefixLength = 24;
          } ];
          networking.defaultGateway = { address = "10.0.2.1"; interface = "eth0"; };
          networking.useNetworkd   = false;
          networking.nameservers   = [ "1.1.1.1" "8.8.8.8" ];
          networking.hosts = {
            "10.0.2.1" = [ "www.logiesopdreef.nl" ];
          };
          system.stateVersion = "23.11";

          # ── Root toegang voor noodgevallen ──────────────────────
          users.users.root.password = "root";

          # ── MicroVM ────────────────────────────────────────────
          microvm = {
            hypervisor = "cloud-hypervisor";
            socket     = "control.sock";
            mem        = 8192;
            vcpu       = 4;
            vsock.cid  = 43;  # openclaw=42, hermes=43

            interfaces = [ {
              type = "tap";
              id   = "vmtap2";
              mac  = "02:00:00:00:00:03";
            } ];

            virtiofsd.group            = null;
            virtiofsd.inodeFileHandles = "never";
            virtiofsd.extraArgs        = [ "--sandbox=none" "--log-level=error" ];

            virtiofsd.package = pkgs.writeShellScriptBin "virtiofsd" ''
              args=()
              for arg in "$@"; do
                case "$arg" in
                  --posix-acl) ;;
                  *) args+=( "$arg" ) ;;
                esac
              done
              while true; do
                ${pkgs.virtiofsd}/bin/virtiofsd "''${args[@]}" >> /dev/null 2>&1
                sleep 1
              done
            '';

            volumes = [ {
              image      = "nix-store-rw.img";
              mountPoint = "/nix/.rw-store";
              size       = 8192;
            } ];

            shares = [
              { source = "/nix/store";                   mountPoint = "/nix/store";            tag = "ro-store";     proto = "virtiofs"; }
              { source = hostWorkspace;                  mountPoint = "/home/agent/workspace"; tag = "hermes-data";  proto = "virtiofs"; }
              { source = "${hostWorkspace}/.claude";     mountPoint = "/home/agent/.claude";   tag = "agent-claude"; proto = "virtiofs"; }
              { source = "${hostWorkspace}/.npm-global"; mountPoint = "/home/agent/.npm-global"; tag = "agent-npm";  proto = "virtiofs"; }
            ];
          };

          # ── Packages ───────────────────────────────────────────
          environment.systemPackages = with pkgs; [
            python311 nodejs_22
            curl git gh ffmpeg
            chromium
          ];

          virtualisation.docker.enable = true;

          networking.firewall.allowedTCPPorts = [ 3333 8644 ];

          networking.firewall.extraCommands = ''
            iptables -I INPUT -i docker0 -p tcp --dport 3001 -j ACCEPT
          '';

          # uid/gid = 1000 (zelfde als host michiel → virtiofs schrijfrechten)
          users.groups.agent.gid = 1000;
          users.users.agent = {
            isNormalUser = true;
            uid          = 1000;
            group        = "agent";
            extraGroups  = [ "wheel" "docker" ];
            password     = "agent";
          };

          security.sudo.wheelNeedsPassword = false;

          environment.sessionVariables.NPM_CONFIG_PREFIX = "/home/agent/workspace/.npm-global";
          programs.bash.interactiveShellInit = ''
            export PATH="/home/agent/.npm-global/bin:$PATH"
          '';

          systemd.tmpfiles.rules = [
            "L+ /home/agent/.claude.json - - - - /home/agent/.claude/claude.json"
            "L+ /home/agent/.hermes - - - - /home/agent/workspace/.hermes"
            "d /home/agent/workspace/dashboard 0755 agent agent -"
          ];

          # ── Hermes Agent (NixOS module) ─────────────────────────
          services.hermes-agent = {
            enable              = true;
            user                = "agent";
            group               = "agent";
            createUser          = false;
            stateDir            = "/home/agent/workspace/.hermes";
            workingDirectory    = "/home/agent/workspace";
            environmentFiles    = [ "/home/agent/workspace/.env" ];
            addToSystemPackages = true;
            settings = {
              model.default = "anthropic/claude-sonnet-4-6";
            };
          };

          # Pas start-volgorde aan: wacht op virtiofs mounts
          systemd.services.hermes-agent = {
            after    = lib.mkForce [ "network.target" "remote-fs.target" "local-fs.target" ];
            wantedBy = lib.mkForce [ "multi-user.target" ];
            serviceConfig.Restart    = lib.mkOverride 90 "on-failure";
            serviceConfig.RestartSec = lib.mkOverride 90 "10s";
          };

          # ── Hermes Gateway (system-level service) ───────────────
          # Draait als agent user via systemd system (geen user-session nodig).
          # Start na hermes-agent en virtiofs mounts.
          systemd.services.hermes-gateway = {
            description = "Hermes Agent Gateway - Messaging Platform Integration";
            after       = [ "network.target" "remote-fs.target" "hermes-agent.service" ];
            wantedBy    = [ "multi-user.target" ];
            startLimitIntervalSec = 600;
            startLimitBurst       = 5;
            environment = {
              HERMES_HOME  = "/home/agent/workspace/.hermes";
              VIRTUAL_ENV  = "${hermesPackage}";
            };
            serviceConfig = {
              Type             = "simple";
              User             = "agent";
              Group            = "agent";
              WorkingDirectory = "/home/agent/workspace";
              ExecStart        = "${hermesPackage}/bin/hermes gateway run --replace";
              Restart          = "on-failure";
              RestartSec       = "30s";
              KillMode         = "mixed";
              KillSignal       = "SIGTERM";
              TimeoutStopSec   = "60s";
              StandardOutput   = "journal";
              StandardError    = "journal";
              SyslogIdentifier = "hermes-gateway";
              EnvironmentFile  = "/home/agent/workspace/.env";
            };
          };

          # ── Mission Control dashboard (poort 3333) ─────────────
          systemd.services.hermes-dashboard = {
            description = "Hermes Mission Control Dashboard";
            after       = [ "network.target" "remote-fs.target" "hermes-agent.service" ];
            wantedBy    = [ "multi-user.target" ];
            path        = [ pkgs.bash pkgs.nodejs_22 pkgs.coreutils pkgs.python3 ];
            environment = {
              HERMES_STATE = "/home/agent/workspace/.hermes";
              NODE_ENV     = "production";
            };
            serviceConfig = {
              User             = "agent";
              WorkingDirectory = "/home/agent/workspace/dashboard";
              ExecStartPre     = [
                "${pkgs.nodejs_22}/bin/npm install"
                "${pkgs.nodejs_22}/bin/npm run build"
              ];
              ExecStart        = "${pkgs.nodejs_22}/bin/npm run start";
              Restart          = "on-failure";
              RestartSec       = "5s";
              StandardOutput   = "journal";
              StandardError    = "journal";
              SyslogIdentifier = "hermes-dashboard";
              EnvironmentFile  = "/home/agent/workspace/.env";
            };
          };

        })
      ];
    };

    packages.x86_64-linux.default =
      self.nixosConfigurations.hermes-vm.config.microvm.runner.cloud-hypervisor;
  };
}
