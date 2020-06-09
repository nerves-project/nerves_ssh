defmodule NervesSSH.Daemon do
  use GenServer

  alias NervesSSH.Options

  require Logger

  @type opt ::
          {:authorized_keys, [String.t()]}
          | {:port, non_neg_integer()}
          | {:subsystems, [:ssh.subsystem_spec()]}
          | {:system_dir, Path.t()}

  @dialyzer [{:no_opaque, start_daemon: 3}]

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            opts: Options.t(),
            sshd: pid(),
            sshd_ref: reference()
          }

    defstruct opts: [], sshd: nil, sshd_ref: nil
  end

  @doc false
  @spec start_link(Options.t()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Read the configuration options
  """
  @spec configuration :: Options.t()
  def configuration() do
    GenServer.call(__MODULE__, :configuration)
  end

  @impl true
  def init(opts) do
    # Make sure we can attempt SSH daemon cleanup if
    # NervesSSH application gets shutdown
    Process.flag(:trap_exit, true)

    {:ok, %State{opts: opts}, {:continue, :start_daemon}}
  end

  @impl true
  def handle_continue(:start_daemon, state) do
    case start_daemon(state) do
      {:error, reason} -> {:stop, reason, state}
      new_state -> {:noreply, new_state}
    end
  end

  @impl true
  def handle_call(:configuration, _from, state) do
    {:reply, state.opts, state}
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

  @spec start_daemon(State.t(), boolean(), non_neg_integer()) :: map() | {:error, any()}
  defp start_daemon(state, force \\ false, attempt \\ 1)

  defp start_daemon(state, _force, attempt) when attempt > 10 do
    {:error, "failed to start ssh daemon on #{state.opts[:port]} after 10 attempts"}
  end

  defp start_daemon(%{opts: opts} = state, force?, attempt) do
    daemon_options = Options.daemon_options(opts)

    case {:ssh.daemon(opts.port, daemon_options), force?} do
      {{:ok, sshd}, _} ->
        %{state | sshd: sshd, sshd_ref: Process.monitor(sshd)}

      {{:error, :eaddrinuse}, _force = true} ->
        with %{} = state <- stop_daemon(state), do: start_daemon(state, force?, attempt + 1)

      {{:error, :eaddrinuse}, _no_force} ->
        {:error, {:eaddrinuse, state.sshd}}

      {err, _} ->
        err
    end
  end

  @spec stop_daemon(map(), non_neg_integer()) :: map() | {:error, any()}
  defp stop_daemon(state, attempt \\ 1)

  defp stop_daemon(_state, attempt) when attempt > 10 do
    {:error, "failed to stop ssh daemon after 10 attempts"}
  end

  defp stop_daemon(state, attempt) do
    port = state.opts.port

    if state.sshd_ref, do: Process.demonitor(state.sshd_ref)

    if is_pid(state.sshd),
      do: :ssh.stop_daemon(state.sshd),
      else: :ssh.stop_daemon(:any, port, :default)

    # Apparently there is a bug in erlang ssh where tcp socket can remain
    # open even when the daemon crashes/doesn't start, so we forcibly search
    # for a socket using our port and close it
    #
    # Based on https://github.com/se-apc/sshd/blob/master/lib/sshd.ex#L383-L384
    Port.list()
    |> Enum.filter(&ssh_daemon_socket?(&1, port))
    |> Enum.each(&:gen_tcp.close(&1))

    if is_pid(state.sshd) and Process.alive?(state.sshd) do
      # Failed to stop so let's keep trying
      stop_daemon(state, attempt + 1)
    else
      %{state | sshd: nil, sshd_ref: nil}
    end
  end

  defp ssh_daemon_socket?(s, port) do
    case :prim_inet.sockname(s) do
      {:ok, {{0, 0, 0, 0}, ^port}} -> true
      {:ok, {{0, 0, 0, 0, 0, 0, 0, 0}, ^port}} -> true
      _anything_else -> false
    end
  end
end
