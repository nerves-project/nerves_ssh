defmodule NervesSSH.Application do
  @moduledoc false

  use Application

  def start(_type, _args) do
    children = [NervesSSH]

    opts = [strategy: :one_for_one, name: NervesSSH.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
