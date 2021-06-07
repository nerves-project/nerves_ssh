defmodule NervesSshTest do
  use ExUnit.Case, async: false

  @nerves_ssh_config NervesSSH.Options.with_defaults(
                       authorized_keys: [File.read!("test/fixtures/good_user_dir/id_rsa.pub")],
                       user_passwords: [
                         {"test_user", "password"}
                       ],
                       port: 4022
                     )

  @username_login [
    user: 'test_user',
    password: 'password',
    user_dir: Path.absname("test/fixtures/good_user_dir")
  ]
  @key_login [user: 'anything_but_root', user_dir: Path.absname("test/fixtures/good_user_dir")]

  defp ssh_run(cmd, options \\ @username_login) do
    ssh_options =
      [ip: '127.0.0.1', port: 4022, user_interaction: false, silently_accept_hosts: true]
      |> Keyword.merge(options)

    # Short sleep to make sure server is up an running
    Process.sleep(100)

    with {:ok, conn} <- SSHEx.connect(ssh_options) do
      SSHEx.run(conn, cmd)
    end
  end

  @tag :has_good_sshd_exec
  test "private key login" do
    start_supervised!({NervesSSH, @nerves_ssh_config})
    assert {:ok, "2", 0} == ssh_run("1 + 1", @key_login)
  end

  @tag :has_good_sshd_exec
  test "username/password login" do
    start_supervised!({NervesSSH, @nerves_ssh_config})
    assert {:ok, "2", 0} == ssh_run("1 + 1", @username_login)
  end

  @tag :has_good_sshd_exec
  test "can recover from sshd failure" do
    start_supervised!({NervesSSH, @nerves_ssh_config})

    # Test we can send SSH command
    state = :sys.get_state(NervesSSH)
    assert {:ok, "2", 0} == ssh_run("1 + 1")

    # Simulate sshd failure. restart
    Process.exit(state.sshd, :kill)
    :timer.sleep(800)

    # Test recovery
    new_state = :sys.get_state(NervesSSH)
    assert state.sshd != new_state.sshd

    assert {:ok, "4", 0} == ssh_run("2 + 2")
  end

  @tag :has_good_sshd_exec
  test "stopping and starting the application" do
    # The application is running, but without a config. Stop
    # it, so that we can set a config and have it autostart.
    assert :ok == Application.stop(:nerves_ssh)

    Application.put_all_env([
      {:nerves_ssh,
       port: 4022,
       authorized_keys: [
         File.read!("test/fixtures/good_user_dir/id_rsa.pub")
       ]}
    ])

    assert :ok == Application.start(:nerves_ssh)
    Process.sleep(25)
    assert {:ok, ":started_once?", 0} == ssh_run(":started_once?")

    assert :ok == Application.stop(:nerves_ssh)
    Process.sleep(25)
    assert {:error, :econnrefused} == ssh_run(":really_stopped?")

    assert :ok == Application.start(:nerves_ssh)
    Process.sleep(25)
    assert {:ok, ":started_again?", 0} == ssh_run(":started_again?")

    assert :ok == Application.stop(:nerves_ssh)
    Application.put_all_env(nerves_ssh: [])
    Process.sleep(25)
  end

  @tag :has_good_sshd_exec
  test "starting the application after terminate wasn't called" do
    # Start a server up manually to simulate terminate not being called
    # to shut down the server.
    {:ok, _pid} =
      GenServer.start(
        NervesSSH,
        NervesSSH.Options.new(
          user_passwords: [{"test_user", "not_the_right_password"}],
          port: 4022,
          system_dir: :code.priv_dir(:nerves_ssh)
        )
      )

    # Verify that the old server has started and that it won't accept
    # the test credentials.
    assert {:error, 'Unable to connect using the available authentication methods'} ==
             ssh_run(":started_again?")

    # Start the real server up. It should kill our old one.
    start_supervised!({NervesSSH, @nerves_ssh_config})
    Process.sleep(25)
    assert {:ok, ":started_again?", 0} == ssh_run(":started_again?")
  end
end
