defmodule NervesSSH.Application do
  @moduledoc false

  use Application

  alias NervesSSH.Options

  require Logger

  @default_system_dir "/etc/ssh"
  @default_iex_exs_path "/etc/iex.exs"

  def start(_type, _args) do
    # Prefer supplied opts, default to application env

    # TODO: Pull in any relevant :nerves_firmware_ssh options in addition to the authorized keys...
    opts =
      firmware_ssh_options()
      |> Keyword.merge(Application.get_all_env(:nerves_ssh))
      |> resolve_system_dir()
      # |> resolve_iex_exs_path()
      |> Options.new()
      |> Options.sanitize()

    children = [{NervesSSH.Daemon, opts}]

    opts = [strategy: :one_for_one, name: NervesSSH.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp firmware_ssh_options() do
    # Check for legacy nerves_firmware_ssh options so that if they still
    # exist, they get merged with a warning.
    case Application.get_env(:nerves_firmware_ssh, :authorized_keys) do
      keys when is_list(keys) ->
        Logger.warn(
          "ssh authorized keys found in :nerves_firmware_ssh. Please move them to :nerves_ssh in your config.exs."
        )

        [authorized_keys: keys]

      _other ->
        []
    end
  end

  defp resolve_system_dir(opts) do
    cond do
      system_dir = opts.system_dir ->
        system_dir

      File.dir?(@default_system_dir) and host_keys_readable?(@default_system_dir) ->
        @default_system_dir

      true ->
        :code.priv_dir(:nerves_ssh)
    end
  end

  defp find_iex_exs() do
    [".iex.exs", "~/.iex.exs", "/etc/iex.exs"]
    |> Enum.map(&Path.expand/1)
    |> Enum.find("", &File.regular?/1)
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
