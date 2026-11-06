# Opt-in NixOS module for the xsprof read-only recorder service.
# The service is disabled by default; enabling it creates an unprivileged
# account, grants only the capabilities the packaging/systemd unit documents,
# and applies systemd hardening. The module never applies advisor output and
# refuses unsafe/mutating CLI verbs in extraArgs.
self:
{ config, lib, pkgs, ... }:

let
  cfg = config.services.xsprof.recorder;
  system = pkgs.stdenv.hostPlatform.system;
  defaultPackage = self.packages.${system}.xsprof;
  unsafeVerbs = [
    "load"
    "attach"
    "enable"
    "mutate"
    "apply"
    "sched-ext-attach"
    "setaffinity"
    "setpriority"
    "bind"
  ];
  unsafeArgs = builtins.filter (arg: builtins.elem arg unsafeVerbs) cfg.extraArgs;
  extraArgs = lib.concatMapStrings (arg: " " + lib.escapeShellArg arg) cfg.extraArgs;
  stateDirectory = lib.removePrefix "/var/lib/" cfg.stateDir;
in
{
  options.services.xsprof.recorder = {
    enable = lib.mkEnableOption "the xsprof read-only recorder service";
    package = lib.mkOption {
      type = lib.types.package;
      default = defaultPackage;
      description = "xsprof package to run.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "xsprof";
      description = "Unprivileged user that owns the recorder state.";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "xsprof";
      description = "Group for the recorder user.";
    };
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/xsprof";
      description = "State directory below /var/lib for the recorder.";
    };
    retain = lib.mkOption {
      type = lib.types.str;
      default = "10m";
      description = "Raw journal retention window (passed to --retain).";
    };
    maxBytes = lib.mkOption {
      type = lib.types.str;
      default = "2G";
      description = "Maximum raw journal size (passed to --max-bytes).";
    };
    historyInterval = lib.mkOption {
      type = lib.types.str;
      default = "60s";
      description = "History sidecar interval (passed to --history-interval).";
    };
    historyRetain = lib.mkOption {
      type = lib.types.str;
      default = "24h";
      description = "History sidecar retention (passed to --history-retain).";
    };
    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra read-only daemon arguments; unsafe verbs are rejected.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = unsafeArgs == [ ];
        message = "services.xsprof.recorder.extraArgs contains unsafe/mutating verbs: ${lib.concatStringsSep ", " unsafeArgs}";
      }
      {
        assertion = lib.hasPrefix "/var/lib/" cfg.stateDir;
        message = "services.xsprof.recorder.stateDir must live under /var/lib so systemd StateDirectory can own it";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      description = "xsprof read-only recorder";
    };
    users.groups.${cfg.group} = { };

    systemd.services.xsprof-recorder = {
      description = "xsprof read-only scheduler recorder";
      after = [ "local-fs.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        StateDirectory = stateDirectory;
        ExecStart = lib.concatStrings [
          "${cfg.package}/bin/xsprof daemon --foreground"
          " --dir ${cfg.stateDir}"
          " --retain ${cfg.retain}"
          " --max-bytes ${cfg.maxBytes}"
          " --history-interval ${cfg.historyInterval}"
          " --history-retain ${cfg.historyRetain}"
          extraArgs
        ];
        AmbientCapabilities = [ "CAP_PERFMON" "CAP_DAC_READ_SEARCH" ];
        CapabilityBoundingSet = [ "CAP_PERFMON" "CAP_DAC_READ_SEARCH" ];
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadOnlyPaths = [ "-/sys/kernel/tracing" "-/sys/kernel/debug/tracing" ];
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
