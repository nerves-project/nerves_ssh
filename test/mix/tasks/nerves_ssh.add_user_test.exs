# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
# Igniter requires Elixir 1.15 or later
if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.NervesSsh.AddUserTest do
    use ExUnit.Case, async: true

    import Igniter.Test

    # What `mix nerves.new` generates minus the nerves_ssh section
    @target_exs """
    import Config

    # Advance the system clock on devices without a real-time clock.
    config :nerves, :erlinit, update_clock: true

    # Import target specific config. This must remain at the bottom
    # of this file so it overrides the configuration defined above.
    # Uncomment to use target specific configurations

    # import_config "\#{Mix.target()}.exs"
    """

    @password_code """
    # Username and password login over SSH. The password is read from the
    # NERVES_SSH_PASSWORD environment variable when the firmware is built.
    # Firmware that is built without it doesn't accept password logins.
    ssh_password = System.get_env("NERVES_SSH_PASSWORD", "")
    """

    @user_passwords ~s|user_passwords: if(ssh_password == "", do: [], else: [{"username", ssh_password}])|

    defp install(igniter), do: Igniter.compose_task(igniter, "nerves_ssh.install", [])

    defp add_user(igniter, argv \\ []) do
      Igniter.compose_task(igniter, "nerves_ssh.add_user", argv)
    end

    defp content(igniter, path) do
      igniter.rewrite |> Rewrite.source!(path) |> Rewrite.Source.get(:content)
    end

    # Evaluates a config file like a firmware build would. Config.Reader runs
    # in the VM that calls it, so the environment can't be changed safely here.
    # A separate VM is used instead. `password` is the value of the environment
    # variable or `nil` for unset.
    defp read_config!(config, password, env \\ "NERVES_SSH_PASSWORD") do
      path =
        Path.join(System.tmp_dir!(), "nerves_ssh_add_user_#{System.unique_integer([:positive])}")

      home = Path.join(path, "home")
      File.mkdir_p!(Path.join(home, ".ssh"))
      File.write!(Path.join(path, "target.exs"), config)
      File.write!(Path.join(home, ".ssh/id_ed25519.pub"), "ssh-ed25519 AAAA test\n")

      script = """
      [path] = System.argv()
      IO.puts(inspect(Config.Reader.read!(path)[:nerves_ssh], limit: :infinity))
      """

      {output, status} =
        System.cmd("elixir", ["-e", script, Path.join(path, "target.exs")],
          env: [{"HOME", home}, {"NERVES_SSH_PASSWORD", nil}, {env, password}],
          stderr_to_stdout: true
        )

      File.rm_rf!(path)
      assert status == 0, output
      {result, _binding} = Code.eval_string(output)
      result
    end

    describe "Nerves project after nerves_ssh.install" do
      setup do
        igniter =
          test_project(files: %{"config/target.exs" => @target_exs})
          |> install()
          |> apply_igniter!()

        [igniter: igniter]
      end

      @tag :merges_config
      test "merges with the authorized keys setup in config/target.exs", %{igniter: igniter} do
        igniter =
          igniter
          |> add_user()
          |> assert_unchanged(["config/config.exs", "mix.exs"])
          |> assert_has_notice(
            &(&1 =~ ~s|config/target.exs now sets up password login for the SSH user\n"username"|)
          )
          |> apply_igniter!()

        # The end of the block that the installer added and everything after it
        assert String.ends_with?(content(igniter, "config/target.exs"), """
                   See your project's config/target.exs for this error message.
                   \""")

               #{String.trim_trailing(@password_code)}

               config :nerves_ssh,
                 authorized_keys: Enum.map(keys, &File.read!/1),
                 #{@user_passwords}

               # Import target specific config. This must remain at the bottom
               # of this file so it overrides the configuration defined above.
               # Uncomment to use target specific configurations

               # import_config "\#{Mix.target()}.exs"
               """)
      end

      @tag :merges_config
      test "only adds to the file", %{igniter: igniter} do
        before = content(igniter, "config/target.exs")
        igniter = igniter |> add_user() |> apply_igniter!()
        result = content(igniter, "config/target.exs")

        added =
          String.split(@password_code, "\n", trim: true) ++
            ["  authorized_keys: Enum.map(keys, &File.read!/1),", "  " <> @user_passwords]

        assert String.split(result, "\n", trim: true) -- added ==
                 String.split(before, "\n", trim: true) --
                   ["  authorized_keys: Enum.map(keys, &File.read!/1)"]

        assert length(Regex.scan(~r/^config :nerves_ssh/m, result)) == 1
      end

      test "the notice says where the password comes from and what the risks are", %{
        igniter: igniter
      } do
        igniter
        |> add_user()
        |> assert_has_notice(fn notice ->
          notice =~ "No password was written to the project" and
            notice =~ "export NERVES_SSH_PASSWORD=..." and
            notice =~ "If NERVES_SSH_PASSWORD is unset or empty at build time" and
            notice =~ "has no password user" and
            notice =~ "never built with an empty password" and
            notice =~ "weaker than public key authentication" and
            notice =~ "stored in the clear in the firmware image"
        end)
      end

      test "the password user is configured when the variable is set", %{igniter: igniter} do
        igniter = igniter |> add_user() |> apply_igniter!()

        assert read_config!(content(igniter, "config/target.exs"), "s3cret pass") ==
                 [
                   authorized_keys: ["ssh-ed25519 AAAA test\n"],
                   user_passwords: [{"username", "s3cret pass"}]
                 ]
      end

      test "no user is configured when the variable is unset or empty", %{igniter: igniter} do
        igniter = igniter |> add_user() |> apply_igniter!()
        config = content(igniter, "config/target.exs")

        for password <- [nil, ""] do
          assert read_config!(config, password) ==
                   [authorized_keys: ["ssh-ed25519 AAAA test\n"], user_passwords: []]
        end

        # ...which NervesSSH takes as nobody being able to log in with a password
        options =
          config
          |> read_config!(nil)
          |> Keyword.take([:user_passwords])
          |> NervesSSH.Options.new()

        assert options.user_passwords == []
      end

      test "is idempotent", %{igniter: igniter} do
        igniter
        |> add_user()
        |> apply_igniter!()
        |> add_user()
        |> assert_unchanged()
        |> assert_has_notice(&(&1 =~ "config/target.exs already configures `:user_passwords`"))
      end

      test "the installer leaves the result alone", %{igniter: igniter} do
        igniter
        |> add_user()
        |> apply_igniter!()
        |> install()
        |> assert_unchanged()
      end

      @tag :merges_config
      test "stays above import_config" do
        target_exs = """
        import Config

        config :logger, level: :info

        # Must remain at the bottom
        import_config "\#{Mix.target()}.exs"
        """

        igniter =
          test_project(files: %{"config/target.exs" => target_exs})
          |> install()
          |> apply_igniter!()
          |> add_user()
          |> apply_igniter!()

        assert String.ends_with?(content(igniter, "config/target.exs"), """
               config :nerves_ssh,
                 authorized_keys: Enum.map(keys, &File.read!/1),
                 #{@user_passwords}

               # Must remain at the bottom
               import_config "\#{Mix.target()}.exs"
               """)
      end
    end

    describe "existing nerves_ssh configuration" do
      @tag :merges_config
      test "is merged with" do
        target_exs = """
        import Config

        config :logger, level: :info

        # SSH on a different port
        config :nerves_ssh,
          authorized_keys: [File.read!("priv/device.pub")],
          port: 2222

        config :mdns_lite, hosts: [:hostname]
        """

        igniter =
          test_project(files: %{"config/target.exs" => target_exs})
          |> add_user()
          |> assert_unchanged("config/config.exs")
          |> apply_igniter!()

        assert content(igniter, "config/target.exs") == """
               import Config

               config :logger, level: :info

               #{String.trim_trailing(@password_code)}

               # SSH on a different port
               config :nerves_ssh,
                 authorized_keys: [File.read!("priv/device.pub")],
                 port: 2222,
                 #{@user_passwords}

               config :mdns_lite, hosts: [:hostname]
               """

        igniter |> add_user() |> assert_unchanged()
      end

      @tag :merges_config
      test "is merged with where it is, even if that's config/config.exs" do
        files = %{
          "config/target.exs" => "import Config\n",
          "config/config.exs" => """
          import Config

          config :nerves_ssh, port: 2222

          import_config "target.exs"
          """
        }

        igniter =
          test_project(files: files)
          |> add_user()
          |> assert_unchanged("config/target.exs")
          |> assert_has_notice(&(&1 =~ "config/config.exs now sets up password login"))
          |> apply_igniter!()

        assert content(igniter, "config/config.exs") == """
               import Config

               #{String.trim_trailing(@password_code)}

               config :nerves_ssh,
                 port: 2222,
                 #{@user_passwords}

               import_config "target.exs"
               """
      end

      test "that can't be merged with gets a config :nerves_ssh next to it" do
        for existing <- [
              "config :nerves_ssh, :port, 2222",
              "if Mix.target() != :host do\n  config :nerves_ssh, port: 2222\nend",
              "config :nerves_ssh, Keyword.new(port: 2222)"
            ] do
          target_exs = """
          import Config

          #{existing}

          import_config "\#{Mix.target()}.exs"
          """

          igniter =
            test_project(files: %{"config/target.exs" => target_exs})
            |> add_user()
            |> apply_igniter!()

          result = content(igniter, "config/target.exs")

          assert result == """
                 import Config

                 #{existing}

                 #{String.trim_trailing(@password_code)}

                 config :nerves_ssh,
                   #{@user_passwords}

                 import_config "\#{Mix.target()}.exs"
                 """

          igniter |> add_user() |> assert_unchanged()
        end
      end

      @tag :merges_config
      test "is merged with when there are several" do
        target_exs = """
        import Config

        config :nerves_ssh, :port, 2222

        config :nerves_ssh, shell: :erlang
        """

        igniter =
          test_project(files: %{"config/target.exs" => target_exs})
          |> add_user()
          |> apply_igniter!()

        # The variable has to be in scope whichever one is extended
        assert content(igniter, "config/target.exs") == """
               import Config

               #{String.trim_trailing(@password_code)}

               config :nerves_ssh, :port, 2222

               config :nerves_ssh,
                 shell: :erlang,
                 #{@user_passwords}
               """

        assert read_config!(content(igniter, "config/target.exs"), "pw") ==
                 [port: 2222, shell: :erlang, user_passwords: [{"username", "pw"}]]
      end

      test "doesn't reuse an ssh_password variable that is already in the file" do
        target_exs = """
        import Config

        ssh_password = "something else"

        config :my_app, password: ssh_password

        config :nerves_ssh, port: 2222
        """

        igniter =
          test_project(files: %{"config/target.exs" => target_exs})
          |> add_user()
          |> apply_igniter!()

        result = content(igniter, "config/target.exs")

        assert result =~ ~s|ssh_password = "something else"|
        assert result =~ ~s|\nnerves_ssh_password = System.get_env("NERVES_SSH_PASSWORD", "")\n|

        assert result =~
                 ~s|if(nerves_ssh_password == "", do: [], else: [{"username", nerves_ssh_password}])|

        assert read_config!(result, "pw") == [port: 2222, user_passwords: [{"username", "pw"}]]
      end
    end

    describe "existing user_passwords" do
      test "are left alone" do
        for existing <- [
              ~s|config :nerves_ssh, user_passwords: [{"me", System.fetch_env!("SSH_PASSWORD")}]|,
              ~s|config :nerves_ssh, authorized_keys: [], user_passwords: []|,
              ~s|config :nerves_ssh, :user_passwords, [{"me", "secret"}]|,
              ~s|if Mix.target() != :host do\n  config :nerves_ssh, user_passwords: []\nend|
            ] do
          test_project(files: %{"config/target.exs" => "import Config\n\n#{existing}\n"})
          |> add_user(["--ssh-username", "admin"])
          |> assert_unchanged()
          |> assert_has_notice(
            &(&1 =~ "config/target.exs already configures `:user_passwords`" and
                &1 =~ ~s|To add "admin" as well|)
          )
        end
      end

      test "are detected in other config files" do
        for file <- ["config/config.exs", "config/runtime.exs", "config/prod.exs"] do
          files = %{
            "config/target.exs" => "import Config\n\nconfig :nerves_ssh, port: 2222\n",
            file => """
            import Config

            config :nerves_ssh, user_passwords: [{"me", System.get_env("SSH_PASSWORD")}]
            """
          }

          test_project(files: files)
          |> add_user()
          |> assert_unchanged()
          |> assert_has_notice(&(&1 =~ "#{file} already configures `:user_passwords`"))
        end
      end
    end

    describe "Nerves project without nerves_ssh configuration" do
      test "gets a config :nerves_ssh above the import_config comment" do
        igniter =
          test_project(files: %{"config/target.exs" => @target_exs})
          |> add_user()
          |> assert_unchanged("config/config.exs")
          |> apply_igniter!()

        assert content(igniter, "config/target.exs") == """
               import Config

               # Advance the system clock on devices without a real-time clock.
               config :nerves, :erlinit, update_clock: true

               #{String.trim_trailing(@password_code)}

               config :nerves_ssh,
                 #{@user_passwords}

               # Import target specific config. This must remain at the bottom
               # of this file so it overrides the configuration defined above.
               # Uncomment to use target specific configurations

               # import_config "\#{Mix.target()}.exs"
               """

        assert read_config!(content(igniter, "config/target.exs"), "pw") ==
                 [user_passwords: [{"username", "pw"}]]

        assert read_config!(content(igniter, "config/target.exs"), nil) == [user_passwords: []]

        igniter |> add_user() |> assert_unchanged()
      end
    end

    describe "plain project" do
      test "falls back to config/config.exs with a notice" do
        igniter =
          test_project()
          |> add_user()
          |> refute_creates("config/target.exs")
          |> assert_has_notice(&(&1 =~ "no config/target.exs was found"))
          |> assert_has_notice(&(&1 =~ "config/config.exs now sets up password login"))
          |> apply_igniter!()

        assert content(igniter, "config/config.exs") == """
               import Config

               #{String.trim_trailing(@password_code)}

               config :nerves_ssh,
                 #{@user_passwords}
               """
      end

      test "keeps import_config last in config/config.exs" do
        config_exs = """
        import Config

        config :logger, level: :info

        import_config "\#{config_env()}.exs"
        """

        igniter =
          test_project(files: %{"config/config.exs" => config_exs})
          |> add_user()
          |> apply_igniter!()

        assert String.ends_with?(content(igniter, "config/config.exs"), """
               config :logger, level: :info

               #{String.trim_trailing(@password_code)}

               config :nerves_ssh,
                 #{@user_passwords}

               import_config "\#{config_env()}.exs"
               """)
      end

      test "is idempotent" do
        test_project()
        |> add_user()
        |> apply_igniter!()
        |> add_user()
        |> assert_unchanged()
      end

      @tag :merges_config
      test "merges with what nerves_ssh.install added to config/config.exs" do
        igniter =
          test_project()
          |> install()
          |> apply_igniter!()
          |> add_user()
          |> apply_igniter!()

        assert String.ends_with?(content(igniter, "config/config.exs"), """
               #{String.trim_trailing(@password_code)}

               config :nerves_ssh,
                 authorized_keys: Enum.map(keys, &File.read!/1),
                 #{@user_passwords}
               """)

        igniter |> add_user() |> assert_unchanged()
      end
    end

    describe "options" do
      test "--ssh-username sets the name to log in with" do
        igniter =
          test_project(files: %{"config/target.exs" => @target_exs})
          |> add_user(["--ssh-username", "admin"])
          |> assert_has_notice(&(&1 =~ ~s|password login for the SSH user\n"admin"|))
          |> apply_igniter!()

        result = content(igniter, "config/target.exs")

        assert result =~
                 ~s|user_passwords: if(ssh_password == "", do: [], else: [{"admin", ssh_password}])|

        assert read_config!(result, "pw") == [user_passwords: [{"admin", "pw"}]]
      end

      test "--ssh-password-env sets the environment variable to read" do
        igniter =
          test_project(files: %{"config/target.exs" => @target_exs})
          |> add_user(["--ssh-password-env", "MY_DEVICE_PASSWORD"])
          |> assert_has_notice(
            &(&1 =~ "export MY_DEVICE_PASSWORD=..." and
                &1 =~ "If MY_DEVICE_PASSWORD is unset or empty at build time")
          )
          |> apply_igniter!()

        result = content(igniter, "config/target.exs")

        assert result =~ "# MY_DEVICE_PASSWORD environment variable when the firmware is built."
        assert result =~ ~s|ssh_password = System.get_env("MY_DEVICE_PASSWORD", "")|
        refute result =~ "NERVES_SSH_PASSWORD"

        assert read_config!(result, "pw", "MY_DEVICE_PASSWORD") ==
                 [user_passwords: [{"username", "pw"}]]

        assert read_config!(result, nil, "MY_DEVICE_PASSWORD") == [user_passwords: []]
      end

      test "both options together" do
        igniter =
          test_project(files: %{"config/target.exs" => "import Config\n"})
          |> add_user(["--ssh-username", "o'brien\"", "--ssh-password-env", "_PW2"])
          |> apply_igniter!()

        # The name ends up as a properly escaped string
        assert read_config!(content(igniter, "config/target.exs"), "pw", "_PW2") ==
                 [user_passwords: [{"o'brien\"", "pw"}]]
      end

      test "an invalid --ssh-username is an error" do
        for username <- ["", "two words", "tab\tbed"] do
          test_project(files: %{"config/target.exs" => @target_exs})
          |> add_user(["--ssh-username", username])
          |> assert_has_issue(&(&1 =~ "Invalid --ssh-username"))
          |> assert_unchanged()
        end
      end

      test "something that isn't a variable name for --ssh-password-env is an error" do
        for env <- ["", "hunter2!", "my password", "1PASSWORD", "A=B", "$SECRET"] do
          igniter =
            test_project(files: %{"config/target.exs" => @target_exs})
            |> add_user(["--ssh-password-env", env])
            |> assert_has_issue(&(&1 =~ "Invalid --ssh-password-env"))
            |> assert_unchanged()

          # It could be a password that was passed by mistake, so it isn't repeated
          if env != "", do: refute(Enum.any?(igniter.issues, &(&1 =~ env)))
        end
      end
    end

    test "never writes a password" do
      for files <- [%{"config/target.exs" => @target_exs}, %{}],
          prepare <- [&install/1, &Function.identity/1] do
        igniter =
          test_project(files: files)
          |> prepare.()
          |> apply_igniter!()
          |> add_user()
          |> apply_igniter!()

        for {path, source} <- igniter.rewrite.sources, String.starts_with?(path, "config/") do
          content = Rewrite.Source.get(source, :content)

          # The only password in a tuple is the variable and that only ever
          # comes from the environment
          for [_, _user, password] <- Regex.scan(~r/\{("[^"]*"), ([^}]*)\}/, content) do
            assert password == "ssh_password"
          end

          for [assignment] <- Regex.scan(~r/^ssh_password = .*$/m, content) do
            assert assignment == ~s|ssh_password = System.get_env("NERVES_SSH_PASSWORD", "")|
          end
        end
      end
    end
  end
end
