{
  lib,
  newScope,
  zig,
}:
lib.makeScope newScope (self: {
  inherit zig;
  levee = self.callPackage ./levee/package.nix {};
})
