# levee

This project is made to integrate with my
[river](https://codeberg.org/river/river) window manager
[delta](https://github.com/cnsta/delta).

Status: experimental.

### Configuration

levee reads `$XDG_CONFIG_HOME/levee/config.zon` (default `~/.config/levee/`)
each time it locks; `-config <path>` picks another file and command-line flags
override it. Every field is optional, and a broken file is logged and ignored.
See [`example-config.zon`](example-config.zon) for every option.

The background is a solid color unless `.background.path` names an image (png,
bmp, tga, qoi, jpeg, gif) or a VP8/VP9 `.mp4`, which loops. Video is detected
from the file's content, so nothing else needs enabling.

### Disclaimer

This project started as clone of @ifreund's `waylock`. A fork and a playground
for me to work with and learn zig. It has diverged quite a bit from that, but
surely wouldn't exist without it.

If you're looking for an actual general purpose wayland screenlocker, use
[waylock](https://isaacfreund.com/software/waylock).
