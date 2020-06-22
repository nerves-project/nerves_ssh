defmodule NervesSSH do
  @moduledoc File.read!("README.md")
             |> String.split("## Usage")
             |> Enum.fetch!(1)

  @doc """
  Read the configuration options
  """
  @spec configuration :: NervesSSH.Options.t()
  defdelegate configuration(), to: NervesSSH.Daemon
end
