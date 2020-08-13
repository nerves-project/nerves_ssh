defmodule NervesSSH.Application do
  @moduledoc false

  use Application

  alias NervesSSH.Options

  @impl Application
  def start(_type, _args) do
    children =
      case Application.get_all_env(:nerves_ssh) do
        [] ->
          # No app environment, so don't start
          []

        app_env ->
          [{NervesSSH, Options.with_defaults(app_env)}]
      end

    opts = [strategy: :one_for_one, name: NervesSSH.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
