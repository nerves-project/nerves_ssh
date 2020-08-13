# Changelog

## v0.2.0

This update makes using the application environment optional. If you don't have
any settings for `:nerves_ssh` in your `config.exs`, `:nerves_ssh` won't start.
You can then add `{NervesSSH, your_options}` to the supervision tree of your
choice.

## v0.1.0

Initial release
