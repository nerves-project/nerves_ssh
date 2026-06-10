# SPDX-FileCopyrightText: 2026 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesSSH.SubsystemSh do
  @moduledoc """
  PROTOTYPE: SSH subsystem that connects clients to an interactive Unix shell

  This bridges the raw SSH channel byte stream to a shell running on a
  pseudo-terminal via a small C port program (`c_src/pty_bridge.c`). Since the
  shell gets a real controlling tty, its own line editing, tab completion, and
  signal generation (ctrl+c -> SIGINT, etc.) work normally.

  Build the bridge first:

      make -C c_src

  Register the subsystem in the daemon options:

      subsystems: [NervesSSH.SubsystemSh.subsystem_spec()]

  Then connect with:

      ssh -tt -s -p 4022 device sh

  The `-tt` matters. It makes the OpenSSH client put the local terminal in
  raw mode and pass keystrokes through unbuffered. Without it, your local
  terminal line-buffers input and nothing interactive works.

  Known prototype limitation: the initial `pty-req` from the client appears
  to be consumed by the channel that OTP's ssh starts for it, not this
  subsystem, so the shell starts at 80x24 with TERM from `subsystem_spec/1`
  options. `window-change` events do arrive here, so resizing the terminal
  window once after connecting syncs everything up.
  """

  @behaviour :ssh_server_channel

  require Logger

  # Max payload per {packet, 2} frame, minus slack for the type byte
  @bridge_max_frame 65_000

  @doc """
  Return the subsystem spec for this subsystem

  Options:

  * `:shell` - absolute path of the shell to run. Defaults to `"/bin/sh"`
  * `:term` - value for the TERM environment variable. Defaults to `"xterm"`
  """
  @spec subsystem_spec(keyword()) :: :ssh.subsystem_spec()
  def subsystem_spec(opts \\ []) do
    {~c"sh", {__MODULE__, opts}}
  end

  @impl :ssh_server_channel
  def init(opts) do
    state = %{
      cm: nil,
      cid: nil,
      port: nil,
      shell: Keyword.get(opts, :shell, "/bin/sh"),
      term: Keyword.get(opts, :term, "xterm")
    }

    {:ok, state}
  end

  @impl :ssh_server_channel
  def handle_msg({:ssh_channel_up, cid, cm}, state) do
    state = %{state | cid: cid, cm: cm}

    case start_bridge(state) do
      {:ok, port} ->
        {:ok, %{state | port: port}}

      {:error, reason} ->
        Logger.error("[NervesSSH.SubsystemSh] #{reason}")
        _ = :ssh_connection.send(cm, cid, "NervesSSH.SubsystemSh: #{reason}\r\n")
        {:stop, cid, state}
    end
  end

  # Shell output -> ssh client
  def handle_msg({port, {:data, data}}, %{port: port} = state) do
    _ = :ssh_connection.send(state.cm, state.cid, data)
    {:ok, state}
  end

  # Shell exited
  def handle_msg({port, {:exit_status, status}}, %{port: port} = state) do
    _ = :ssh_connection.exit_status(state.cm, state.cid, status)
    _ = :ssh_connection.send_eof(state.cm, state.cid)
    {:stop, state.cid, %{state | port: nil}}
  end

  def handle_msg(msg, state) do
    Logger.debug("[NervesSSH.SubsystemSh] unhandled message: #{inspect(msg)}")
    {:ok, state}
  end

  # Keystrokes from the ssh client -> shell
  @impl :ssh_server_channel
  def handle_ssh_msg({:ssh_cm, cm, {:data, cid, 0, data}}, %{cm: cm, cid: cid} = state) do
    :ok = send_data(state.port, data)
    {:ok, state}
  end

  def handle_ssh_msg(
        {:ssh_cm, cm, {:window_change, cid, width, height, _pixw, _pixh}},
        %{cm: cm, cid: cid} = state
      ) do
    true = Port.command(state.port, <<1, height::16, width::16>>)
    {:ok, state}
  end

  # The pty-req usually beats the subsystem request and gets routed to the
  # CLI channel that OTP's ssh starts for it, but handle it in case it shows
  # up here.
  def handle_ssh_msg(
        {:ssh_cm, cm, {:pty, cid, want_reply, {_term, width, height, _pixw, _pixh, _modes}}},
        %{cm: cm, cid: cid} = state
      ) do
    Logger.debug("[NervesSSH.SubsystemSh] pty request: #{width}x#{height}")
    true = Port.command(state.port, <<1, height::16, width::16>>)
    :ok = :ssh_connection.reply_request(cm, want_reply, :success, cid)
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _cm, {:eof, _cid}}, state) do
    # Client stdin closed. Let the shell exit on its own.
    {:ok, state}
  end

  def handle_ssh_msg(msg, state) do
    Logger.debug("[NervesSSH.SubsystemSh] unhandled ssh message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl :ssh_server_channel
  def terminate(_reason, state) do
    # Closing the port EOFs the bridge, which HUPs the shell
    if state.port, do: close_port(state.port)
    :ok
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  catch
    # Port already closed
    _, _ -> :ok
  end

  defp start_bridge(state) do
    bridge = Application.app_dir(:nerves_ssh, ["priv", "pty_bridge"])

    if File.exists?(bridge) do
      port =
        Port.open({:spawn_executable, bridge}, [
          {:packet, 2},
          :binary,
          :exit_status,
          {:args, [state.shell]},
          {:env, [{~c"TERM", to_charlist(state.term)}]}
        ])

      {:ok, port}
    else
      {:error, "pty bridge not found at #{bridge}. Run: make -C c_src && mix compile"}
    end
  end

  defp send_data(port, data) when byte_size(data) <= @bridge_max_frame do
    true = Port.command(port, [0, data])
    :ok
  end

  defp send_data(port, <<chunk::binary-size(@bridge_max_frame), rest::binary>>) do
    true = Port.command(port, [0, chunk])
    send_data(port, rest)
  end
end
