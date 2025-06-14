defmodule NervesSSH.MixProject do
  use Mix.Project

  @version "1.1.0"
  @source_url "https://github.com/nerves-project/nerves_ssh"

  def project do
    [
      app: :nerves_ssh,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      dialyzer: dialyzer(),
      docs: docs(),
      package: package()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :public_key, :ssh],
      mod: {NervesSSH.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: %{
        dialyzer: :dialyzer,
        docs: :docs,
        "hex.publish": :docs,
        "hex.build": :docs,
        credo: :test
      }
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:dialyxir, "~> 1.4", only: :dialyzer, runtime: false},
      {:ex_doc, "~> 0.22", only: :docs, runtime: false},
      {:ssh_subsystem_fwup, "~> 0.5"},
      {:nerves_runtime, "~> 0.11"},
      # lfe currently requires `compile: "make"` to build and this is
      # disallowed when pushing the package to hex.pm.  Work around this by
      # listing it as dev/test only.
      {:lfe, "~> 2.0", only: [:dev, :test], compile: "make", optional: true},
      {:sshex, "~> 2.2.1", only: [:dev, :test]},
      {:credo, "~> 1.2", only: :test, runtime: false}
    ]
  end

  defp description do
    "Manage a SSH daemon and subsystems on Nerves devices"
  end

  defp dialyzer() do
    [
      flags: [:missing_return, :extra_return, :unmatched_returns, :error_handling, :underspecs]
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
      files: [
        "CHANGELOG.md",
        "lib",
        "LICENSES/*",
        "mix.exs",
        "NOTICE",
        "README.md",
        "REUSE.toml"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "REUSE Compliance" =>
          "https://api.reuse.software/info/github.com/nerves-project/nerves_ssh"
      }
    }
  end
end
