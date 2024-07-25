{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.python-services;

  mkOpt = type: default:
    mkOption { inherit type default; };

  mkOpt' = type: default: description:
    mkOption { inherit type default description; };

  mkBoolOpt = default: mkOption {
    inherit default;
    type = types.bool;
    example = true;
  };

  mkBoolOpt' = default: description: mkOption {
    inherit default description;
    type = types.bool;
    example = true;
  };

  normalizeFiles = files: mapAttrs configToPath (filterAttrs (_: nonEmptyValue) files);
  nonEmptyValue = x: nonEmpty x && (x ? value -> nonEmpty x.value);
  nonEmpty = x: x != { } && x != [ ];

  configToPath = name: config:
    if isStringLike config # Includes paths and packages
    then config
    else (getFormat name config).generate name config.value;
  getFormat = name: config:
    if config ? format && config.format != null
    then config.format
    else inferFormat name;
  inferFormat = name:
    let
      error = throw "nix-minecraft: Could not infer format from file '${name}'. Specify one using 'format'.";
      extension = builtins.match "[^.]*\\.(.+)" name;
    in
    if extension != null && extension != [ ]
    then formatExtensions.${head extension} or error
    else error;

  formatExtensions = with pkgs.formats; {
    "yml" = yaml { };
    "yaml" = yaml { };
    "json" = json { };
    "props" = keyValue { };
    "properties" = keyValue { };
    "toml" = toml { };
    "ini" = ini { };
  };

  configType = types.submodule {
    options = {
      format = mkOption {
        type = with types; nullOr attrs;
        default = null;
        description = ''
          The format to use when converting "value" into a file. If set to
          null (the default), we'll try to infer it from the file name.
        '';
        example = literalExpression "pkgs.formats.yaml { }";
      };
      value = mkOption {
        type = with types; either (attrsOf anything) (listOf anything);
        description = ''
          A value that can be converted into the specified format.
        '';
      };
    };
  };

  mkEnableOpt = description: mkBoolOpt' false description;
