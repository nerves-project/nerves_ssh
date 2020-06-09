# This file is used to resolve an iex.exs location when starting a ssh session
# Offsetting this lookup to runtime at ssh session start allows you to make changes
# to your iex.exs and resolve errors without requiring a new firmware.
#
# If you change your iex.exs on device that is resovled here, you should be
# sure to port those changes back to your original iex.exs file that is
# used when burning the firmware

# Pull from iex_opts and add to list of default places to try
[
  Application.get_env(:nerves_ssh, :iex_opts, [])[:dot_iex_path],
  ".iex.exs",
  "~/.iex.exs",
  "/etc/iex.exs"
]
|> Enum.filter(&is_bitstring/1)
|> Enum.map(&Path.expand/1)
|> Enum.find("", &File.regular?/1)
|> import_file()
