defmodule NervesSSH.SystemShellUtils do
  @moduledoc false

  def get_shell_command() do
    cond do
      shell = System.get_env("SHELL") ->
        [shell, "-i"]

      shell = System.find_executable("sh") ->
        [shell, "-i"]

      true ->
        raise "SHELL environment variable not set and sh not available"
    end
  end

  def get_term(nil) do
    if term = System.get_env("TERM") do
      [{"TERM", term}]
    else
      [{"TERM", "xterm"}]
    end
  end

  def get_term({term, _, _, _, _, _}) when is_list(term),
    do: [{"TERM", List.to_string(term)}]
end

defmodule NervesSSH.SystemShell do
  @moduledoc """
  A `:ssh_server_channel` that uses `:erlexec` to provide an interactive system shell.
  """

  @behaviour :ssh_server_channel

  require Logger

  import NervesSSH.SystemShellUtils

  defp exec_command(cmd, %{pty_opts: pty_opts, env: env}) do
    base_opts = [
      :stdin,
      :stdout,
      :monitor,
      env: [:clear] ++ env ++ get_term(pty_opts)
    ]

    opts =
      case pty_opts do
        nil ->
          base_opts ++ [:stderr]

        {_term, _cols, _rows, _, _, opts} ->
          # https://www.erlang.org/doc/man/ssh_connection.html#type-pty_ch_msg
          # erlexec understands the format of the erlang ssh pty_ch_msg
          base_opts ++ [{:stderr, :stdout}, {:pty, opts}]
          # not yet released
          # ++ [{:winsz, {rows, cols}}]
      end

    :exec.run(cmd, opts)
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       port_pid: nil,
       os_pid: nil,
       pty_opts: nil,
       env: [],
       cid: nil,
       cm: nil
     }}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, connection_manager}, state) do
    {:ok, %{state | cid: channel_id, cm: connection_manager}}
  end

  # port closed
  def handle_msg(
        {:DOWN, os_pid, :process, port_pid, reason},
        %{os_pid: os_pid, port_pid: port_pid, cm: cm, cid: cid} = state
      ) do
    case reason do
      :normal ->
        :ssh_connection.exit_status(cm, cid, 0)

      {:exit_status, status} ->
        :ssh_connection.exit_status(cm, cid, status)
    end

    :ssh_connection.send_eof(cm, cid)
    {:stop, cid, state}
  end

  def handle_msg({:stdout, os_pid, data} = _msg, %{cm: cm, cid: cid, os_pid: os_pid} = state) do
    :ssh_connection.send(cm, cid, data)
    {:ok, state}
  end

  def handle_msg({:stderr, os_pid, data} = _msg, %{cm: cm, cid: cid, os_pid: os_pid} = state) do
    :ssh_connection.send(cm, cid, 1, data)
    {:ok, state}
  end

  def handle_msg(msg, state) do
    Logger.error("[NervesSSH.SystemShell] unhandled message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl true
  # client sent a pty request
  def handle_ssh_msg({:ssh_cm, cm, {:pty, cid, want_reply, pty_opts} = _msg}, state = %{cm: cm}) do
    :ssh_connection.reply_request(cm, want_reply, :success, cid)

    {:ok, %{state | pty_opts: pty_opts}}
  end

  # client wants to set an environment variable
  def handle_ssh_msg(
        {:ssh_cm, cm, {:env, cid, want_reply, key, value}},
        state = %{cm: cm, cid: cid}
      ) do
    :ssh_connection.reply_request(cm, want_reply, :success, cid)

    {:ok, update_in(state, [:env], fn vars -> [{key, value} | vars] end)}
  end

  # client wants to execute a command
  def handle_ssh_msg(
        {:ssh_cm, cm, {:exec, cid, want_reply, command} = _msg},
        state = %{cm: cm, cid: cid}
      )
      when is_list(command) do
    {:ok, pid, os_pid} = exec_command(List.to_string(command), state)
    :ssh_connection.reply_request(cm, want_reply, :success, cid)
    {:ok, %{state | os_pid: os_pid, port_pid: pid}}
  end

  # client requested a shell
  def handle_ssh_msg(
        {:ssh_cm, cm, {:shell, cid, want_reply} = _msg},
        state = %{cm: cm, cid: cid}
      ) do
    {:ok, pid, os_pid} = exec_command(get_shell_command(), state)
    :ssh_connection.reply_request(cm, want_reply, :success, cid)
    {:ok, %{state | os_pid: os_pid, port_pid: pid}}
  end

  def handle_ssh_msg(
        {:ssh_cm, _cm, {:data, channel_id, 0, data}},
        state = %{os_pid: os_pid, cid: channel_id}
      ) do
    :exec.send(os_pid, data)

    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:eof, _}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:signal, _, _} = _msg}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:exit_signal, channel_id, _, _error, _}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:exit_status, channel_id, _status}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg(
        {:ssh_cm, cm, {:window_change, cid, width, height, _, _} = _msg},
        state = %{os_pid: os_pid, cm: cm, cid: cid}
      ) do
    :exec.winsz(os_pid, height, width)

    {:ok, state}
  end

  def handle_ssh_msg(msg, state) do
    Logger.error("[NervesSSH.SystemShell] unhandled ssh message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end

defmodule NervesSSH.SystemShellSubsystem do
  # TODO: maybe merge this into the SystemShell module
  # but not sure yet if it's worth the effort

  @moduledoc false

  @behaviour :ssh_server_channel

  require Logger

  import NervesSSH.SystemShellUtils

  @impl true
  def init(opts) do
    # SSH subsystems do not send :exec, :shell or :pty messages
    command = Keyword.get_lazy(opts, :command, fn -> get_shell_command() end)
    force_pty = Keyword.get(opts, :force_pty, true)

    base_opts = [
      :stdin,
      :stdout,
      :monitor,
      env: get_term(nil)
    ]

    opts =
      if force_pty do
        base_opts ++ [{:stderr, :stdout}, :pty, :pty_echo]
      else
        base_opts ++ [:stderr]
      end

    {:ok, port_pid, os_pid} = :exec.run(command, opts)

    {:ok, %{os_pid: os_pid, port_pid: port_pid, cid: nil, cm: nil}}
  end

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, connection_manager}, state) do
    {:ok, %{state | cid: channel_id, cm: connection_manager}}
  end

  # port closed
  def handle_msg(
        {:DOWN, os_pid, :process, port_pid, reason},
        %{os_pid: os_pid, port_pid: port_pid, cm: cm, cid: cid} = state
      ) do
    case reason do
      :normal ->
        :ssh_connection.exit_status(cm, cid, 0)

      {:exit_status, status} ->
        :ssh_connection.exit_status(cm, cid, status)
    end

    :ssh_connection.send_eof(cm, cid)
    {:stop, cid, state}
  end

  def handle_msg({:stdout, os_pid, data}, %{os_pid: os_pid, cm: cm, cid: cid} = state) do
    :ssh_connection.send(cm, cid, data)
    {:ok, state}
  end

  def handle_msg({:stderr, os_pid, data}, %{os_pid: os_pid, cm: cm, cid: cid} = state) do
    :ssh_connection.send(cm, cid, 1, data)
    {:ok, state}
  end

  @impl true
  def handle_ssh_msg(
        {:ssh_cm, cm, {:data, cid, 0, data}},
        state = %{os_pid: os_pid, cm: cm, cid: cid}
      ) do
    :exec.send(os_pid, data)

    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:eof, _}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:signal, _, _}}, state) do
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:exit_signal, channel_id, _, _error, _}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg({:ssh_cm, _, {:exit_status, channel_id, _status}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg(
        {:ssh_cm, cm, {:window_change, cid, width, height, _, _}},
        state = %{os_pid: os_pid, cm: cm, cid: cid}
      ) do
    :exec.winsz(os_pid, height, width)

    {:ok, state}
  end

  def handle_ssh_msg(msg, state) do
    Logger.error("[NervesSSH.SystemShellSubsystem] unhandled ssh message: #{inspect(msg)}")
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end
end
