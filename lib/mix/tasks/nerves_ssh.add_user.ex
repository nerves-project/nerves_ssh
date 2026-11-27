# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.NervesSsh.AddUser.Docs do
  @moduledoc false

  @spec short_doc() :: String.t()
  def short_doc() do
    "Sets up username and password login for nerves_ssh."
  end

  @spec example() :: String.t()
  def example() do
    "mix nerves_ssh.add_user --ssh-username admin"
  end

  @spec long_doc() :: String.t()
  def long_doc() do
    """
    #{short_doc()}

    Adds `:user_passwords` to the project's `config :nerves_ssh`. This is the
    build-time counterpart to `NervesSSH.add_user/2`. Public key
    authentication that is already set up keeps working alongside it.

    The password is never written to a file. The generated configuration reads
    it from an environment variable (`NERVES_SSH_PASSWORD` by default) when
    the firmware is built:

    ```elixir
    ssh_password = System.get_env("NERVES_SSH_PASSWORD", "")

    config :nerves_ssh,
      user_passwords: if(ssh_password == "", do: [], else: [{"username", ssh_password}])
    ```

    If the variable is unset or empty when the firmware is built, no password
    user is configured, so that firmware doesn't accept password logins at
    all. It is never built with an empty password.

    Keep in mind that password authentication is weaker than public key
    authentication and that the password is stored in the clear in the
    firmware. The `nerves_ssh` README doesn't recommend it for most
    situations.

    The configuration is added to the existing `config :nerves_ssh` in
    `config/target.exs` or `config/config.exs` when there is one. Otherwise it
    is added to `config/target.exs` when that file exists (a Nerves project)
    and to `config/config.exs` if not. Nothing is changed if `:user_passwords`
    is already configured.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--ssh-username` - The name to log in with. Defaults to `username`.
    * `--ssh-password-env` - The environment variable that the password is
      read from when the firmware is built. Defaults to `NERVES_SSH_PASSWORD`.
      This is the name of the variable. Don't pass the password itself.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.NervesSsh.AddUser do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Igniter.Project.Config
    alias Sourceror.Zipper

    @target_config "config/target.exs"
    @fallback_config "config/config.exs"

    # `:user_passwords` in any of these means that the user already set it up
    @checked_configs [
      "config/target.exs",
      "config/config.exs",
      "config/runtime.exs",
      "config/host.exs",
      "config/dev.exs",
      "config/prod.exs"
    ]

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :nerves_ssh,
        example: __MODULE__.Docs.example(),
        schema: [ssh_username: :string, ssh_password_env: :string],
        defaults: [ssh_username: "username", ssh_password_env: "NERVES_SSH_PASSWORD"],
        aliases: [],
        composes: []
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      username = igniter.args.options[:ssh_username]
      env = igniter.args.options[:ssh_password_env]

      cond do
        not valid_username?(username) ->
          Igniter.add_issue(
            igniter,
            "Invalid --ssh-username #{inspect(username)}. Expected printable characters without whitespace."
          )

        not valid_env?(env) ->
          # The value isn't echoed in case a password was passed by mistake
          Igniter.add_issue(igniter, """
          Invalid --ssh-password-env. Expected the name of an environment
          variable like NERVES_SSH_PASSWORD (letters, digits and underscores).
          The password itself is never passed to this task.
          """)

        path = Enum.find(@checked_configs, &configures_user_passwords?(igniter, &1)) ->
          Igniter.add_notice(igniter, existing_notice(path, username))

        true ->
          add_user(igniter, username, env)
      end
    end

    defp valid_username?(username), do: username =~ ~r/\A[[:graph:]]+\z/u

    defp valid_env?(env), do: env =~ ~r/\A[A-Za-z_][A-Za-z0-9_]*\z/

    defp add_user(igniter, username, env) do
      nerves_project? = Igniter.exists?(igniter, @target_config)
      path = config_path(igniter, nerves_project?)
      var = password_variable(igniter, path)

      # A missing password must not turn into a user that can log in with an
      # empty one, which is how NervesSSH treats `{"username", nil}`, so no
      # user is configured at all then.
      user_passwords = ~s|if(#{var} == "", do: [], else: [{#{inspect(username)}, #{var}}])|

      igniter
      |> Igniter.include_or_create_file(path, "import Config\n")
      |> configure_user_passwords(path, var, env, user_passwords)
      |> Igniter.add_notice(notice(path, username, env))
      |> fallback_notice(path, nerves_project?)
    end

    # Prefer the file that has the project's `config :nerves_ssh`
    defp config_path(igniter, nerves_project?) do
      default = if nerves_project?, do: @target_config, else: @fallback_config

      Enum.find([@target_config, @fallback_config], default, fn path ->
        Igniter.exists?(igniter, path) and
          Config.configures_root_key?(igniter, Path.basename(path), :nerves_ssh)
      end)
    end

    # Only pick something other than `ssh_password` when that name is already
    # taken in the file so that an existing variable isn't clobbered.
    defp password_variable(igniter, path) do
      if Igniter.exists?(igniter, path) and
           find_in_file(igniter, path, &variable?(&1, :ssh_password)) do
        "nerves_ssh_password"
      else
        "ssh_password"
      end
    end

    # Before Elixir 1.17, Sourceror raises when a key is added to a `config`
    # in a file that ends in comments, like the config/target.exs from `mix
    # nerves.new`. The user gets a `config :nerves_ssh` of its own there.
    defp merge_supported?(), do: Version.match?(System.version(), ">= 1.17.0")

    # The code that reads the password is spliced in as text since inserting
    # code around the last expression of a file that ends in comments, like
    # the config/target.exs from `mix nerves.new`, breaks in Sourceror. It
    # also keeps the rest of the file exactly as it was.
    defp configure_user_passwords(igniter, path, var, env, user_passwords) do
      if merge_supported?() and mergeable?(igniter, path) do
        # The variable goes in first so that the file is valid at every step
        igniter
        |> Igniter.update_file(path, &add_password_variable(&1, var, env))
        |> Config.configure_new(
          Path.basename(path),
          :nerves_ssh,
          [:user_passwords],
          {:code, Sourceror.parse_string!(user_passwords)}
        )
      else
        Igniter.update_file(igniter, path, &add_config(&1, var, env, user_passwords))
      end
    end

    # Whether there's a top-level `config :nerves_ssh, key: value` to merge with
    defp mergeable?(igniter, path) do
      igniter = Igniter.include_existing_file(igniter, path)

      case Rewrite.source(igniter.rewrite, path) do
        {:ok, source} ->
          source |> parse() |> top_level() |> Enum.any?(&keyword_config?/1)

        _ ->
          false
      end
    end

    defp keyword_config?({:config, _, [_app, keyword]} = config) when is_list(keyword) do
      nerves_ssh_config?(config)
    end

    defp keyword_config?(_), do: false

    # Reads the password above the first top-level `config :nerves_ssh` so
    # that it is in scope for all of them
    defp add_password_variable(source, var, env) do
      index = source |> parse() |> top_level() |> Enum.find(&nerves_ssh_config?/1) |> first_line()
      {before, rest} = source |> lines() |> Enum.split(index)

      put_lines(source, before ++ password_code(var, env) ++ ["" | rest])
    end

    # A `config :nerves_ssh` of its own for when there is nothing to merge with
    defp add_config(source, var, env, user_passwords) do
      lines = lines(source)

      code =
        password_code(var, env) ++
          ["", "config :nerves_ssh,", "  user_passwords: #{user_passwords}"]

      # `import_config` has to stay last so that what it imports can override
      index =
        import_config_index(parse(source)) || trailing_import_comment_index(lines) ||
          length(lines)

      {before, rest} = Enum.split(lines, index)

      content =
        [trim_blank_lines(before), Enum.join(code, "\n"), trim_blank_lines(rest)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      Rewrite.Source.update(source, :content, content <> "\n")
    end

    defp password_code(var, env) do
      [
        "# Username and password login over SSH. The password is read from the",
        "# #{env} environment variable when the firmware is built.",
        "# Firmware that is built without it doesn't accept password logins.",
        "#{var} = System.get_env(#{inspect(env)}, \"\")"
      ]
    end

    # Parsed from the content so that the line numbers are those of the text
    defp parse(source), do: source |> Rewrite.Source.get(:content) |> Sourceror.parse_string!()

    defp lines(source), do: source |> Rewrite.Source.get(:content) |> String.split("\n")

    defp put_lines(source, lines) do
      Rewrite.Source.update(source, :content, Enum.join(lines, "\n"))
    end

    # Sourceror wraps a statement that is followed by the comments that end
    # the file in a block of its own
    defp top_level({:__block__, _, statements}), do: Enum.map(statements, &unwrap/1)
    defp top_level(statement), do: [statement]

    # 0-based index of the line where the statement starts. Comments right
    # above it belong to it.
    defp first_line({_, meta, _}) do
      comment_lines = for %{line: line} <- meta[:leading_comments] || [], do: line
      Enum.min([meta[:line] | comment_lines]) - 1
    end

    defp import_config_index(quoted) do
      Enum.find_value(top_level(quoted), fn
        {:import_config, _, [_]} = statement -> first_line(statement)
        _ -> nil
      end)
    end

    # `mix nerves.new` ends config/target.exs with a commented out
    # `import_config`. Stay above that too so that uncommenting it works.
    defp trailing_import_comment_index(lines) do
      trailing = lines |> Enum.reverse() |> Enum.take_while(&(&1 =~ ~r/^\s*(#.*)?$/))

      if Enum.any?(trailing, &(&1 =~ "import_config")) do
        length(lines) - length(trailing)
      end
    end

    defp trim_blank_lines(lines), do: lines |> Enum.join("\n") |> String.trim()

    defp configures_user_passwords?(igniter, path) do
      Igniter.exists?(igniter, path) and
        find_in_file(igniter, path, &(nerves_ssh_config?(&1) and mentions?(&1, :user_passwords)))
    end

    defp find_in_file(igniter, path, predicate) do
      igniter = Igniter.include_existing_file(igniter, path)

      case Rewrite.source(igniter.rewrite, path) do
        {:ok, source} ->
          source
          |> Rewrite.Source.get(:quoted)
          |> Zipper.zip()
          |> Zipper.find(predicate)
          |> is_struct()

        _ ->
          false
      end
    end

    # Matches `config :nerves_ssh, ...` at any depth so that config in an
    # `if`/`case` block counts as well.
    defp nerves_ssh_config?({:config, _, [app | _]}), do: unwrap(app) == :nerves_ssh
    defp nerves_ssh_config?(_), do: false

    defp variable?({name, _, context}, name) when is_atom(context), do: true
    defp variable?(_, _), do: false

    # Whether the atom or the variable with that name is anywhere in the code
    defp mentions?(quoted, name) do
      {_quoted, found?} =
        Macro.prewalk(quoted, false, fn node, found? ->
          {node, found? or node == name or variable?(node, name)}
        end)

      found?
    end

    defp unwrap({:__block__, _, [value]}), do: value
    defp unwrap(value), do: value

    defp notice(path, username, env) do
      """
      nerves_ssh: #{path} now sets up password login for the SSH user
      #{inspect(username)}. No password was written to the project. It is read
      from the #{env} environment variable when the firmware is built:

          export #{env}=...
          mix firmware

      If #{env} is unset or empty at build time, the build succeeds and that
      firmware has no password user, so password logins are refused. It is
      never built with an empty password. Public key authentication is not
      affected either way.

      Password authentication is weaker than public key authentication, and
      the password is stored in the clear in the firmware image, so anyone with
      the .fw file or the device's storage can read it. Prefer `:authorized_keys`
      where you can and use a password that isn't used anywhere else.
      """
    end

    defp existing_notice(path, username) do
      """
      nerves_ssh: #{path} already configures `:user_passwords` for :nerves_ssh,
      so nothing was changed. To add #{inspect(username)} as well, add a
      `{#{inspect(username)}, password}` tuple to that list by hand. Read the
      password from the environment instead of writing it to the file, and
      leave the user out when it is unset, since a `nil` or empty password
      lets anyone log in as that user.
      """
    end

    defp fallback_notice(igniter, _path, true), do: igniter

    defp fallback_notice(igniter, path, false) do
      Igniter.add_notice(igniter, """
      nerves_ssh: no config/target.exs was found so the password login was
      configured in #{path}. This is meant for Nerves projects, where it only
      applies to the device. Here it applies to every build, including host
      builds. Move it to where your device configuration lives if that isn't
      what you want.
      """)
    end
  end
else
  defmodule Mix.Tasks.NervesSsh.AddUser do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'nerves_ssh.add_user' requires igniter. Please install igniter and try again.

      For more information, see: https://igniter.hexdocs.pm/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
