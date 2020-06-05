defmodule NervesSSH.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nerves-project/nerves_ssh"

  def project do
    [
      app: :nerves_ssh,
      version: @version,
      elixir: "~> 1.7",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      dialyzer: dialyzer(),
      docs: docs(),
      package: package(),
      preferred_cli_env: %{
        docs: :docs,
        "hex.publish": :docs,
        "hex.build": :docs
      }
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
      {:dialyxir, "~> 1.0.0", only: :dev, runtime: false},
      {:ex_doc, "~> 0.22", only: :docs, runtime: false},
      {:nerves_firmware_ssh2, github: "jjcarstens/nerves_firmware_ssh2", branch: "spec-fix"}
    ]
  end

  defp description do
    "Manage a SSH daemon and subsystems on Nerves devices"
  end

  defp dialyzer() do
    [
      flags: [:race_conditions, :unmatched_returns, :error_handling, :underspecs],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp docs do
    [
      extras: ["README.md", "CHANGELOG.md"],
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      skip_undefined_reference_warnings_on: ["CHANGELOG.md"]
    ]
  end

  defp package do
    %{
      files: ["CHANGELOG.md", "lib", "LICENSE", "mix.exs", "priv", "README.md"],
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    }
  end
end
