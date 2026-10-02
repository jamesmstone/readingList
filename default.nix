{
  lib,
  buildGoModule,
}:
buildGoModule {
  pname = "readinglist";
  version = "0-unstable-2026-09-30";

  # The screenshot/PDF archive under .site is >2GiB; keep it out of the build.
  src = lib.fileset.toSource {
    root = ./.;
    fileset = lib.fileset.unions [
      ./go.mod
      ./go.sum
      ./main.go
      ./manager.go
      ./generator.go
      ./transport
    ];
  };

  vendorHash = "sha256-snyrVHXWSB84li/xFuqYuTzwnXD0ZkQRHPh6XuYjgas=";

  meta = {
    description = "Appends to readingList.csv and renders the static reading list";
    license = lib.licenses.mit;
    mainProgram = "readingList";
  };
}
