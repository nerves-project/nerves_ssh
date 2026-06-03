# SPDX-FileCopyrightText: 2025 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesSSH.TerminalCapabilities.Registry do
  @moduledoc """
  Stores per-connection terminal capabilities.

  Capabilities are keyed by the SSH session's group leader pid (the Erlang
  `group` process that backs the pty). Code running inside an SSH session shares
  that group leader, so it can look its own capabilities up with
  `NervesSSH.TerminalCapabilities.get/0`.

  The group leader is monitored so that the entry is removed automatically when
  the session ends.
  """

  use GenServer

  @table __MODULE__

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Store capabilities for the given group leader and monitor it for cleanup.
  """
  @spec track(pid(), struct()) :: :ok
  def track(group_leader, caps) when is_pid(group_leader) do
    GenServer.cast(__MODULE__, {:track, group_leader, caps})
  end

  @doc """
  Look up the capabilities for a group leader. Returns `nil` if unknown or if
  the registry isn't running.
  """
  @spec lookup(pid()) :: struct() | nil
  def lookup(group_leader) when is_pid(group_leader) do
    case :ets.whereis(@table) do
      :undefined ->
        nil

      tid ->
        case :ets.lookup(tid, group_leader) do
          [{^group_leader, caps}] -> caps
          [] -> nil
        end
    end
  end

  @impl GenServer
  def init(_opts) do
    table = :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{table: table, monitors: %{}}}
  end

  @impl GenServer
  def handle_cast({:track, group_leader, caps}, state) do
    :ets.insert(@table, {group_leader, caps})

    monitors =
      Map.put_new_lazy(state.monitors, group_leader, fn ->
        Process.monitor(group_leader)
      end)

    {:noreply, %{state | monitors: monitors}}
  end

  @impl GenServer
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.delete(@table, pid)
    {:noreply, %{state | monitors: Map.delete(state.monitors, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
