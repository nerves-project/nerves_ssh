# NervesSSH

[![CircleCI](https://circleci.com/gh/nerves-project/nerves_ssh/tree/main.svg?style=svg)](https://circleci.com/gh/nerves-project/nerves_ssh/tree/main)
[![Hex version](https://img.shields.io/hexpm/v/nerves_ssh.svg "Hex version")](https://hex.pm/packages/nerves_ssh)

Manage an SSH daemon and its subsystems on Nerves devices

## Usage

This library wraps Erlang/OTP's [SSH
daemon](http://erlang.org/doc/man/ssh.html#daemon-1) to make it easier to use
reliably with Nerves devices.

Most importantly, it makes it possible to segment failures in other OTP
applications from terminating the daemon and it recovers from rare scenarios
where the daemon terminates without automatically restarting.

If you're using [`:nerves_pack`](https://hex.pm/packages/nerves_pack) v0.4.0 or
later, you don't need to do anything except, perhaps, modify the `:nerves_ssh`'s
configuration in your `config.exs`. If you are not using `:nerves_pack`, add
`:nerves_ssh` to your `mix` dependency list:

```elixir
def deps do
  [
    {:nerves_ssh, "~> 0.1.0", targets: @all_targets}
  ]
end
```

And then include it in `:shoehorn`'s `:init` list:

```elixir
config :shoehorn,
  init: [:nerves_runtime, :vintage_net, :nerves_ssh]
```

`:nerves_ssh` will work if you do not add it to the `:init` list. However, if
your main OTP application stops, OTP may stop `:nerves_ssh`, and that would make
your device inaccessible via SSH.

## Configuration

NervesSSH supports a few pieces of configuration via the application config:

* `:authorized_keys` - a list of SSH authorized key file string
* `:user_passwords` - a list of username/password tuples (stored in the
    clear!)
* `:port` - the TCP port to use for the SSH daemon. Defaults to `22`.
* `:subsystems` - a list of [SSH subsystems specs](https://erlang.org/doc/man/ssh.html#type-subsystem_spec) to start. Defaults to SFTP and `ssh_subsystem_fwup`
* `:system_dir` - where to find host keys
* `:shell` - the language of the shell (`:elixir`, `:erlang`, or `:disabled`). Defaults to `:elixir`.
* `:exec` - the language to use for commands sent over ssh (`:elixir`, `:erlang`, or `:disabled`). Defaults to `:elixir`.
* `:iex_opts` - additional options to use when starting up IEx
* `:daemon_option_overrides` - additional options to pass to `:ssh.daemon/2`. These take precedence and are unchecked.

## Authentication

It's possible to set up a number of authentication strategies with the Erlang
SSH daemon. Currently, only simple public key and username/password
authentication setups are supported by `:nerves_ssh`. Both of them work fine for
getting started. As needs become more sophisticated, you can pass options to
`:daemon_option_overrides`.

### Public key authentication

Public ssh keys can be included in the `config.exs` so that matching clients can
connect. These come from files like your `~/.ssh/id_rsa.pub` or
`~/.ssh/id_ecdsa.pub` that were created when you created your `ssh` keys. If you
haven't done this, the following
[article](https://help.github.com/articles/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent/)
may be helpful. Here's an example:

```elixir
config :nerves_ssh,
  authorized_keys: [
    "ssh-rsa
AAAAB3NzaC1yc2EAAAADAQABAAAAgQDBCdMwNo0xOE86il0DB2Tq4RCv07XvnV7W1uQBlOOE0ZZVjxmTIOiu8XcSLy0mHj11qX5pQH3Th6Jmyqdj",
    "ssh-rsa
AAAAB3NzaC1yc2EAAAADAQABAAACAQCaf37TM8GfNKcoDjoewa6021zln4GvmOiXqW6SRpF61uNWZXurPte1u8frrJX1P/hGxCL7YN3cV6eZqRiF"
  ]
```

Here's another way that may work well for you that avoids needing to commit your
keys:

```elixir
config :nerves_ssh,
  authorized_keys: [
    File.read!(Path.join(System.user_home!, ".ssh/id_rsa.pub"))
  ]
```

### Username/password authentication

The SSH console uses public key authentication by default, but it can be
configured for usernames and passwords via the `:user_passwords` key. This
has the form `[{"username", "password"}, ...]`. Keep in mind that passwords are
stored in the clear. This is not recommended for most situations.

```elixir
config :nerves_ssh,
  user_passwords: [
    {"username", "password"}
  ]
```

## Goals

* [X] Support public key authentication
* [X] Support username/password authentication
* [ ] Device generated server certificate and key
* [ ] Device generated username/password
