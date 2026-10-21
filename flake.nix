{
  description = "Reading list — read.jamesst.one and api-read.jamesst.one";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    systems.url = "github:nix-systems/default";
  };

  nixConfig = {
    extra-substituters = [
      "https://cache.nixos.org"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  outputs =
    inputs:
    let
      inherit (inputs.nixpkgs) lib;
      eachSystem = lib.genAttrs (import inputs.systems);
      pkgsFor = eachSystem (system: import inputs.nixpkgs { inherit system; });
    in
    {
      packages = eachSystem (
        system:
        let
          pkgs = pkgsFor.${system};
        in
        rec {
          readinglist = pkgs.callPackage ./default.nix { };
          database = pkgs.callPackage ./database.nix { };
          default = readinglist;

          # shot-scraper's playwright refuses to fetch its own browsers, so
          # point it at the ones nixpkgs already built. Wrapped rather than set
          # in the unit, so the devshell and the service shoot identically.
          shot-scraper = pkgs.writeShellApplication {
            name = "shot-scraper";
            runtimeInputs = [ pkgs.shot-scraper ];
            text = ''
              export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
              export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=true
              exec shot-scraper "$@"
            '';
            meta.description = "shot-scraper pointed at the store's browsers";
          };

          # What the systemd units run. A package rather than a script inlined
          # in the module, so the unit's PATH is the one the VM test exercises.
          append = pkgs.writeShellApplication {
            name = "readinglist-append";
            runtimeInputs = [
              readinglist
              pkgs.bash
              pkgs.coreutils
              pkgs.git
              pkgs.jq
              pkgs.openssh
              pkgs.rsync
              pkgs.sqlite-utils
              pkgs.util-linux
            ];
            text = builtins.readFile ./nix/append.sh;
            meta.description = "record an article, then rebuild and publish the list";
          };

          # Enough of a checkout for the VM test to clone, append to and push.
          # The CSV is deliberately absent: `readingList add` writes the header
          # itself, so seeding one would hide a regression in that path.
          testSeed = pkgs.runCommand "readinglist-seed" { } ''
            mkdir -p $out/.site/css
            cp ${./run.sh} $out/run.sh
            cp ${./.site/css/ghpages.css} $out/.site/css/ghpages.css
          '';
        }
      );

      nixosModules.readinglist = import ./nix/module.nix { self = inputs.self; };
      nixosModules.default = inputs.self.nixosModules.readinglist;

      checks = eachSystem (
        system:
        let
          pkgs = pkgsFor.${system};
        in
        {
          inherit (inputs.self.packages.${system})
            readinglist
            database
            append
            shot-scraper
            ;
        }
        # Keyed off the system string rather than `pkgs.stdenv`, so listing the
        # outputs does not have to instantiate a nixpkgs for darwin.
        // lib.optionalAttrs (lib.hasSuffix "-linux" system) {
          # Drives the real units, so the append's PATH, locking and publish
          # steps are exercised rather than the builder's. No network: the
          # screenshot tool is stubbed, and the Hacker News lookup inside
          # `readingList add` already tolerates failing.
          endpoint = pkgs.testers.runNixOSTest {
            name = "readinglist-endpoint";

            nodes.machine = {
              imports = [ inputs.self.nixosModules.readinglist ];

              environment.systemPackages = [
                pkgs.curl
                pkgs.git
                pkgs.sqlite
              ];

              services.readinglist = {
                enable = true;
                user = "root";
                address = "127.0.0.1";
                remote = "/srv/archive.git";
                publishDB = "/srv/datasette/readingList.db";
                publishSite = "/srv/site";
                # Started by the test, not by the clock.
                reconcileInterval = null;

                shotScraper = pkgs.writeShellApplication {
                  name = "shot-scraper";
                  runtimeInputs = [ pkgs.coreutils ];
                  text = ''
                    # A page that never loads, for the subtest that times
                    # an append out. Backgrounded so the process the server
                    # has to kill is a grandchild of the script, not a child.
                    case "$*" in
                    *example.com/slow*)
                      sleep 600 &
                      wait
                      ;;
                    esac

                    # Mimics both calling conventions: `shot-scraper URL -o
                    # out.png` and `shot-scraper pdf URL -o out.pdf`.
                    out=""
                    while [ $# -gt 0 ]; do
                      case "$1" in
                      -o)
                        out=$2
                        shift 2
                        ;;
                      *) shift ;;
                      esac
                    done
                    [ -n "$out" ] || exit 1
                    printf 'stub' >"$out"
                  '';
                };
              };
            };

            testScript = ''
              from datetime import timedelta

              machine.wait_for_unit("multi-user.target")

              machine.succeed(
                  "mkdir -p /srv/seed",
                  "cp -r ${inputs.self.packages.${system}.testSeed}/. /srv/seed/",
                  "chmod -R u+w /srv/seed",
                  "git -C /srv/seed init -q -b main",
                  "git -C /srv/seed add -A",
                  "git -C /srv/seed -c user.name=t -c user.email=t@t commit -qm seed",
                  "git clone -q --bare /srv/seed /srv/archive.git",
              )

              machine.wait_for_unit("readinglist.service")
              machine.wait_for_open_port(8108)
              machine.succeed("curl -sS --fail http://127.0.0.1:8108/healthz")

              with subtest("a GET cannot append"):
                  machine.succeed(
                      "curl -sS -o /dev/null -w '%{http_code}' "
                      "http://127.0.0.1:8108/add | grep -q 405"
                  )

              with subtest("an entry with no URL is refused"):
                  machine.succeed(
                      "curl -sS -o /dev/null -w '%{http_code}' -X POST "
                      "-H 'Content-Type: application/json' -d '{\"title\":\"no url\"}' "
                      "http://127.0.0.1:8108/add | grep -q 400"
                  )

              with subtest("an append is recorded, pushed and published"):
                  machine.succeed(
                      "curl -sS --fail --max-time 300 -X POST "
                      "-H 'Content-Type: application/json' "
                      "-d '{\"url\":\"https://example.com/a\",\"title\":\"An article\"}' "
                      "http://127.0.0.1:8108/add"
                  )

                  tracked = machine.succeed("git -C /srv/archive.git ls-tree -r --name-only main")
                  assert "readingList.csv" in tracked, tracked
                  assert ".site/index.html" in tracked, tracked
                  assert len([f for f in tracked.split("\n") if f.endswith(".pdf")]) == 1, tracked

                  rows = machine.succeed("sqlite3 /srv/datasette/readingList.db 'select url from read'")
                  assert rows.strip() == "https://example.com/a", rows

                  published = machine.succeed("ls /srv/site /srv/site/css")
                  assert "index.html" in published, published
                  assert "ghpages.css" in published, published
                  assert ".png" in published, published
                  # The index links every PDF, so each must be served.
                  assert ".pdf" in published, published
                  machine.succeed(
                      "grep -o 'href=\"[^\"]*\\.pdf\"' /srv/site/index.html | cut -d'\"' -f2 "
                      "| while read -r f; do test -s \"/srv/site/$f\" || exit 1; done"
                  )

              with subtest("a form-encoded append works too"):
                  machine.succeed(
                      "curl -sS --fail --max-time 300 -X POST "
                      "--data-urlencode url=https://example.com/b "
                      "--data-urlencode title=Another "
                      "http://127.0.0.1:8108/add"
                  )
                  rows = machine.succeed("sqlite3 /srv/datasette/readingList.db 'select count(*) from read'")
                  assert rows.strip() == "2", rows

              with subtest("a republish appends nothing and still succeeds"):
                  machine.succeed("systemctl start readinglist-publish.service")
                  rows = machine.succeed("sqlite3 /srv/datasette/readingList.db 'select count(*) from read'")
                  assert rows.strip() == "2", rows

              with subtest("a republish repairs an emptied publish directory"):
                  machine.succeed("rm -rf /srv/site")
                  machine.succeed("systemctl start readinglist-publish.service")
                  machine.succeed("test -s /srv/site/index.html")
                  machine.succeed("test -s /srv/site/css/ghpages.css")

              with subtest("both units outlast the script's own worst case"):
                  timeout = machine.succeed(
                      "systemctl show -P TimeoutStartUSec readinglist-publish.service"
                  )
                  assert timeout.strip() == "3h", timeout
                  env = machine.succeed("systemctl show -P Environment readinglist.service")
                  assert "RL_TIMEOUT_SECONDS=10800" in env, env

              with subtest("a timed-out append is killed whole"):
                  machine.succeed(
                      "mkdir -p /run/systemd/system/readinglist.service.d",
                      "printf '[Service]\\nEnvironment=RL_TIMEOUT_SECONDS=5\\n' "
                      ">/run/systemd/system/readinglist.service.d/timeout.conf",
                      "systemctl daemon-reload",
                      "systemctl restart readinglist.service",
                  )
                  machine.wait_for_open_port(8108)
                  machine.succeed(
                      "curl -sS -o /dev/null -w '%{http_code}' --max-time 60 -X POST "
                      "-H 'Content-Type: application/json' "
                      "-d '{\"url\":\"https://example.com/slow\",\"title\":\"Slow\"}' "
                      "http://127.0.0.1:8108/add | grep -q 500"
                  )
                  # Anchored, so it cannot match the shell running pgrep.
                  machine.wait_until_fails("pgrep -f '^sleep 600$'", timeout=timedelta(seconds=10))

                  machine.succeed(
                      "rm -r /run/systemd/system/readinglist.service.d",
                      "systemctl daemon-reload",
                      "systemctl restart readinglist.service",
                  )
                  machine.wait_for_open_port(8108)

              with subtest("an interrupted clone is recovered, not wedged on"):
                  # What a clone killed before it fetched leaves behind: a
                  # .git with no HEAD, both in place and cloned aside.
                  machine.succeed(
                      "rm -rf /var/lib/readinglist/repo",
                      "git init -q /var/lib/readinglist/repo",
                      "git init -q /var/lib/readinglist/repo.tmp",
                  )
                  machine.succeed("systemctl start readinglist-publish.service")
                  head = machine.succeed("git -C /var/lib/readinglist/repo rev-parse HEAD")
                  main = machine.succeed("git -C /srv/archive.git rev-parse main")
                  assert head == main, (head, main)
                  machine.fail("test -e /var/lib/readinglist/repo.tmp")
                  rows = machine.succeed("sqlite3 /srv/datasette/readingList.db 'select count(*) from read'")
                  assert rows.strip() == "2", rows
            '';
          };
        }
      );

      devShells = eachSystem (
        system:
        let
          pkgs = pkgsFor.${system};
        in
        {
          default = pkgs.mkShell {
            packages = [
              inputs.self.packages.${system}.readinglist
              inputs.self.packages.${system}.shot-scraper
            ]
            ++ (with pkgs; [
              git
              go
              jq
              rsync
              sqlite-utils
            ]);
          };
        }
      );
    };
}
