defmodule NervesSSH.Options do
  @moduledoc false

  @type language :: :elixir | :erlang | :disabled

  @type t :: %__MODULE__{
          authorized_keys: [String.t()],
          port: non_neg_integer(),
          subsystems: [:ssh.subsystem_spec()],
          system_dir: Path.t(),
          shell: language(),
          exec: language()
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
            iex_opts: [dot_iex_path: ""]

  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc """
  Convert NervesSSH.Options to :ssh.daemon_options()
  """
  @spec daemon_options(t()) :: :ssh.daemon_options()
  def daemon_options(opts) do
    base_opts() ++
      subsystem_opts(opts) ++
      shell_opts(opts) ++
      exec_opts(opts) ++
      authentication_daemon_opts(opts) ++
      key_cb_opts(opts)
  end

  defp base_opts() do
    [id_string: :random, inet: :inet6]
  end

  defp shell_opts(%{shell: :elixir, iex_opts: iex_opts}),
    do: [{:shell, {Elixir.IEx, :start, [iex_opts]}}]

  defp shell_opts(%{shell: :erlang}), do: []
  defp shell_opts(%{shell: :disabled}), do: [shell: :disabled]

  defp exec_opts(%{exec: :elixir}), do: [exec: {:direct, &NervesSSH.Exec.run_elixir/1}]
  defp exec_opts(%{exec: :disabled}), do: [exec: :disabled]

  defp key_cb_opts(opts) do
    cb_opts = [authorized_keys: decoded_authorized_keys(opts)]

    [key_cb: {NervesSSH.Keys, cb_opts}]
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

  defp decoded_authorized_keys(opts) do
    opts.authorized_keys
    |> Enum.flat_map(&:public_key.ssh_decode(&1, :auth_keys))
  end
end
