local config = require "core.config"

config.ignore_files = {
  "^%.",
  "^zig%-cache$",
  "^zig%-out$",
}
