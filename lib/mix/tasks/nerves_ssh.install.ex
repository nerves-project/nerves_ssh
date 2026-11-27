# SPDX-FileCopyrightText: 2026 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.NervesSsh.Install.Docs do
  @moduledoc false

  @spec short_doc() :: String.t()
  def short_doc() do
    "Installs nerves_ssh in your Nerves project."
  end

  @spec example() :: String.t()
  def example() do
    "mix igniter.install nerves_ssh"
  end

  @spec long_doc() :: String.t()
  def long_doc() do
    """
    #{short_doc()}

    Configures public key authentication the same way `mix nerves.new` does:
    the public SSH keys found in `~/.ssh` on the build machine are read when
    the firmware is built and become the device's `:authorized_keys`. No key
    material is written to your project.

    The configuration is added to `config/target.exs` when that file exists
    (a Nerves project) and to `config/config.exs` otherwise. Nothing is changed
    if `:nerves_ssh` is already configured.

    If the project has a list of applications to start early
    (`config :nerves, application_sort: [init: [...]]` or
    `config :shoehorn, init: [...]`), `:nerves_ssh` is added to it so that the
    device stays reachable over SSH if your application fails to start.

    ## Example

    ```bash
    #{example()}
    ```

    ## Options

    * `--ssh-username` - Set up username and password login for this user
      instead of public key authentication. This runs `mix nerves_ssh.add_user`.
      The password is never written to your project. It's read from an
      environment variable when the firmware is built.
    * `--ssh-password-env` - The environment variable that holds the password.
      Defaults to `NERVES_SSH_PASSWORD`. Only used with `--ssh-username`.

    See the `nerves_ssh` README for the other settings (`:port`, `:shell`,
    etc.) that can be added to the generated `config :nerves_ssh` afterwards.
    """
  end
