defmodule NervesSSH do
  @moduledoc File.read!("README.md")
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  use GenServer

  require Logger

  @type opt ::
          {:authorized_keys, [String.t()]}
          | {:force, boolean()}
          | {:port, non_neg_integer()}
          | {:subsystems, [:ssh.subsystem_spec()]}
          | {:system_dir, Path.t()}

  @default_subsystems [
    :ssh_sftpd.subsystem_spec(cwd: '/'),
    NervesFirmwareSSH2.subsystem_spec(subsystem: 'nerves_firmware_ssh')
  ]

  @default_system_dir "/etc/ssh"

  @dialyzer [{:no_opaque, start_daemon: 3}]

  defmodule State do
    @type t :: %__MODULE__{
            opts: [NervesSSH.opt()],
            port: non_neg_integer(),
            sshd: pid(),
            sshd_ref: reference()
          }

    defstruct opts: [], port: nil, sshd: nil, sshd_ref: nil
  end

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Read the configuration options
  """
  @spec configuration :: [opt()]
  def configuration() do
    GenServer.call(__MODULE__, :configuration)
  end

  @impl true
  def init(opts) do
    # Prefer supplied opts, default to application env
    opts =
      Application.get_all_env(:nerves_ssh)
      |> Keyword.merge(opts)

    # Make sure we can attempt SSH daemon cleanup if
    # NervesSSH application gets shutdown
    Process.flag(:trap_exit, true)

    {:ok, %State{opts: opts}, {:continue, :start_daemon}}
  end

  @impl true
  def handle_call(:configuration, _from, state) do
    {:reply, state.opts, state}
  end

  @impl true
  def handle_continue(:start_daemon, state) do
    case start_daemon(state) do
      {:error, reason} -> {:stop, reason, state}
      new_state -> {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _sshd, reason}, state) do
    Logger.warn("[NervesSSH] sshd #{inspect(state.sshd)} crashed: #{inspect(reason)}")

    # force the ssh daemon to start with our options again
    case start_daemon(state, true) do
      {:error, err} ->
        Logger.error("[NervesSSH] failed to restart sshd: #{inspect(err)}")
        {:stop, err, state}

      new_state ->
        {:noreply, new_state}
    end
  end

  @impl true
  def terminate(reason, state) do
    Logger.error("[NervesSSH] terminating with reason: #{inspect(reason)}")

    # Try not to leave rogue SSH daemon processes
    stop_daemon(state)
  end

  defp decoded_authorized_keys(opts) do
    # Piggy back on NervesFirmwareSSH config if needed
    keys =
      opts[:authorized_keys] || Application.get_env(:nerves_firmware_ssh, :authorized_keys) || []

    Enum.join(keys, "\n")
    |> :public_key.ssh_decode(:auth_keys)
  end

  defp exec(cmd, _user, _peer) do
    try do
      {result, _env} = Code.eval_string(to_string(cmd))
      IO.inspect(result)
    catch
      kind, value ->
        IO.puts("** (#{kind}) #{inspect(value)}")
    end
  end

  defp find_iex_exs() do
    [".iex.exs", "~/.iex.exs", "/etc/iex.exs"]
    |> Enum.map(&Path.expand/1)
    |> Enum.find("", &File.regular?/1)
  end

  defp get_port(opts) do
    opts[:port] || Application.get_env(:nerves_ssh, :port, 22)
  end

  defp host_keys_readable?(path) do
    ["ssh_host_rsa_key", "ssh_host_dsa_key", "ssh_host_ecdsa_key"]
    |> Enum.map(fn name -> Path.join(path, name) end)
    |> Enum.any?(&readable?/1)
  end

  defp is_subsystem?({name, {mod, args}}) when is_list(name) and is_atom(mod) and is_list(args) do
    List.ascii_printable?(name)
  end

  defp is_subsystem?(_), do: false

  defp readable?(path) do
    case File.read(path) do
      {:ok, _} -> true
      _ -> false
    end
  end

  defp system_dir(opts) do
    cond do
      system_dir = opts[:system_dir] ->
        to_charlist(system_dir)

      system_dir = Application.get_env(:nerves_firmware_ssh, :system_dir) ->
        to_charlist(system_dir)

      File.dir?(@default_system_dir) and host_keys_readable?(@default_system_dir) ->
        to_charlist(@default_system_dir)

      true ->
        :code.priv_dir(:nerves_ssh)
    end
  end

  defp subsystems(opts) do
    subsystems =
      (opts[:subsystems] || @default_subsystems)
      |> Enum.filter(&is_subsystem?/1)

    if Enum.any?(subsystems, &(elem(&1, 0) == 'nerves_firmware_ssh')) do
      subsystems
    else
      [NervesFirmwareSSH2.subsystem_spec(subsystem: 'nerves_firmware_ssh') | subsystems]
    end
  end

  @spec start_daemon(map(), boolean(), non_neg_integer()) :: map() | {:error, any()}
  defp start_daemon(state, force \\ false, attempt \\ 1)

  defp start_daemon(state, _force, attempt) when attempt > 10 do
    {:error, "failed to start ssh daemon on #{get_port(state.opts)} after 10 attempts"}
  end

  defp start_daemon(%{opts: opts} = state, force?, attempt) do
    cb_opts = [authorized_keys: decoded_authorized_keys(opts)]

    # Nerves stores a system default iex.exs. It's not in IEx's search path,
    # so run a search with it included.
    iex_opts = [dot_iex_path: find_iex_exs()]

    port = get_port(opts)

    options = [
      {:id_string, :random},
      {:key_cb, {NervesSSH.Keys, cb_opts}},
      {:system_dir, system_dir(opts)},
      {:shell, {Elixir.IEx, :start, [iex_opts]}},
      {:exec, &start_exec/3},
      {:subsystems, subsystems(opts)},
      :inet6
    ]

    case {:ssh.daemon(port, options), force?} do
      {{:ok, sshd}, _} ->
        %{state | port: port, sshd: sshd, sshd_ref: Process.monitor(sshd)}

      {{:error, :eaddrinuse}, _force = true} ->
        with %{} = state <- stop_daemon(state), do: start_daemon(state, force?, attempt + 1)

      {{:error, :eaddrinuse}, _no_force} ->
        {:error, {:eaddrinuse, state.sshd}}

      {err, _} ->
        err
    end
  end

  defp start_exec(cmd, user, peer) do
    spawn(fn -> exec(cmd, user, peer) end)
  end

  @spec stop_daemon(map(), non_neg_integer()) :: map() | {:error, any()}
  defp stop_daemon(state, attempt \\ 1)

  defp stop_daemon(_state, attempt) when attempt > 10 do
    {:error, "failed to stop ssh daemon after 10 attempts"}
  end

  defp stop_daemon(state, attempt) do
    port = state.port || 22

    if state.sshd_ref, do: Process.demonitor(state.sshd_ref)

    if is_pid(state.sshd),
      do: :ssh.stop_daemon(state.sshd),
      else: :ssh.stop_daemon({0, 0, 0, 0}, port)

    # Apparently there is a bug in erlang ssh where tcp socket can remain
    # open even when the daemon crashes/doesn't start, so we forcibly search
    # for a socket using our port and close it
    #
    # Based on https://github.com/se-apc/sshd/blob/master/lib/sshd.ex#L383-L384
    rouge_socket =
      Port.list()
      |> Enum.find(
        &(Port.info(&1)[:name] == 'tcp_inet' and
            match?({:ok, {{0, 0, 0, 0}, ^port}}, :prim_inet.sockname(&1)))
      )

    if rouge_socket, do: :gen_tcp.close(rouge_socket)

    if is_pid(state.sshd) and Process.alive?(state.sshd) do
      # Failed to stop so let's keep trying
      stop_daemon(state, attempt + 1)
    else
      %{state | sshd: nil, sshd_ref: nil, port: nil}
    end
  end
end
