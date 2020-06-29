defmodule NervesSSH do
  @moduledoc File.read!("README.md")
             |> String.split("## Usage")
             |> Enum.fetch!(1)

  @doc """
  Read the configuration options
  """
  @spec configuration :: NervesSSH.Options.t()
  defdelegate configuration(), to: NervesSSH.Daemon

  @doc """
  Return information on the running ssh daemon.

  See [ssh.daemon_info/1](http://erlang.org/doc/man/ssh.html#daemon_info-1).
  """
  @spec info() :: {:ok, [:ssh.daemon_info_tuple()]} | {:error, :bad_daemon_ref}
  defdelegate info(), to: NervesSSH.Daemon
end
