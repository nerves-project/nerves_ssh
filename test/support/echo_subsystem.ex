# SPDX-FileCopyrightText: 2025 Ben Youngblood
# SPDX-FileCopyrightText: 2025 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Support.EchoSubsystem do
  @moduledoc false

  @behaviour :ssh_client_channel

  @impl :ssh_client_channel
  def init(opts) do
    {:ok, %{id: nil, cm: nil, prefix: opts[:prefix] || ""}}
  end

  @impl :ssh_client_channel
  def handle_msg({:ssh_channel_up, channel_id, cm}, state) do
    {:ok, %{state | id: channel_id, cm: cm}}
  end

  @impl :ssh_client_channel
  def handle_ssh_msg({:ssh_cm, _cm, {:data, _channel_id, type, data}}, state) do
    # Echo back the data received
    :ssh_connection.send(state.cm, state.id, type, state.prefix <> data)
    {:ok, state}
  end

  @impl :ssh_client_channel
  def handle_call(_request, _from, state) do
    {:reply, :ok, state}
  end

  @impl :ssh_client_channel
  def handle_cast(_request, state) do
    {:noreply, state}
  end

  @impl :ssh_client_channel
  def code_change(_oldVsn, state, _extra) do
    {:ok, state}
  end

  @impl :ssh_client_channel
  def terminate(_reason, _state) do
    :ok
  end
end
