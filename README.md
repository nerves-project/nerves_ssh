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

- [X] Support public key authentication
- [ ] Support username/password authentication
- [ ] Device generated Server certificate and key
- [ ] Device generated username/password

## Usage

<!-- MDOC !-->

A wrapper around SSH daemon focused purely on the context of Nerves devices.

It keeps `sshd` under supervision and monitored so that daemon failures
can be recovered.

While this will be started with your application, it is generally a good
idea to separate connection level processes from your main application via
`shoehorn`. In the event of your application failure, this still keeps the
ability to conenct to the device over SSH:

```elixir
config :shoehorn,
  init: [:nerves_runtime, :vintage_net, :nerves_ssh]
```

## Configuration

NervesSSH supports a few pieces of configuration via the application config:

* `authorized_keys` - list of public key strings
* `port` - port for the SSH daemon. Defaults to `22`
* `subsystems` - list of subsystem specs that should run under the SSH daemon. Each item must conform to the Erlang [`subsystem_spec`](https://erlang.org/doc/man/ssh.html#type-subsystem_spec) type. SFTP included by default. NervseFirmwareSSH subsystem is ensured to always be included, even when supplying your own 
* `system_dir` - path for the SSH system dir. Tries `/etc/ssh` then defaults to `:nerves_ssh` priv dir

