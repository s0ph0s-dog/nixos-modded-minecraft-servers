{
  pkgs,
  lib,
  config,
  ...
}:
with lib; let
  cfg = config.services.modded-minecraft-servers;

  # Server config rendering
  serverPropertiesFile = serverConfig:
    pkgs.writeText "server.properties"
    (mkOptionText serverConfig);

  encodeOptionValue = value: let
    encodeBool = value:
      if value
      then "true"
      else "false";
    encodeString = value: escape [":" "=" "'"] value;
    typeMap = {
      "bool" = encodeBool;
      "string" = encodeString;
    };
  in
    (typeMap.${builtins.typeOf value} or toString) value;

  mkOptionLine = name: value: let
    dotNames = ["query-port" "rcon-password" "rcon-port"];
    fixName = name:
      if elem name dotNames
      then
        stringAsChars
        (x:
          if x == "-"
          then "."
          else x)
        name
      else name;
  in "${fixName name}=${encodeOptionValue value}";

  mkOptionText = serverConfig: let
    # Merge declared options with extraConfig
    c =
      (builtins.removeAttrs serverConfig ["extra-options"])
      // serverConfig.extra-options;
  in
    concatStringsSep "\n"
    (mapAttrsToList mkOptionLine c);

  # Configure rsync access
  mkRsyncdConf = name: parentDir:
    pkgs.writeText "rsyncd-minecraft.conf" ''
      log file = ${parentDir}/${mkInstanceName name}/rsync.log
      [${mkInstanceName name}]
      use chroot = false
      comment = Minecraft server state
      path = ${parentDir}/${mkInstanceName name}
      read only = false
    '';

  # Render EULA file
  eulaFile = builtins.toFile "eula.txt" ''
    # eula.txt managed by NixOS Configuration
    eula=true
  '';

  mkInstanceName = name: "mc-${name}";
  mkBackupInstanceName = name: (mkInstanceName name) + "-backup";
