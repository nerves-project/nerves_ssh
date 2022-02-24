defmodule NervesSSH.Keys do
  @moduledoc false
  @behaviour :ssh_server_key_api

  @impl :ssh_server_key_api
  def host_key(algorithm, options) do
    case options[:key_cb_private][:host_keys] do
      %{^algorithm => key} -> {:ok, key}
      _ -> {:error, :enoent}
    end
  end

  @impl :ssh_server_key_api
  def is_auth_key(key, _user, _options) do
    # If any of them match, then we're good.
    Enum.member?(NervesSSH.configuration().decoded_authorized_keys, key)
  end
end
