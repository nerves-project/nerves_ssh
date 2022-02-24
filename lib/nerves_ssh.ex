defmodule NervesSSH do
  @moduledoc File.read!("README.md")
             |> String.split("## Usage")
             |> Enum.fetch!(1)

  use GenServer

  alias NervesSSH.Options

  require Logger

  # In the very rare event that the Erlang ssh daemon crashes, give the system
  # some time to recover.
  @cool_off_time 500

  @dialyzer [{:no_opaque, handle_continue: 2}]

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
  def start_link(%Options{} = opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Read the configuration options
  """
  @spec configuration :: Options.t()
  def configuration() do
    GenServer.call(__MODULE__, :configuration)
  end

  @doc """
  Return information on the running ssh daemon.

  See [ssh.daemon_info/1](http://erlang.org/doc/man/ssh.html#daemon_info-1).
  """
  @spec info() :: {:ok, keyword()} | {:error, :bad_daemon_ref}
  def info() do
    GenServer.call(__MODULE__, :info)
  end

  @doc """
  Add an SSH public key to the authorized keys

  This will also attempt to save the key in `{USER_DIR}/authorized_keys`
  """
  @spec add_authorized_key(String.t()) :: :ok
  def add_authorized_key(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:add_authorized_key, key})
  end

  @doc """
  Remove an SSH public key from the authorized keys

  This will also attempt to remove the key in `{USER_DIR}/authorized_keys`
  """
  @spec remove_authorized_key(String.t()) :: :ok
  def remove_authorized_key(key) when is_binary(key) do
    GenServer.call(__MODULE__, {:remove_authorized_key, key})
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
    state =
      update_in(state.opts, &Options.load_authorized_keys/1)
      |> try_save_authorized_keys()

    daemon_options = Options.daemon_options(state.opts)

    # Handle the case where we're restarted and terminate/2 wasn't called to
    # stop the ssh daemon. This should be very rare, but it happens since we
    # can't link to the ssh daemon and take it down when we go down (it already
    # has a link). This is harmless if the server isn't running.
    _ = :ssh.stop_daemon(:any, state.opts.port, :default)

    case :ssh.daemon(state.opts.port, daemon_options) do
      {:ok, sshd} ->
        {:noreply, %{state | sshd: sshd, sshd_ref: Process.monitor(sshd)}}

      error ->
        Logger.error("[NervesSSH] :ssd.daemon failed: #{inspect(error)}")
        Process.sleep(@cool_off_time)

        {:stop, {:ssh_daemon_error, error}, state}
    end
  end

  @impl true
  def handle_call(:configuration, _from, state) do
    {:reply, state.opts, state}
  end

  def handle_call(:info, _from, state) do
    {:reply, :ssh.daemon_info(state.sshd), state}
  end

  def handle_call({fun, key}, _from, state)
      when fun in [:add_authorized_key, :remove_authorized_key] do
    state =
      update_in(state.opts, &apply(Options, fun, [&1, key]))
      |> try_save_authorized_keys()

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _sshd, reason}, state) do
    Logger.warn(
      "[NervesSSH] sshd #{inspect(state.sshd)} crashed: #{inspect(reason)}. Restarting after delay."
    )

    Process.sleep(@cool_off_time)

    {:stop, {:ssh_crashed, reason}, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.error("[NervesSSH] terminating with reason: #{inspect(reason)}")

    # NOTE: we can't link to the SSH daemon process, so we must manually stop
    # it if we terminate. terminate/2 is not guaranteed to be called, so it's
    # possible that this is not called.
    :ssh.stop_daemon(state.sshd)
  end

  defp try_save_authorized_keys(state) do
    case Options.save_authorized_keys(state.opts) do
      :ok ->
        state

      error ->
        Logger.warn("[NervesSSH] Failed to save authorized_keys file: #{inspect(error)}")
        state
    end
  end
end
