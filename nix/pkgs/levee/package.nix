{
  lib,
  stdenv,
  zig,
  libxkbcommon,
  wayland,
  wayland-protocols,
  wayland-scanner,
  pam,
  pkg-config,
  callPackage,
}:
stdenv.mkDerivation (finalAttrs: {
  pname = "levee";
  version = "unstable";

  src = lib.fileset.toSource {
    root = ../../..;
    fileset = lib.fileset.unions [
      ../../../build.zig
      ../../../build.zig.zon
      ../../../src
      ../../../protocol
      ../../../pam.d
    ];
  };

  deps = callPackage ./build.zig.zon.nix {};

  nativeBuildInputs = [
    zig
    pkg-config
    wayland-scanner
    wayland-protocols
  ];

  buildInputs = [
    libxkbcommon
    wayland
    pam
  ];

  zigBuildFlags = [
    "--system"
    "${finalAttrs.deps}"
    "-Doptimize=ReleaseSafe"
  ];

  doCheck = true;

  zigCheckFlags = finalAttrs.zigBuildFlags;

  meta = {
    homepage = "https://git.cnst.dev/cnst/levee";
    description = "An optional screen locker for river, using ext-session-lock-v1";
    mainProgram = "levee";
    platforms = lib.platforms.linux;
  };
})
