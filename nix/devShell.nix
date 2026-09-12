{
  mkShell,
  lib,
  pkg-config,
  libxkbcommon,
  alejandra,
  wayland,
  wayland-scanner,
  wayland-protocols,
  pam,
  zon2nix,
  zig,
}: let
  runtimeLibs = [
    wayland
    libxkbcommon
    pam
  ];
in
  mkShell {
    name = "levee-dev-shell";

    nativeBuildInputs = [
      zig
      zon2nix
      pkg-config
      wayland-scanner
      wayland-protocols
      alejandra
    ];

    buildInputs = runtimeLibs;

    env = {
      ZIG_GLOBAL_CACHE_DIR = "../.zig-cache/global";
      LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;
    };

    shellHook = ''
      echo "⚡ levee dev shell ready"
      echo "Zig version: $(zig version)"
    '';
  }
