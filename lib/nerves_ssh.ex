defmodule NervesSSH do
  @moduledoc """
  Manages an ssh daemon.

  Currently piggy-backs off authorized keys defined for `NervesFirmwareSSH`
  and enables SFTP as a subsystem of SSH as well.

  It also configures an execution point so you can use `ssh` command
  to execute one-off Elixir code within IEx on the device and get the
  result back:

  ```sh
  $ ssh nerves.local "MyModule.hello()"
  :world
  ```
  """
  use GenServer

  require Logger

  @default_subsystems [
    :ssh_sftpd.subsystem_spec(cwd: '/'),
    NervesFirmwareSSH2.subsystem_spec(subsystem: 'nerves_firmware_ssh')
  ]

  @default_system_dir "/etc/ssh"

  defmodule State do
    defstruct autostart: true, opts: [], port: nil, sshd: nil, sshd_ref: nil
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec enable :: Supervisor.on_start_child()
  def enable(opts \\ []) do
    GenServer.call(__MODULE__, {:enable, opts})
  end

  @spec disable :: :ok | {:error, any}
  def disable() do
    GenServer.call(__MODULE__, :disable)
  end

  def system_dir(opts \\ []) do
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

  @impl true
  def init(opts) do
    # Prefer supplieed opts, default to application env
    {autostart, opts} =
      Application.get_all_env(:nerves_ssh)
      |> Keyword.merge(opts)
      |> Keyword.pop(:autostart, true)

    {:ok, %State{opts: opts, autostart: autostart}, {:continue, :maybe_autostart}}
  end

  @impl true
  def handle_call({:enable, opts}, _from, %{opts: initial_opts} = state) do
    {force?, opts} =
      Keyword.merge(initial_opts, opts)
      |> Keyword.pop(:force, false)

    case start_daemon(%{state | opts: opts}, force?) do
      {:error, _} = err -> {:reply, err, state}
      new_state -> {:reply, new_state.sshd, new_state}
    end
  end

  def handle_call(:disable, _from, state) do
    case stop_daemon(state) do
      {:error, _} = err -> {:reply, err, state}
      new_state -> {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_continue(:maybe_autostart, %{autostart: true} = state) do
    case start_daemon(state) do
      {:error, reason} -> {:stop, reason}
      new_state -> {:noreply, new_state}
    end
  end

  def handle_continue(:maybe_autostart, state) do
    Logger.info("[NervesSSH] skipped starting sshd")
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _sshd, reason}, state) do
    Logger.warn("[NervesSSH] sshd crashed: #{inspect(reason)}")

    # force the ssh daemon to start with our options again
    case start_daemon(state, true) do
      {:error, reason} ->
        Logger.error("[NervesSSH] failed to restart sshd: #{inspect(reason)}")
        {:stop, reason}

      new_state ->
        {:noreply, new_state}
    end
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

  def get_port(opts \\ []) do
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
      {:subsystems, subsystems(opts)}
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
