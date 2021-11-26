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
  def is_auth_key(key, _user, options) do
    # Grab the decoded authorized keys from the options
    cb_opts = Keyword.get(options, :key_cb_private)
    keys = Keyword.get(cb_opts, :authorized_keys)

    # If any of them match, then we're good.
    Enum.any?(keys, fn {k, _info} -> k == key end)
  end
end