in {
  options = {
    services.modded-minecraft-servers = {
      eula = mkOption {
        type = with types; bool;
        default = false;
        description = ''
          Whether or not you accept the Minecraft EULA
        '';
      };

      instances = mkOption {
        type = with types; attrsOf (submodule (import ./minecraft-instance-options.nix pkgs));
        default = {};
        description = ''
          Define instances of Minecraft servers to run.
        '';
      };
    };
  };

  config = let
    enabledInstances = filterAttrs (_: x: x.enable) cfg.instances;
    enabledInstancesWBackups = filterAttrs (_: x: x.enable && x.backups.enable) cfg.instances;

    parentDir = cfg.parentDir;

    # Attrset options
    eachEnabledInstance = f: mapAttrs' (i: c: nameValuePair (mkInstanceName i) (f i c)) enabledInstances;
    eachEnabledInstanceWBackups = f: mapAttrs' (i: c: nameValuePair (mkBackupInstanceName i) (f i c)) enabledInstancesWBackups;

    serverPorts = mapAttrsToList (_: v: v.serverConfig.server-port) enabledInstances;
    rconPorts =
      mapAttrsToList
      (_: v: v.serverConfig.rcon-port)
      (filterAttrs (_: x: x.serverConfig.enable-rcon) enabledInstances);
    openRconPorts =
      mapAttrsToList
      (_: v: v.serverConfig.rcon-port)
      (filterAttrs (_: x: x.serverConfig.enable-rcon && x.openRcon) enabledInstances);
    queryPorts =
      mapAttrsToList
      (_: v: v.serverConfig.query-port)
      (filterAttrs (_: x: x.serverConfig.enable-query) enabledInstances);
  in {
    assertions = [
      {
        assertion = cfg.eula;
        message = "You must accept the Mojang EULA in order to run any servers.";
      }

      {
        assertion = (unique serverPorts) == serverPorts;
        message = "Your Minecraft instances have overlapping server ports. They must be unique.";
      }

      {
        assertion = (unique rconPorts) == rconPorts;
        message = "Your Minecraft instances have overlapping RCON ports. They must be unique.";
      }

      {
        assertion = (unique queryPorts) == queryPorts;
        message = "Your Minecraft instances have overlapping query ports. They must be unique.";
      }

      (
        let
          allPorts = serverPorts ++ rconPorts ++ queryPorts;
        in {
          assertion = (unique allPorts) == allPorts;
          message = "Your Minecraft instances have some overlapping ports among server, rcon and query ports. They must all be unique.";
        }
      )
    ];

    systemd.services =
      (eachEnabledInstance (name: icfg: {
        description = "Minecraft Server ${name}";
        wantedBy = ["multi-user.target"];
        after = ["network.target"];

        path = with pkgs; [icfg.jvmPackage bash];

        environment = {
          JVMOPTS = icfg.jvmOptString;
          MCRCON_PORT = toString icfg.serverConfig.rcon-port;
          MCRCON_PASS = "whatisloveohbabydonthurtmedonthurtmenomore";
        };

        serviceConfig = let
          fullname = mkInstanceName name;
          parentDir = icfg.parentDir;
        in {
          Restart = "always";
          ExecStart = "${parentDir}/${fullname}/start.sh";
          ExecStop = ''
            ${pkgs.mcrcon}/bin/mcrcon stop
          '';
          TimeoutStopSec = "20";
          User = fullname;
          StateDirectory = fullname;
          WorkingDirectory = "${parentDir}/${fullname}";
        };

        preStart = ''
          # Ensure EULA is accepted
          ln -sf ${eulaFile} eula.txt

          # Ensure server.properties is present
          if [[ -f server.properties ]]; then
            mv -f server.properties server.properties.orig
          fi

          # This file must be writeable, because Mojang.
          cp ${serverPropertiesFile icfg.serverConfig} server.properties
          chmod 644 server.properties
        '';
      }))
      // (eachEnabledInstanceWBackups (name: icfg: let
        fullName = mkInstanceName name;
        requisiteService = "${fullName}.service";
        backupFile = icfg.backups.archiveDir + "/backups.zpaq";
      in {
        path = [
          pkgs.zpaq
          pkgs.inotify-tools
          pkgs.mcrcon
          pkgs.bash
          pkgs.gawk
          pkgs.waitsilence
        ];
        script = ''
                 set -eu

                 export MCRCON_PORT=${toString icfg.serverConfig.rcon-port}
                 export MCRCON_PASS=${icfg.serverConfig.rcon-password}
          # Never leave saving off.
          trap 'mcrcon save-on; trap - EXIT; exit' EXIT INT HUP

                 mcrcon "say Beginning world backup (contact s0ph0s if it hasn't finished after ~30 seconds)" save-all save-off

                 CMD='inotifywait -m -r server/world --exclude "^./dynmap.*" | grep -v ACCESS'

                 # Ensure minecraft has finished writing its files out:
                 waitsilence -timeout 5s -command "$CMD"

                 zpaq -t1 add "${backupFile}" ~/world
                 BACKUP_SIZE="$(du -h "${backupFile}" | awk '{ print $1 }')"

                 mcrcon save-on "say World backup completed (cumulative size: $BACKUP_SIZE)."
          # Don't try to turn on saving again after we already turned it on.
          trap - EXIT
        '';
        requisite = [requisiteService];
        after = [requisiteService];
        serviceConfig = {
          Type = "oneshot";
          User = fullName;
          WorkingDirectory = "${icfg.parentDir}/${fullName}";
        };
      }));

    systemd.timers = eachEnabledInstanceWBackups (name: icfg: let
      backupUnitName = "${mkBackupInstanceName name}.service";
    in {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = icfg.backups.period;
        OnUnitActiveSec = icfg.backups.period;
        Unit = backupUnitName;
      };
    });

    users.users = eachEnabledInstance (name: icfg: let
      rsyncCmd = ''command="rsync --config=${mkRsyncdConf name icfg.parentDir} --server --daemon .",no-agent-forwarding,no-port-forwarding,no-user-rc,no-X11-forwarding,no-pty'';
    in {
      description = "Minecraft server service user for instance ${name}";
      isSystemUser = true;
      useDefaultShell = true;
      createHome = true;
      group = mkInstanceName name;
      home = "${icfg.parentDir}/${mkInstanceName name}";
      # openssh.authorizedKeys.keys =
      #   optionals (icfg.rsyncSSHKeys != [])
      #   map
      #   (x: rsyncCmd + " " + x)
      #   icfg.rsyncSSHKeys;
    });

    users.groups = eachEnabledInstance (_: _: {});

    networking.firewall.allowedUDPPorts = queryPorts;
    networking.firewall.allowedTCPPorts = serverPorts ++ queryPorts ++ openRconPorts;
  };
}
