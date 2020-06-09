defmodule NervesSSH.Options do
  @moduledoc """
  Defines option for running the SSH daemon.

  The following fields are available:

  * `:authorized_keys` - a list of SSH authorized key file string
  * `:port` - the TCP port to use for the SSH daemon. Defaults to `22`.
  * `:subsystems` - a list of [SSH subsystems specs](https://erlang.org/doc/man/ssh.html#type-subsystem_spec) to start. Defaults to SFTP and `nerves_firmware_ssh2`
  * `:system_dir` - where to find host keys
  * `:shell` - the language of the shell (`:elixir`, `:erlang`, or `:disabled`). Defaults to `:elixir`.
  * `:exec` - the language to use for commands sent over ssh (`:elixir`, `:erlang`, or `:disabled`). Defaults to `:elixir`.
  * `:iex_opts` - additional options to use when starting up IEx
  * `:daemon_option_overrides` - additional options to pass to `:ssh.daemon/2`. These take precedence and are unchecked.
  """

  @type language :: :elixir | :erlang | :disabled

  @type t :: %__MODULE__{
          authorized_keys: [String.t()],
          port: non_neg_integer(),
          subsystems: [:ssh.subsystem_spec()],
          system_dir: Path.t(),
          shell: language(),
          exec: language(),
          iex_opts: keyword(),
          daemon_option_overrides: keyword()
        }

  defstruct authorized_keys: [],
            port: 22,
            subsystems: [
              :ssh_sftpd.subsystem_spec(cwd: '/'),
              NervesFirmwareSSH2.subsystem_spec()
            ],
            system_dir: "/etc/ssh",
            shell: :elixir,
            exec: :elixir,
            iex_opts: [dot_iex_path: ""],
            daemon_option_overrides: []

  @doc """
  Convert keyword options to the NervesSSH.Options
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc """
  Return :ssh.daemon_options()
  """
  @spec daemon_options(t()) :: :ssh.daemon_options()
  def daemon_options(opts) do
    (base_opts() ++
       subsystem_opts(opts) ++
       shell_opts(opts) ++
       exec_opts(opts) ++
       authentication_daemon_opts(opts) ++
       key_cb_opts(opts))
    |> Keyword.merge(opts.daemon_option_overrides)
  end

  defp base_opts() do
    [id_string: :random, inet: :inet6]
  end

  defp shell_opts(%{shell: :elixir, iex_opts: iex_opts}) do
    # We want to resolve the user specified iex.exs file at session start
    # so let's do a switcheroo here and make sure to always use
    # our iex.exs to run the resolve logic
    iex_path = Path.join(:code.priv_dir(:nerves_ssh), "iex.exs")
    iex_opts = Keyword.put(iex_opts, :dot_iex_path, iex_path)

    [{:shell, {Elixir.IEx, :start, [iex_opts]}}]
  end

  defp shell_opts(%{shell: :erlang}), do: []
  defp shell_opts(%{shell: :disabled}), do: [shell: :disabled]

  defp exec_opts(%{exec: :elixir}), do: [exec: {:direct, &NervesSSH.Exec.run_elixir/1}]
  defp exec_opts(%{exec: :disabled}), do: [exec: :disabled]

  defp key_cb_opts(opts) do
    keys = Enum.flat_map(opts.authorized_keys, &:public_key.ssh_decode(&1, :auth_keys))

    [key_cb: {NervesSSH.Keys, [authorized_keys: keys]}]
  end

  defp authentication_daemon_opts(opts) do
    [system_dir: to_charlist(opts.system_dir)]
  end

  defp subsystem_opts(opts) do
    [subsystems: opts.subsystems]
  end

  @doc """
  Go through the options and fix anything that might crash

  The goal is to make options "always work" since it is painful to
  debug typo's, etc. that cause the ssh daemon to not start.
  """
  @spec sanitize(t()) :: t()
  def sanitize(opts) do
    safe_subsystems = Enum.filter(opts.subsystems, &valid_subsystem?/1)

    %__MODULE__{opts | subsystems: safe_subsystems}
  end

  defp valid_subsystem?({name, {mod, args}})
       when is_list(name) and is_atom(mod) and is_list(args) do
    List.ascii_printable?(name)
  end

  defp valid_subsystem?(_), do: false
end
