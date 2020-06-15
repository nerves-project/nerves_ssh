defmodule NervesSSH.Application do
  @moduledoc false

  use Application

  alias NervesSSH.Options

  require Logger

  @default_system_dir "/etc/ssh"

  def start(_type, _args) do
    opts =
      Application.get_all_env(:nerves_ssh)
      |> Options.new()
      |> resolve_system_dir()
      |> add_fwup_subsystem()
      |> Options.sanitize()

    children = [{NervesSSH.Daemon, opts}]

    opts = [strategy: :one_for_one, name: NervesSSH.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp add_fwup_subsystem(opts) do
    # TODO: Make it possible to opt out of this

    devpath = Nerves.Runtime.KV.get("nerves_fw_devpath")

    new_subsystems = [SSHSubsystemFwup.subsystem_spec(devpath: devpath) | opts.subsystems]
    %{opts | subsystems: new_subsystems}
  end

  defp resolve_system_dir(opts) do
    cond do
      File.dir?(opts.system_dir) ->
        opts

      File.dir?(@default_system_dir) and host_keys_readable?(@default_system_dir) ->
        %{opts | system_dir: @default_system_dir}

      true ->
        %{opts | system_dir: :code.priv_dir(:nerves_ssh)}
    end
  end

  defp host_keys_readable?(path) do
    ["ssh_host_rsa_key", "ssh_host_dsa_key", "ssh_host_ecdsa_key"]
    |> Enum.map(fn name -> Path.join(path, name) end)
    |> Enum.any?(&readable?/1)
  end

  defp readable?(path) do
    case File.read(path) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
