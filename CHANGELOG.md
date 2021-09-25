# Changelog

## v0.2.3

* New features
  * Initial support for using `scp` to copy files. Not all `scp` features work,
    but uploading and downloading individual files does. Thanks to Connor Rigby
    and Binary Noggin for this feature.

## v0.2.2

* Improvements
  * Fix a deprecation warning on OTP 24.0.1 and later
  * Add support for LFE shells. LFE must be a dependency of your project for
    this to work.

## v0.2.1

* Improvements
  * Raise an error at compile-time if the application environment looks like
    it's using the `:nerves_firmware_ssh` key instead of the `:nerves_ssh` one.

## v0.2.0

This update makes using the application environment optional. If you don't have
any settings for `:nerves_ssh` in your `config.exs`, `:nerves_ssh` won't start.
You can then add `{NervesSSH, your_options}` to the supervision tree of your
choice.

## v0.1.0

Initial release