end

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.NervesSsh.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()}"

    @moduledoc __MODULE__.Docs.long_doc()

    use Igniter.Mix.Task

    alias Igniter.Code.Common
    alias Igniter.Project.Config
    alias Igniter.Project.Deps
    alias Sourceror.Zipper

    @target_config "config/target.exs"
    @fallback_config "config/config.exs"

    # Any of these configuring :nerves_ssh means that the user already set it up
    @checked_configs [
      "config/config.exs",
      "config/target.exs",
      "config/runtime.exs",
      "config/host.exs",
      "config/dev.exs",
      "config/prod.exs"
    ]

    # Lists of applications to start early: Nerves 2 and shoehorn (Nerves 1.x)
    @init_lists [{:nerves, [:application_sort, :init]}, {:shoehorn, [:init]}]

    @impl Igniter.Mix.Task
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :nerves_ssh,
        example: __MODULE__.Docs.example(),
        # `--ssh-username` and `--ssh-password-env` belong to
        # nerves_ssh.add_user. Listing it here makes them available.
        schema: [],
        defaults: [],
        aliases: [],
        composes: ["nerves_ssh.add_user"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      igniter = restrict_dep_to_targets(igniter)

      igniter =
        if password_login?(igniter) do
          Igniter.compose_task(igniter, "nerves_ssh.add_user")
        else
          configure_authorized_keys(igniter)
        end

      start_early(igniter)
    end

    # nerves_ssh.add_user has a default username, so whether one was asked for
    # can only be seen in the arguments.
    defp password_login?(igniter) do
      Enum.any?(igniter.args.argv_flags, &String.starts_with?(&1, "--ssh-username"))
    end

    # mix.exs --------------------------------------------------------------

    # nerves_ssh starts an SSH server on the machine that it runs on.
    # Nerves projects keep such dependencies off the host with a `:targets`
    # option that refers to a module attribute. E.g.,
    # `{:nerves_pack, "~> 0.7", targets: @all_targets}`. When the project has
    # one and :nerves_ssh is listed in mix.exs without `:targets`, it gets
    # the first such attribute too. Nothing is changed otherwise, like when
    # :nerves_ssh is brought in by :nerves_pack.
    defp restrict_dep_to_targets(igniter) do
      with {:ok, declaration} when is_binary(declaration) <-
             Deps.get_dep(igniter, :nerves_ssh),
           {:ok, dep} <- Code.string_to_quoted(declaration),
           false <- has_targets_option?(dep),
           {:ok, quoted} <- Code.string_to_quoted(mix_exs(igniter)),
           attribute when is_atom(attribute) and not is_nil(attribute) <-
             first_targets_attribute(quoted) do
        Deps.set_dep_option(
          igniter,
          :nerves_ssh,
          :targets,
          {:@, [], [{attribute, [], nil}]}
        )
      else
        _ -> igniter
      end
    end

    defp mix_exs(igniter) do
      igniter = Igniter.include_existing_file(igniter, "mix.exs")

      case Rewrite.source(igniter.rewrite, "mix.exs") do
        {:ok, source} -> Rewrite.Source.get(source, :content)
        _ -> ""
      end
    end

    defp has_targets_option?(quoted) do
      {_quoted, found?} =
        Macro.prewalk(quoted, false, fn
          {:targets, _value} = node, _found? -> {node, true}
          node, found? -> {node, found?}
        end)

      found?
    end

    # The name of the module attribute in the first `targets: @attribute`. If
    # no dependency has one, `@all_targets` is used when mix.exs defines it.
    # That's the attribute that Nerves projects list their targets in.
    defp first_targets_attribute(quoted) do
      {_quoted, {used, all_targets?}} =
        Macro.prewalk(quoted, {nil, false}, fn
          {:targets, {:@, _, [{name, _, context}]}} = node, {nil, all_targets?}
          when is_atom(name) and is_atom(context) ->
            {node, {name, all_targets?}}

          {:@, _, [{:all_targets, _, [_value]}]} = node, {used, _all_targets?} ->
            {node, {used, true}}

          node, acc ->
            {node, acc}
        end)

      used || if(all_targets?, do: :all_targets)
    end

    defp configure_authorized_keys(igniter) do
      nerves_project? = Igniter.exists?(igniter, @target_config)
      path = if nerves_project?, do: @target_config, else: @fallback_config

      if already_configured?(igniter) do
        igniter
      else
        igniter
        |> Igniter.include_or_create_file(path, "import Config\n")
        |> Igniter.update_file(path, &add_authorized_keys(&1, path))
        |> Igniter.add_notice(notice(path, nerves_project?))
      end
    end

    # The README recommends starting `:nerves_ssh` early so that the device
    # stays reachable when the main application fails to start. This only
    # extends a list that the project already has (Nerves 2's
    # `:application_sort` or shoehorn's `:init`). `:nerves_pack` in the list
    # already covers `:nerves_ssh` since it depends on it.
    defp start_early(igniter) do
      Enum.reduce(@init_lists, igniter, fn {app, key_path}, igniter ->
        case init_list_file(igniter, app, key_path) do
          nil ->
            igniter

          file ->
            Config.configure(igniter, file, app, key_path, [:nerves_ssh],
              updater: &append_to_init_list/1
            )
        end
      end)
    end

    defp init_list_file(igniter, app, key_path) do
      Enum.find(["target.exs", "config.exs"], fn file ->
        Igniter.exists?(igniter, Path.join("config", file)) and
          Config.configures_key?(igniter, file, app, key_path)
      end)
    end

    # Anything other than a literal list is left alone
    defp append_to_init_list(zipper) do
      case Common.within(zipper, &append_nerves_ssh/1) do
        {:ok, zipper} -> {:ok, zipper}
        :error -> {:ok, zipper}
      end
    end

    defp append_nerves_ssh(list) do
      cond do
        not Igniter.Code.List.list?(list) -> :error
        in_list?(list, :nerves_pack) or in_list?(list, :nerves_ssh) -> :error
        true -> Igniter.Code.List.append_to_list(list, :nerves_ssh)
      end
    end

    defp in_list?(list, app) do
      Igniter.Code.List.find_list_item_index(list, &Common.nodes_equal?(&1, app)) != nil
    end

    defp already_configured?(igniter) do
      Enum.any?(@checked_configs, fn path ->
        Igniter.exists?(igniter, path) and configures_nerves_ssh?(igniter, path)
      end)
    end

    defp configures_nerves_ssh?(igniter, path) do
      igniter = Igniter.include_existing_file(igniter, path)

      case Rewrite.source(igniter.rewrite, path) do
        {:ok, source} ->
          source
          |> Rewrite.Source.get(:quoted)
          |> Zipper.zip()
          |> Zipper.find(&nerves_ssh_config?/1)
          |> is_struct()

        _ ->
          false
      end
    end

    # Matches `config :nerves_ssh, ...` at any depth so that config in an
    # `if`/`case` block counts as well.
    defp nerves_ssh_config?({:config, _, [app | _]}), do: unwrap(app) == :nerves_ssh
    defp nerves_ssh_config?(_), do: false

    defp unwrap({:__block__, _, [value]}), do: value
    defp unwrap(value), do: value

    # The block is spliced into the file as text instead of going through the
    # AST so that it comes out exactly like `mix nerves.new` writes it (blank
    # lines and comments included) and the rest of the file stays as it was.
    defp add_authorized_keys(source, path) do
      quoted = Rewrite.Source.get(source, :quoted)
      lines = source |> Rewrite.Source.get(:content) |> String.split("\n")
      code = config_code(keys_variable(quoted), path)

      # `import_config` has to stay last so that what it imports can override
      index = import_config_index(quoted) || trailing_import_comment_index(lines) || length(lines)
      {before, rest} = Enum.split(lines, index)

      content =
        [trim_blank_lines(before), String.trim_trailing(code), trim_blank_lines(rest)]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      Rewrite.Source.update(source, :content, content <> "\n")
    end

    # 0-based index of the line where the first top-level `import_config`
    # starts. Comments right above it belong to it.
    defp import_config_index(quoted) do
      Enum.find_value(top_level(quoted), fn
        {:import_config, meta, [_]} ->
          comment_lines = for %{line: line} <- meta[:leading_comments] || [], do: line
          Enum.min([meta[:line] | comment_lines]) - 1

        _ ->
          nil
      end)
    end

    defp top_level({:__block__, _, statements}), do: statements
    defp top_level(statement), do: [statement]

    # `mix nerves.new` ends config/target.exs with a commented out
    # `import_config`. Stay above that too so that uncommenting it works.
    defp trailing_import_comment_index(lines) do
      trailing = lines |> Enum.reverse() |> Enum.take_while(&(&1 =~ ~r/^\s*(#.*)?$/))

      if Enum.any?(trailing, &(&1 =~ "import_config")) do
        length(lines) - length(trailing)
      end
    end

    defp trim_blank_lines(lines), do: lines |> Enum.join("\n") |> String.trim()

    # The template uses `keys`. Only pick something else when that name is
    # already taken in the file so that an existing variable isn't clobbered.
    defp keys_variable(quoted) do
      {_, used?} =
        Macro.prewalk(quoted, false, fn
          {:keys, _, ctx} = node, _ when is_atom(ctx) -> {node, true}
          node, acc -> {node, acc}
        end)

      if used?, do: "nerves_ssh_keys", else: "keys"
    end

    defp config_code(var, path) do
      """
      # Configure the device for SSH IEx prompt access and firmware updates
      #
      # * See https://nerves-ssh.hexdocs.pm/readme.html for general SSH configuration
      # * See https://ssh-subsystem-fwup.hexdocs.pm/readme.html for firmware updates

      #{var} =
        System.user_home!()
        |> Path.join(".ssh/id_{rsa,ecdsa,ed25519}.pub")
        |> Path.wildcard()

      if #{var} == [],
        do:
          Mix.raise(\"""
          No SSH public keys found in ~/.ssh. An ssh authorized key is needed to
          log into the Nerves device and update firmware on it using ssh.
          See your project's #{path} for this error message.
          \""")

      config :nerves_ssh,
        authorized_keys: Enum.map(#{var}, &File.read!/1)
      """
    end

    defp notice(path, true) do
      """
      nerves_ssh: #{path} now reads your public SSH keys from
      ~/.ssh/id_{rsa,ecdsa,ed25519}.pub when the firmware is built and
      authorizes them to log into the device. The build fails if none exist.
      Create one with `ssh-keygen -t ed25519` or edit the configuration to
      point at the keys you want. No keys were copied into the project.
      """
    end

    defp notice(path, false) do
      """
      nerves_ssh: no config/target.exs was found so the SSH configuration was
      added to #{path}. These defaults are meant for Nerves projects: they run
      for every build, including host builds and CI, and raise if
      ~/.ssh/id_{rsa,ecdsa,ed25519}.pub don't exist. Move the configuration to
      where your device configuration lives if that isn't what you want.
      No keys were copied into the project.
      """
    end
  end
else
  defmodule Mix.Tasks.NervesSsh.Install do
    @shortdoc "#{__MODULE__.Docs.short_doc()} | Install `igniter` to use"

    @moduledoc __MODULE__.Docs.long_doc()

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'nerves_ssh.install' requires igniter. Please install igniter and try again.

      For more information, see: https://igniter.hexdocs.pm/readme.html#installation
      """)

      exit({:shutdown, 1})
    end
  end
end
