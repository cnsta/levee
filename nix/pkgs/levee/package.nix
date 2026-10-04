{
  lib,
  stdenv,
  zig,
  libxkbcommon,
  wayland,
  wayland-protocols,
  wayland-scanner,
  libvpx,
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
    libvpx
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
    license = lib.licenses.bsd0;
    mainProgram = "levee";
    platforms = lib.platforms.linux;
  };
})
