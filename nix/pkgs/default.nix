{
  lib,
  newScope,
  zig_0_16,
}:
lib.makeScope newScope (self: {
  # Pinned until the Zig 0.17 migration
  zig = zig_0_16;
  levee = self.callPackage ./levee/package.nix {};
})
