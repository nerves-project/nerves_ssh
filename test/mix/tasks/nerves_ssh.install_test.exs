# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
# Igniter requires Elixir 1.15 or later
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.NervesSsh.InstallTest do
    use ExUnit.Case, async: true

    import Igniter.Test

    @expected_block """
    # Configure the device for SSH IEx prompt access and firmware updates
    #
    # * See https://nerves-ssh.hexdocs.pm/readme.html for general SSH configuration
    # * See https://ssh-subsystem-fwup.hexdocs.pm/readme.html for firmware updates

    keys =
      System.user_home!()
      |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
      |> Path.wildcard()

    if keys == [],
      do:
        Mix.raise(\"""
        No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
        log into the Nerves device and update firmware on it using ssh.
        See your project's config/target.exs for this error message.
        \""")

    config :nerves_ssh,
      authorized_keys: Enum.map(keys, &File.read!/1)
    """

    # What `mix nerves.new` generates minus the nerves_ssh section
    @target_exs """
    import Config

    # Advance the system clock on devices without a real-time clock.
    config :nerves, :erlinit, update_clock: true

    config :mdns_lite,
      hosts: [:hostname, "nerves"],
      ttl: 120

    # Import target specific config. This must remain at the bottom
    # of this file so it overrides the configuration defined above.
    # Uncomment to use target specific configurations

    # import_config "\#{Mix.target()}.exs"
    """

    defp install(igniter, argv \\ []) do
      Igniter.compose_task(igniter, "nerves_ssh.install", argv)
    end

    defp content(igniter, path) do
      igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
    end

    describe "Nerves project" do
      test "adds the authorized keys setup to config/target.exs" do
        igniter =
          test_project(files: %{"config/target.exs" => @target_exs})
          |> install()
          |> assert_unchanged("config/config.exs")
          |> assert_has_notice(&(&1 =~ "config/target.exs now reads your public SSH keys"))
          |> apply_igniter!()

        result = content(igniter, "config/target.exs")

        assert result =~ @expected_block
        # Existing content and comments are kept
        assert result =~ "config :nerves, :erlinit, update_clock: true"
        assert result =~ ~s|# import_config "\#{Mix.target()}.exs"|
      end

      test "the generated configuration is valid and reads the keys in ~/.ssh" do
        igniter =
          test_project(files: %{"config/target.exs" => "import Config\n"})
          |> install()
          |> apply_igniter!()

        path =
          Path.join(System.tmp_dir!(), "nerves_ssh_install_#{System.unique_integer([:positive])}")

        home = Path.join(path, "home")
        File.mkdir_p!(Path.join(home, ".ssh"))
        File.write!(Path.join(path, "target.exs"), content(igniter, "config/target.exs"))
        File.write!(Path.join(home, ".ssh/id_ed25519.pub"), "ssh-ed25519 AAAA test\n")
        File.write!(Path.join(home, ".ssh/id_ed25519"), "not a public key")
        on_exit(fn -> File.rm_rf!(path) end)

        # Config.Reader runs in this VM, so HOME can't be changed safely.
        # Run it in a separate one instead.
        script = """
        [path] = System.argv()
        IO.puts(inspect(Config.Reader.read!(path)))
        """

        run = fn ->
          System.cmd("elixir", ["-e", script, Path.join(path, "target.exs")],
            env: [{"HOME", home}],
            stderr_to_stdout: true
          )
        end

        assert {output, 0} = run.()
        assert output =~ ~s([nerves_ssh: [authorized_keys: ["ssh-ed25519 AAAA test\\n"]]])

        File.rm!(Path.join(home, ".ssh/id_ed25519.pub"))
        assert {output, status} = run.()
        assert status != 0
        assert output =~ "No SSH public keys found in ~/.ssh"
      end

      test "is idempotent" do
        test_project(files: %{"config/target.exs" => @target_exs})
        |> install()
        |> apply_igniter!()
        |> install()
        |> assert_unchanged()
      end

      test "adds the setup before import_config" do
        target_exs = """
        import Config

        config :nerves, :erlinit, update_clock: true

        # Must remain at the bottom
        import_config "\#{Mix.target()}.exs"
        """

        igniter =
          test_project(files: %{"config/target.exs" => target_exs})
          |> install()
          |> apply_igniter!()

        result = content(igniter, "config/target.exs")
        assert result =~ @expected_block

        assert String.ends_with?(result, """
                 authorized_keys: Enum.map(keys, &File.read!/1)

               # Must remain at the bottom
               import_config "\#{Mix.target()}.exs"
               """)
      end

      test "doesn't reuse a keys variable that is already in the file" do
        target_exs = """
        import Config

        keys = [:a, :b]

        config :my_app, keys: keys
        """

        igniter =
          test_project(files: %{"config/target.exs" => target_exs})
          |> install()
          |> apply_igniter!()

        result = content(igniter, "config/target.exs")

        assert result =~ "keys = [:a, :b]"
        assert result =~ "nerves_ssh_keys =\n  System.user_home!()"
        assert result =~ "if nerves_ssh_keys == [],"
        assert result =~ "authorized_keys: Enum.map(nerves_ssh_keys, &File.read!/1)"
      end
    end

    describe "existing configuration" do
      test "is preserved in config/target.exs" do
        target_exs = """
        import Config

        config :nerves_ssh,
          authorized_keys: [File.read!("priv/device.pub")],
          port: 2222
        """

        test_project(files: %{"config/target.exs" => target_exs})
        |> install()
        |> assert_unchanged()
      end

      test "is preserved when using username/password authentication" do
        target_exs = """
        import Config

        config :nerves_ssh, user_passwords: [{"me", System.fetch_env!("SSH_PASSWORD")}]
        """

        test_project(files: %{"config/target.exs" => target_exs})
        |> install()
        |> assert_unchanged()
      end

      test "is detected in a nested block" do
        target_exs = """
        import Config

        if Mix.target() != :host do
          config :nerves_ssh, :authorized_keys, []
        end
        """

        test_project(files: %{"config/target.exs" => target_exs})
        |> install()
        |> assert_unchanged()
      end

      test "is detected in other config files" do
        for file <- ["config/config.exs", "config/runtime.exs"] do
          files = %{
            "config/target.exs" => "import Config\n",
            file => """
            import Config

            config :nerves_ssh, port: 2222
            """
          }

          test_project(files: files)
          |> install()
          |> assert_unchanged()
        end
      end
    end

    describe "plain project" do
      test "falls back to config/config.exs with a notice" do
        igniter =
          test_project()
          |> install()
          |> refute_creates("config/target.exs")
          |> assert_has_notice(&(&1 =~ "no config/target.exs was found"))
          |> apply_igniter!()

        result = content(igniter, "config/config.exs")

        assert result =~
                 String.replace(@expected_block, "config/target.exs", "config/config.exs")

        assert String.starts_with?(result, "import Config\n")
      end

      test "keeps import_config last in config/config.exs" do
        config_exs = """
        import Config

        config :logger, level: :info

        import_config "\#{config_env()}.exs"
        """

        igniter =
          test_project(files: %{"config/config.exs" => config_exs})
          |> install()
          |> apply_igniter!()

        result = content(igniter, "config/config.exs")

        assert result =~ "config :logger, level: :info\n\n# Configure the device for SSH"

        assert String.ends_with?(result, """
                 authorized_keys: Enum.map(keys, &File.read!/1)

               import_config "\#{config_env()}.exs"
               """)
      end

      test "is idempotent" do
        test_project()
        |> install()
        |> apply_igniter!()
        |> install()
        |> assert_unchanged()
      end
    end

    describe "starting early" do
      test "adds :nerves_ssh to Nerves' application_sort init list" do
        target_exs = """
        import Config

        config :nerves, application_sort: [init: [:nerves_runtime]]
        """

        test_project(files: %{"config/target.exs" => target_exs})
        |> install()
        |> assert_has_patch("config/target.exs", """
        - |config :nerves, application_sort: [init: [:nerves_runtime]]
        + |config :nerves, application_sort: [init: [:nerves_runtime, :nerves_ssh]]
        """)
        |> apply_igniter!()
        |> install()
        |> assert_unchanged()
      end

      test "what mix nerves.install generates ends up like the mix nerves.new template" do
        target_exs = """
        import Config

        config :nerves, application_sort: [init: [:nerves_runtime]]

        # Import target specific config. This must remain at the bottom
        # of this file so it overrides the configuration defined above.
        # Uncomment to use target specific configurations

        # import_config "\#{Mix.target()}.exs"
        """

        igniter =
          test_project(files: %{"config/target.exs" => target_exs})
          |> install()
          |> apply_igniter!()

        assert content(igniter, "config/target.exs") == """
               import Config

               config :nerves, application_sort: [init: [:nerves_runtime, :nerves_ssh]]

               #{String.trim_trailing(@expected_block)}

               # Import target specific config. This must remain at the bottom
               # of this file so it overrides the configuration defined above.
               # Uncomment to use target specific configurations

               # import_config "\#{Mix.target()}.exs"
               """
      end

      test "adds :nerves_ssh to shoehorn's init list" do
        config_exs = """
        import Config

        config :shoehorn, init: [:nerves_runtime, :vintage_net]

        config :nerves_ssh, authorized_keys: []
        """

        test_project(files: %{"config/config.exs" => config_exs})
        |> install()
        |> assert_has_patch("config/config.exs", """
        - |config :shoehorn, init: [:nerves_runtime, :vintage_net]
        + |config :shoehorn, init: [:nerves_runtime, :vintage_net, :nerves_ssh]
        """)
      end

      test "leaves the init list alone when it has :nerves_pack or :nerves_ssh" do
        for apps <- ["[:nerves_runtime, :nerves_pack]", "[:nerves_ssh, :nerves_runtime]"] do
          target_exs = """
          import Config

          config :nerves, application_sort: [init: #{apps}]

          config :nerves_ssh, authorized_keys: []
          """

          test_project(files: %{"config/target.exs" => target_exs})
          |> install()
          |> assert_unchanged()
        end
      end

      test "leaves an init list that isn't a literal list alone" do
        target_exs = """
        import Config

        early = [:nerves_runtime]
        config :nerves, application_sort: [init: early]

        config :nerves_ssh, authorized_keys: []
        """

        test_project(files: %{"config/target.exs" => target_exs})
        |> install()
        |> assert_unchanged()
      end

      test "doesn't create an init list" do
        igniter =
          test_project(files: %{"config/target.exs" => @target_exs})
          |> install()
          |> apply_igniter!()

        refute content(igniter, "config/target.exs") =~ "application_sort"
        refute content(igniter, "config/target.exs") =~ "shoehorn"
      end
    end

    describe "--ssh-username" do
      test "sets up password login instead of public keys" do
        igniter =
          test_project(files: %{"config/target.exs" => @target_exs})
          |> install(["--ssh-username", "admin"])

        target = content(igniter, "config/target.exs")
        assert target =~ ~s|System.get_env("NERVES_SSH_PASSWORD", "")|
        assert target =~ ~s|[{"admin", ssh_password}]|
        refute target =~ "authorized_keys"
        refute target =~ "No SSH public keys found"
      end

      test "--ssh-password-env names the variable" do
        igniter =
          test_project(files: %{"config/target.exs" => @target_exs})
          |> install(["--ssh-username", "admin", "--ssh-password-env", "MY_PW"])

        assert content(igniter, "config/target.exs") =~ ~s|System.get_env("MY_PW", "")|
      end

      test "is idempotent" do
        test_project(files: %{"config/target.exs" => @target_exs})
        |> install(["--ssh-username", "admin"])
        |> apply_igniter!()
        |> install(["--ssh-username", "admin"])
        |> assert_unchanged()
      end

      test "public keys stay the default" do
        igniter = test_project(files: %{"config/target.exs" => @target_exs}) |> install()

        target = content(igniter, "config/target.exs")
        assert target =~ "authorized_keys"
        refute target =~ "user_passwords"
      end
    end

    test "never writes key material or passwords" do
      igniter =
        test_project(files: %{"config/target.exs" => @target_exs})
        |> install()
        |> apply_igniter!()

      result = content(igniter, "config/target.exs")

      refute result =~ "ssh-rsa"
      refute result =~ "ssh-ed25519"
      refute result =~ "user_passwords"
    end

    describe "restricting the dependency to the project's targets" do
      defp targets_mix_exs(deps) do
        """
        defmodule Test.MixProject do
          use Mix.Project

          @app :test
          @device_targets [:rpi4, :rpi5]
          @other_targets [:bbb]

          def project do
            [app: @app, version: "0.1.0", deps: deps()]
          end

          defp deps do
            [
              {:nerves, "~> 2.0", runtime: false},
              #{Enum.join(deps, ",\n      ")}
            ]
          end
        end
        """
      end

      defp targets_install(deps) do
        test_project(
          files: %{"mix.exs" => targets_mix_exs(deps), "config/target.exs" => "import Config\n"}
        )
        |> Igniter.compose_task("nerves_ssh.install", [])
      end

      defp targets_mix_exs_after(igniter) do
        igniter.rewrite |> Rewrite.source!("mix.exs") |> Rewrite.Source.get(:content)
      end

      test "uses the first targets attribute that another dependency uses" do
        igniter =
          targets_install([
            ~s|{:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4}|,
            ~s|{:nerves_pack, "~> 0.7", targets: @device_targets}|,
            ~s|{:other, "~> 1.0", targets: @other_targets}|,
            ~s|{:nerves_ssh, "~> 1.0"}|
          ])

        assert targets_mix_exs_after(igniter) =~
                 ~s|{:nerves_ssh, "~> 1.0", targets: @device_targets}|

        # Running it again changes nothing
        igniter
        |> apply_igniter!()
        |> Igniter.compose_task("nerves_ssh.install", [])
        |> assert_unchanged("mix.exs")
      end

      test "works for dependencies that only have options" do
        igniter =
          targets_install([
            ~s|{:nerves_pack, "~> 0.7", targets: @device_targets}|,
            ~s|{:nerves_ssh, path: "../nerves_ssh"}|
          ])

        assert targets_mix_exs_after(igniter) =~
                 ~s|{:nerves_ssh, path: "../nerves_ssh", targets: @device_targets}|
      end

      test "keeps the targets that the dependency already has" do
        targets_install([
          ~s|{:nerves_pack, "~> 0.7", targets: @device_targets}|,
          ~s|{:nerves_ssh, "~> 1.0", targets: [:rpi0]}|
        ])
        |> assert_unchanged("mix.exs")
      end

      test "does nothing when no dependency uses a targets attribute" do
        targets_install([
          ~s|{:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4}|,
          ~s|{:nerves_ssh, "~> 1.0"}|
        ])
        |> assert_unchanged("mix.exs")
      end

      test "falls back to @all_targets when it's defined but not used by a dependency" do
        mix_exs = """
        defmodule Test.MixProject do
          use Mix.Project

          @all_targets [:rpi4, :rpi5]

          def project do
            [app: :test, version: "0.1.0", deps: deps()]
          end

          defp deps do
            [
              {:nerves_system_rpi4, "~> 2.0", runtime: false, targets: :rpi4},
              {:nerves_ssh, "~> 1.0"}
            ]
          end
        end
        """

        igniter =
          test_project(files: %{"mix.exs" => mix_exs, "config/target.exs" => "import Config\n"})
          |> Igniter.compose_task("nerves_ssh.install", [])

        assert targets_mix_exs_after(igniter) =~
                 ~s|{:nerves_ssh, "~> 1.0", targets: @all_targets}|
      end

      test "does nothing when the dependency isn't in mix.exs" do
        targets_install([~s|{:nerves_pack, "~> 0.7", targets: @device_targets}|])
        |> assert_unchanged("mix.exs")
      end
    end
  end
end
