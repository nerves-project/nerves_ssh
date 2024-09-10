defmodule NervesSSH.SystemShellTest do
  use ExUnit.Case, async: true

  @base_ssh_port 4022
  @rsa_public_key String.trim(File.read!("test/fixtures/good_user_dir/id_rsa.pub"))

  defp default_config() do
    NervesSSH.Options.with_defaults(
      name: :shell_server,
      authorized_keys: [@rsa_public_key],
      system_dir: Path.absname("test/fixtures/system_dir"),
      user_dir: Path.absname("test/fixtures/system_dir"),
      port: ssh_port(),
      daemon_option_overrides: [ssh_cli: {NervesSSH.SystemShell, []}]
    )
  end

  defp subsystem_config() do
    NervesSSH.Options.with_defaults(
      name: :shell_subsystem_server,
      authorized_keys: [@rsa_public_key],
      system_dir: Path.absname("test/fixtures/system_dir"),
      user_dir: Path.absname("test/fixtures/system_dir"),
      port: ssh_port(),
      subsystems: [
        {'shell', {NervesSSH.SystemShellSubsystem, []}}
      ]
    )
  end

  defp ssh_run(cmd) do
    ssh_options = [
      ip: '127.0.0.1',
      port: ssh_port(),
      user_interaction: false,
      silently_accept_hosts: true,
      save_accepted_host: false,
      user: 'test_user',
      password: 'password',
      user_dir: Path.absname("test/fixtures/good_user_dir")
    ]

    # Short sleep to make sure server is up an running
    Process.sleep(200)

    with {:ok, conn} <- SSHEx.connect(ssh_options) do
      SSHEx.run(conn, cmd)
    end
  end

  defp ssh_port() do
    Process.get(:ssh_port)
  end

  defp receive_until_eof() do
    receive_until_eof([])
  end

  defp receive_until_eof(acc) do
    receive do
      {:ssh_cm, _, {:data, _, _, data}} ->
        receive_until_eof([data | acc])

      {:ssh_cm, _, {:eof, _}} ->
        IO.iodata_to_binary(Enum.reverse(acc))

      _ ->
        receive_until_eof(acc)
    after
      5000 -> raise "timeout"
    end
  end

  setup_all do
    Application.ensure_all_started(:erlexec)

    :ok
  end

  setup context do
    # Use unique ssh port numbers for each test to support async: true
    Process.put(:ssh_port, @base_ssh_port + :erlang.phash2({context.module, context.test}, 10000))
    :ok
  end

  @tag :has_good_sshd_exec
  describe "ssh_cli" do
    test "exec mode" do
      start_supervised!({NervesSSH, default_config()})
      assert {:ok, "ok\n", 0} == ssh_run("echo ok")
    end

    test "shell mode with pty" do
      start_supervised!({NervesSSH, default_config()})
      # Short sleep to make sure server is up an running
      Process.sleep(200)

      assert {:ok, conn} =
               :ssh.connect(
                 '127.0.0.1',
                 ssh_port(),
                 [
                   silently_accept_hosts: true,
                   save_accepted_host: false,
                   user: 'test_user',
                   password: 'password',
                   user_dir: Path.absname("test/fixtures/good_user_dir") |> to_charlist()
                 ],
                 5000
               )

      assert {:ok, channel} = :ssh_connection.session_channel(conn, 5000)

      assert :success =
               :ssh_connection.ptty_alloc(conn, channel,
                 term: "dumb",
                 width: 99,
                 height: 33,
                 pty_opts: [echo: 1]
               )

      assert :success = :ssh_connection.setenv(conn, channel, 'PS1', 'prompt> ', 5000)

      assert :ok = :ssh_connection.shell(conn, channel)
      assert :ok = :ssh_connection.send(conn, channel, "echo cool\n")
      assert :ok = :ssh_connection.send(conn, channel, "echo $TERM\n")
      assert :ok = :ssh_connection.send(conn, channel, "exit 0\n")

      assert receive_until_eof() =~
               "prompt> echo cool\r\ncool\r\nprompt> echo $TERM\r\ndumb\r\nprompt> exit 0\r\n"
    end
  end

  @tag :has_good_sshd_exec
  describe "subsystem" do
    test "normal elixir exec" do
      start_supervised!({NervesSSH, subsystem_config()})
      assert {:ok, "2", 0} == ssh_run("1 + 1")
    end

    test "subsystem login" do
      start_supervised!({NervesSSH, subsystem_config()})
      # Short sleep to make sure server is up an running
      Process.sleep(200)

      assert {:ok, conn} =
               :ssh.connect(
                 '127.0.0.1',
                 ssh_port(),
                 [
                   silently_accept_hosts: true,
                   save_accepted_host: false,
                   user: 'test_user',
                   password: 'password',
                   user_dir: Path.absname("test/fixtures/good_user_dir") |> to_charlist()
                 ],
                 5000
               )

      assert {:ok, channel} = :ssh_connection.session_channel(conn, 5000)

      assert :success =
               :ssh_connection.ptty_alloc(conn, channel,
                 term: "dumb",
                 width: 80,
                 height: 25,
                 pty_opts: [echo: 1]
               )

      assert :success = :ssh_connection.subsystem(conn, channel, 'shell', 5000)

      assert :ok = :ssh_connection.send(conn, channel, "echo cool\n")
      assert :ok = :ssh_connection.send(conn, channel, "echo $TERM\n")
      assert :ok = :ssh_connection.send(conn, channel, "exit 0\n")

      result = receive_until_eof()
      assert result =~ "echo cool\r\n"
      assert result =~ "exit 0\r\n"
    end
  end
end