in
{
  options.services.python-services = {
    enable = mkEnableOpt ''
      If enabled, the services in <option>services.python-services.services</option>
      will be created and started as applicable.
      The data for the services will be loaded from and
      saved to <option>services.python-services.dataDir</option>
    '';

    dataDir = mkOpt' types.path "/srv/python" ''
      Directory to store the python services.
      Each service will be under a subdirectory named after
      the service name in this directory, such as <literal>/srv/python/servicename</literal>.
    '';

    runDir = mkOpt' types.path "/run/python" ''
      Directory to place the runtime tmux sockets into.
      Each service's console will be a tmux socket file in the form of <literal>servicename.sock</literal>.
      To connect to the console, run `tmux -S /run/python/servicename.sock attach`,
      press `Ctrl + b` then `d` to detach.
    '';

    user = mkOption {
      type = types.str;
      default = "python";
      description = ''
        Name of the user to create and run services under.
      '';
      internal = true;
      visible = false;
    };

    group = mkOption {
      type = types.str;
      default = "python";
      description = ''
        Name of the group to create and run services under.
        In order to modify the service files or attach to the tmux socket,
        your user must be a part of this group.
      '';
    };

    services = mkOption {
      default = { };
      description = ''
        services to create and manage using this module.
        Each service can be stopped with <literal>systemctl stop python-service-service</literal>.
        ::: {.warning}
        If the service is not stopped using `systemctl`, the service will automatically restart.
        See <option>services.python-services.services.<name>.restart</option>.
        :::
      '';
      type = types.attrsOf (types.submodule {
        options = {
          enable = mkEnableOpt ''
            Whether to enable this services.
            If set to <literal>false</literal>, does NOT delete any data in the data directory,
            just does not generate the service file.
          '';

          executable = mkOpt' types.str "code.py" ''
            File that should be executed by the service.
            Command is executed in the service directory, such as <literal>/srv/python/servicename/</literal>.
          '';

          autoStart = mkBoolOpt' true ''
            Whether to start this services on boot.
            If set to <literal>false</literal>, can still be started with
            <literal>systemctl start python-service-servicename</literal>.
            Requires the services to be enabled.
          '';

          restart = mkOpt' types.str "always" ''
            Value of systemd's <literal>Restart=</literal> service configuration option.
            Due to the services being started in tmux sockets, values other than
            <literal>"no"</literal> and <literal>"always"</literal> may not work properly.
          '';

          pythonOpts = mkOpt' (types.separatedString " ") "-node1" "Launch ptions for this service.";

          path = with types; mkOpt' (listOf (either path str)) [ ] ''
            Packages added to the python service's <literal>PATH</literal> environment variable.
            Works as <option>systemd.services.<name>.path</option>.
          '';

          environment = with types; mkOpt' (attrsOf (oneOf [ null str path package ])) { } ''
            Environment variables added to the python service's processes.
            Works as <option>systemd.services.<name>.environment</option>.
          '';

          symlinks = with types; mkOpt' (attrsOf (either path configType)) { } ''
            Things to symlink into this service's data directory, in the form of
            a nix package/derivation. Can be used to declaratively manage
            arbitrary files in the service's data directory.
          '';
          files = with types; mkOpt' (attrsOf (either path configType)) { } ''
            Things to copy into this service's data directory. Similar to
            symlinks, but these are actual files. Useful for configuration
            files that don't behave well when read-only.
          '';
        };
      });
    };
  };

  config = mkIf cfg.enable (
    let
      services = filterAttrs (_: cfg: cfg.enable) cfg.services;
    in
    {
      users = {
        users.python = mkIf (cfg.user == "python") {
          description = "Python service user";
          home = cfg.dataDir;
          createHome = true;
          homeMode = "770";
          isSystemUser = true;
          group = "python";
        };
        groups.python = mkIf (cfg.group == "python") { };
      };

      systemd.tmpfiles.rules = mapAttrsToList
        (name: _:
          "d '${cfg.dataDir}/${name}' 0770 ${cfg.user} ${cfg.group} - -"
        )
        services;

      systemd.services = mapAttrs'
        (name: conf:
          let
            tmux = "${getBin pkgs.tmux}/bin/tmux";
            tmuxSock = "${cfg.runDir}/${name}.sock";

            symlinks = normalizeFiles (conf.symlinks);
            files = normalizeFiles (conf.files);

            startScript = pkgs.writeScript "python-start-${name}" ''
              #!${pkgs.runtimeShell}
              ${tmux} -S ${tmuxSock} new -d ${cfg.dataDir}/${name}/${conf.executable} ${conf.pythonOpts}

              ${tmux} -S ${tmuxSock} service-access -aw nobody
            '';

            stopScript = pkgs.writeScript "python-stop-${name}" ''
              #!${pkgs.runtimeShell}

              function service_running {
                ${tmux} -S ${tmuxSock} has-session
              }

              if ! service_running ; then
                exit 0
              fi

              ${tmux} -S ${tmuxSock} send-keys C-c

              while service_running ; do
                sleep 0.25
              done
            '';
          in
          {
            name = "python-service-${name}";
            value = rec {
              description = "Python service ${name}";
              wantedBy = mkIf conf.autoStart [ "multi-user.target" ];
              after = [ "network.target" ];

              enable = conf.enable;

              startLimitIntervalSec = 120;
              startLimitBurst = 5;

              serviceConfig = {
                ExecStart = "${startScript}";
                ExecStop = "${stopScript}";
                Restart = conf.restart;
                WorkingDirectory = "${cfg.dataDir}/${name}";
                User = cfg.user;
                Group = cfg.group;
                Type = "simple";
                GuessMainPID = true;
                RuntimeDirectory = "python";
                RuntimeDirectoryPreserve = "yes";

                # Hardening
                CapabilityBoundingSet = [ "" ];
                DeviceAllow = [ "" ];
                LockPersonality = true;
                PrivateDevices = true;
                PrivateTmp = true;
                PrivateUsers = true;
                ProtectClock = true;
                ProtectControlGroups = true;
                ProtectHome = true;
                ProtectHostname = true;
                ProtectKernelLogs = true;
                ProtectKernelModules = true;
                ProtectKernelTunables = true;
                ProtectProc = "invisible";
                RestrictNamespaces = true;
                RestrictRealtime = true;
                RestrictSUIDSGID = true;
                SystemCallArchitectures = "native";
                UMask = "0007";
              };

              inherit (conf) path environment;

              reload = ''
                ${postStop}
                ${preStart}
              '';

              preStart =
                let
                  mkSymlinks = pkgs.writeShellScript "python-service-${name}-symlinks"
                    (concatStringsSep "\n"
                      (mapAttrsToList
                        (n: v: ''
                          if [[ -L "${n}" ]]; then
                            unlink "${n}"
                          elif [[ -e "${n}" ]]; then
                            echo "${n} already exists, moving"
                            mv "${n}" "${n}.bak"
                          fi
                          mkdir -p "$(dirname "${n}")"
                          ln -sf "${v}" "${n}"
                        '')
                        symlinks));

                  mkFiles = pkgs.writeShellScript "python-service-${name}-files"
                    (concatStringsSep "\n"
                      (mapAttrsToList
                        (n: v: ''
                          if [[ -L "${n}" ]]; then
                            unlink "${n}"
                          elif ${pkgs.diffutils}/bin/cmp -s "${n}" "${v}"; then
                            rm "${n}"
                          elif [[ -e "${n}" ]]; then
                            echo "${n} already exists, moving"
                            mv "${n}" "${n}.bak"
                          fi
                          mkdir -p $(dirname "${n}")
                          ${pkgs.gawk}/bin/awk '{
                            for(varname in ENVIRON)
                              gsub("@"varname"@", ENVIRON[varname])
                            print
                          }' "${v}" > "${n}"
                        '')
                        files));
                in
                ''
                  ${mkSymlinks}
                  ${mkFiles}
                '';

              postStart = ''
                ${pkgs.coreutils}/bin/chmod 660 ${tmuxSock}
              '';

              postStop =
                let
                  rmSymlinks = pkgs.writeShellScript "python-service-${name}-rm-symlinks"
                    (concatStringsSep "\n"
                      (mapAttrsToList (n: v: "unlink \"${n}\"") symlinks)
                    );
                  rmFiles = pkgs.writeShellScript "python-service-${name}-rm-files"
                    (concatStringsSep "\n"
                      (mapAttrsToList (n: v: "rm -f \"${n}\"") files)
                    );
                in
                ''
                  ${rmSymlinks}
                  ${rmFiles}
                '';
            };
          })
        services;
    }
  );
}
