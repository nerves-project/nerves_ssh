defmodule NervesSSH.MixProject do
  use Mix.Project

  def project do
    [
      app: :nerves_ssh,
      version: "0.1.0",
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssh],
      mod: {NervesSSH.Application, []}
    ]
  end

  defp deps do
    [

    ]
  end
end
