defmodule NervesSSH.Options do
  @moduledoc """
  Defines option for running the SSH daemon.

  The following fields are available:

  * `:authorized_keys` - a list of SSH authorized key file string
  * `:port` - the TCP port to use for the SSH daemon. Defaults to `22`.
  * `:subsystems` - a list of [SSH subsystems specs](https://erlang.org/doc/man/ssh.html#type-subsystem_spec) to start. Defaults to SFTP and `ssh_subsystem_fwup`
  * `:system_dir` - where to find host keys
  * `:shell` - the language of the shell (`:elixir`, `:erlang`, or `:disabled`). Defaults to `:elixir`.
  * `:exec` - the language to use for commands sent over ssh (`:elixir`, `:erlang`, or `:disabled`). Defaults to `:elixir`.
  * `:iex_opts` - additional options to use when starting up IEx
  * `:user_passwords` - a list of username/password tuples (stored in the clear!)
  * `:daemon_option_overrides` - additional options to pass to `:ssh.daemon/2`. These take precedence and are unchecked.
  """

  @type language :: :elixir | :erlang | :disabled

  @type t :: %__MODULE__{
          authorized_keys: [String.t()],
          user_passwords: [{String.t(), String.t()}],
          port: non_neg_integer(),
          subsystems: [:ssh.subsystem_spec()],
          system_dir: Path.t(),
          shell: language(),
          exec: language(),
          iex_opts: keyword(),
          daemon_option_overrides: keyword()
        }

  defstruct authorized_keys: [],
            user_passwords: [],
            port: 22,
            subsystems: [:ssh_sftpd.subsystem_spec(cwd: '/')],
            system_dir: "",
            shell: :elixir,
            exec: :elixir,
            iex_opts: [dot_iex_path: ""],
            daemon_option_overrides: []

  @doc """
  Convert keyword options to the NervesSSH.Options
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    # if a key is present with nil value, the default will
    # not be applied in the struct. So remove keys that
    # have a nil value so defaults get set appropiately
    opts = Enum.reject(opts, fn {_k, v} -> is_nil(v) end)

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
       key_cb_opts(opts) ++
       user_passwords_opts(opts))
    |> Keyword.merge(opts.daemon_option_overrides)
  end

  defp base_opts() do
    [id_string: :random, inet: :inet6, disconnectfun: fn _reason -> false end]
  end

  defp shell_opts(%{shell: :elixir, iex_opts: iex_opts}),
    do: [{:shell, {Elixir.IEx, :start, [iex_opts]}}]

  defp shell_opts(%{shell: :erlang}), do: []
  defp shell_opts(%{shell: :disabled}), do: [shell: :disabled]

  defp exec_opts(%{exec: :elixir}), do: [exec: {:direct, &NervesSSH.Exec.run_elixir/1}]
  defp exec_opts(%{exec: :disabled}), do: [exec: :disabled]

  defp key_cb_opts(opts) do
    keys = Enum.flat_map(opts.authorized_keys, &:public_key.ssh_decode(&1, :auth_keys))

    [key_cb: {NervesSSH.Keys, [authorized_keys: keys]}]
  end

  defp user_passwords_opts(opts) do
    passes =
      for {user, password} <- opts.user_passwords do
        {to_charlist(user), to_charlist(password)}
      end

    [user_passwords: passes]
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
    safe_dot_iex_path = validate_dot_iex_path(opts.iex_opts[:dot_iex_path])
    iex_opts = Keyword.put(opts.iex_opts, :dot_iex_path, safe_dot_iex_path)

    %__MODULE__{opts | subsystems: safe_subsystems, iex_opts: iex_opts}
  end

  defp validate_dot_iex_path(dot_iex_path) do
    [dot_iex_path, ".iex.exs", "~/.iex.exs", "/etc/iex.exs"]
    |> Enum.filter(&is_bitstring/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.find("", &File.regular?/1)
  end

  defp valid_subsystem?({name, {mod, args}})
       when is_list(name) and is_atom(mod) and is_list(args) do
    List.ascii_printable?(name)
  end

  defp valid_subsystem?(_), do: false
end
