{
  self,
}:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    boolToString
    getExe
    isBool
    literalExpression
    mapAttrs
    mkEnableOption
    mkIf
    mkOption
    optional
    optionalAttrs
    optionalString
    types
    ;

  cfg = config.services.tclip;

  defaultPackage = self.packages.${pkgs.stdenv.hostPlatform.system}.tclipd;

  flagEnvironment = {
    DATA_DIR = cfg.dataDir;
    TSNET_HOSTNAME = cfg.hostname;
  }
  // optionalAttrs cfg.tsnetVerbose {
    TSNET_VERBOSE = "1";
  }
  // optionalAttrs cfg.useFunnel {
    USE_FUNNEL = "1";
  }
  // optionalAttrs cfg.hideFunnelUsers {
    HIDE_FUNNEL_USERS = "1";
  }
  // optionalAttrs (cfg.httpPort != null) {
    HTTP_PORT = toString cfg.httpPort;
  }
  // optionalAttrs (cfg.controlUrl != null) {
    TSNET_CONTROL_URL = cfg.controlUrl;
  }
  // optionalAttrs cfg.disableHttps {
    DISABLE_HTTPS = "1";
  }
  // optionalAttrs cfg.enableLineNumbers {
    ENABLE_LINE_NUMBERS = "1";
  }
  // optionalAttrs cfg.enableWordWrap {
    ENABLE_WORD_WRAP = "1";
  };

  renderedEnvironment = mapAttrs (
    _: value: if isBool value then boolToString value else toString value
  ) (flagEnvironment // cfg.environment);

  startScript = pkgs.writeShellScript "tclipd-start" ''
    set -eu
    ${optionalString (cfg.authKeyFile != null) ''
      export TS_AUTHKEY="$(cat "$CREDENTIALS_DIRECTORY/ts-authkey")"
    ''}
    exec ${getExe cfg.package}
  '';
in
{
  options.services.tclip = {
    enable = mkEnableOption "tclip pastebin service";

    package = mkOption {
      type = types.package;
      default = defaultPackage;
      defaultText = literalExpression "self.packages.\${pkgs.stdenv.hostPlatform.system}.tclipd";
      description = "The tclipd package to run.";
    };

    user = mkOption {
      type = types.str;
      default = "tclip";
      description = "User account under which tclip runs.";
    };

    group = mkOption {
      type = types.str;
      default = "tclip";
      description = "Group under which tclip runs.";
    };

    hostname = mkOption {
      type = types.str;
      default = "paste";
      description = "Hostname to use for the tsnet node on your tailnet.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/tclip";
      description = "Directory where tclip stores SQLite data and tsnet state.";
    };

    authKeyFile = mkOption {
      type = with types; nullOr path;
      default = null;
      example = "/run/secrets/tclip-authkey";
      description = ''
        File containing a Tailscale auth key. The file is passed to tclip as
        {env}`TS_AUTHKEY` without copying the secret into the Nix store.
      '';
    };

    environmentFile = mkOption {
      type = with types; nullOr path;
      default = null;
      example = "/run/secrets/tclip.env";
      description = ''
        Additional environment file as defined in {manpage}`systemd.exec(5)`.
        This can be used for secrets or for tclip environment variables not
        covered by first-class module options.
      '';
    };

    environment = mkOption {
      type =
        with types;
        attrsOf (oneOf [
          bool
          int
          str
        ]);
      default = { };
      example = {
        TSNET_HOSTNAME = "paste";
      };
      description = ''
        Extra environment variables for tclip. Prefer the first-class options
        in this module for tclip's boolean settings because tclip treats the
        mere presence of those variables as true.
      '';
    };

    tsnetVerbose = mkOption {
      type = types.bool;
      default = false;
      description = "Enable verbose tsnet logging.";
    };

    useFunnel = mkOption {
      type = types.bool;
      default = false;
      description = "Expose individual pastes to the public internet with Tailscale Funnel.";
    };

    hideFunnelUsers = mkOption {
      type = types.bool;
      default = false;
      description = "Hide the creating user's name and profile picture on funneled pastes.";
    };

    httpPort = mkOption {
      type = with types; nullOr port;
      default = null;
      example = 8080;
      description = "Optional plain HTTP port for serving public paste endpoints, usually behind a reverse proxy.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the configured HTTP port in the firewall.";
    };

    controlUrl = mkOption {
      type = with types; nullOr str;
      default = null;
      example = "https://headscale.example.com";
      description = "Optional custom Tailscale control server URL, for example for Headscale.";
    };

    disableHttps = mkOption {
      type = types.bool;
      default = false;
      description = "Disable HTTPS serving via Tailscale Serve. Useful for Headscale deployments.";
    };

    enableLineNumbers = mkOption {
      type = types.bool;
      default = false;
      description = "Show line numbers when viewing pastes.";
    };

    enableWordWrap = mkOption {
      type = types.bool;
      default = false;
      description = "Allow paste lines to wrap.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.openFirewall -> cfg.httpPort != null;
        message = "services.tclip.openFirewall requires services.tclip.httpPort to be set.";
      }
    ];

    users.users = optionalAttrs (cfg.user == "tclip") {
      tclip = {
        inherit (cfg) group;
        isSystemUser = true;
        home = cfg.dataDir;
      };
    };

    users.groups = optionalAttrs (cfg.group == "tclip") {
      tclip = { };
    };

    systemd.tmpfiles.settings."10-tclip"."${cfg.dataDir}".d = {
      inherit (cfg) user group;
      mode = "0700";
    };

    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [
      cfg.httpPort
    ];

    systemd.services.tclip = {
      description = "tclip pastebin service";
      documentation = [ "https://github.com/tailscale-dev/tclip" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];

      environment = renderedEnvironment;

      serviceConfig = {
        EnvironmentFile = optional (cfg.environmentFile != null) cfg.environmentFile;
        LoadCredential = optional (cfg.authKeyFile != null) "ts-authkey:${cfg.authKeyFile}";
        ExecStart = startScript;
        Restart = "always";
        RestartSec = "30s";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        StateDirectory = optional (cfg.dataDir == "/var/lib/tclip") "tclip";
        StateDirectoryMode = "0700";
        ReadWritePaths = [ cfg.dataDir ];
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        NoNewPrivileges = true;

        # Hardening
        DevicePolicy = "closed";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHome = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        ProtectProc = "invisible";
        ProtectSystem = "strict";
        RemoveIPC = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_NETLINK"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = [ "native" ];
        SystemCallFilter = [ "@system-service" ];
      };
    };
  };
}
