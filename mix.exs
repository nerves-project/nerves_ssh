defmodule NervesSSH.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nerves-project/nerves_ssh"

  def project do
    [
      app: :nerves_ssh,
      version: @version,
      elixir: "~> 1.9",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      docs: docs()
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
      {:ex_doc, "~> 0.22", only: :docs},
      {:nerves_firmware_ssh2, github: "fhunleth/nerves_firmware_ssh2"}
    ]
  end

  defp docs do
    [
      extras: ["README.md"],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
