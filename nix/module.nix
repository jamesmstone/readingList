{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.readinglist;
  inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) readinglist;

  env = {
    RL_REMOTE = cfg.remote;
    RL_STATE = cfg.stateDir;
    RL_SHOT_SCRAPER = lib.getExe cfg.shotScraper;
  }
  // lib.optionalAttrs (cfg.publishDB != null) { RL_PUBLISH_DB = cfg.publishDB; }
  // lib.optionalAttrs (cfg.publishSite != null) { RL_PUBLISH_SITE = cfg.publishSite; };

  # Shared by the server and the reconcile timer: both drive the same script
  # over the same checkout, and the push needs the user's own ssh key, which is
  # why neither sets ProtectHome.
  hardening = {
    User = cfg.user;
    # The box also runs the forge; an append is never the urgent thing on it.
    Nice = 19;
    IOSchedulingClass = "idle";
    NoNewPrivileges = true;
    PrivateTmp = true;
  };
in
{
  options.services.readinglist = {
    enable = lib.mkEnableOption "the reading list's append endpoint";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.append;
      defaultText = lib.literalExpression "readingList.packages.\${system}.append";
      description = "The append/republish script the units run.";
    };

    shotScraper = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.shot-scraper;
      defaultText = lib.literalExpression "readingList.packages.\${system}.shot-scraper";
      description = ''
        Screenshot tool, called as `<exe> URL -o out.png` and `<exe> pdf URL -o
        out.pdf`. An option so the VM test can substitute a stub: the real one
        pulls a browser into the closure and needs the network.
      '';
    };

    remote = lib.mkOption {
      type = lib.types.str;
      example = "ssh://forgejo@hermanii/james/readingList";
      description = "Git remote holding the archive; the units clone and push to it.";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "james";
      description = ''
        User to run as. Its ~/.ssh must be able to push to `remote`, and it
        needs write access to `publishDB` and `publishSite`.
      '';
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/readinglist";
      description = "Holds the checkout of the archive and the database built from it.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "[::1]";
      example = "[::]";
      description = ''
        Address the endpoint binds. The default is loopback; reaching it from a
        phone over the tailnet needs this widened.
      '';
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8108;
      description = "Port the endpoint listens on.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Open `port`. The endpoint is unauthenticated, so this is only ever
        appropriate where the only route to it is the tailnet.
      '';
    };

    publishDB = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/datasette-sites/api-read/readingList.db";
      description = ''
        Where to install the rebuilt database, replaced by rename so a reader
        never sees a partial file. Null builds it in `stateDir` and stops there.
      '';
    };

    publishSite = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/var/lib/readinglist-site";
      description = ''
        Where to publish the page and the screenshots. The PDFs are never
        published: they are 2.2G against the screenshots' 102M and nothing
        links to them.
      '';
    };

    reconcileInterval = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "daily";
      description = ''
        systemd OnCalendar expression for a republish that appends nothing. It
        is what picks up a row committed from somewhere else, and what repairs
        a publish directory that was emptied. Null disables it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [ "d ${cfg.stateDir} 0750 ${cfg.user} - - -" ];

    systemd.services.readinglist = {
      description = "Reading list append endpoint";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = env // {
        RL_APPEND_CMD = lib.getExe cfg.package;
        RL_LISTEN = "${cfg.address}:${toString cfg.port}";
      };

      serviceConfig = hardening // {
        ExecStart = "${lib.getExe readinglist} serve";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    systemd.services.readinglist-publish = {
      description = "Rebuild and republish the reading list";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = env;

      serviceConfig = hardening // {
        Type = "oneshot";
        ExecStart = "${lib.getExe cfg.package} publish";
      };
    };

    systemd.timers.readinglist-publish = lib.mkIf (cfg.reconcileInterval != null) {
      description = "Republish the reading list on a schedule";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.reconcileInterval;
        # A box that was off at the scheduled minute should still catch up.
        Persistent = true;
        RandomizedDelaySec = "10m";
        Unit = "readinglist-publish.service";
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}
