# NervesSSH

[![CircleCI](https://circleci.com/gh/nerves-project/nerves_ssh.svg?style=svg)](https://circleci.com/gh/nerves-project/nerves_ssh)
[![Hex version](https://img.shields.io/hexpm/v/nerves_ssh.svg "Hex version")](https://hex.pm/packages/nerves_ssh)

Manage a SSH daemon and subsystems on Nerves devices.

## Installation

To use, add the dependency to your `mix.exs`:

```elixir
def deps do
  [
    {:nerves_ssh, "~> 0.1.0", targets: @all_targets}
  ]
end
```

## Goals

* [X] Support public key authentication
* [X] Support username/password authentication
* [ ] Device generated Server certificate and key
* [ ] Device generated username/password

## Usage

<!-- MDOC !-->

A wrapper around SSH daemon focused purely on the context of Nerves devices.

It keeps `sshd` under supervision and monitored so that daemon failures can be
recovered.

While this will be started with your application, it is generally a good idea to
separate connection level processes from your main application via `shoehorn`.
Then the event of your application failure, the separated `nerves_ssh`
application will continue to work instead of crashing with your app:

```elixir
config :shoehorn,
  init: [:nerves_runtime, :vintage_net, :nerves_ssh]
```

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

FILL IN...

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

