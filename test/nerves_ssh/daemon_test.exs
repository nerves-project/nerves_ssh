defmodule NervesSSH.DaemonTest do
  use ExUnit.Case, async: false

  @username_login [
    user: 'test_user',
    password: 'password',
    user_dir: Path.absname("test/fixtures/good_user_dir")
  ]
  @key_login [user_dir: Path.absname("test/fixtures/good_user_dir")]

  defp ssh_run(cmd, options \\ @username_login) do
    ssh_options =
      [ip: '127.0.0.1', port: 4022, user_interaction: false, silently_accept_hosts: true]
      |> Keyword.merge(options)

    with {:ok, conn} <- SSHEx.connect(ssh_options) do
      SSHEx.run(conn, cmd)
    end
  end

  test "private key login" do
    assert {:ok, "2", 0} == ssh_run("1 + 1", @key_login)
  end

  test "username/password login" do
    assert {:ok, "2", 0} == ssh_run("1 + 1", @username_login)
  end

  test "can recover from sshd failure" do
    # Test we can send SSH command
    state = :sys.get_state(NervesSSH.Daemon)
    assert {:ok, "2", 0} == ssh_run("1 + 1")

    # Simulate sshd failure. restart
    Process.exit(state.sshd, :kill)
    :timer.sleep(800)

    # Test recovery
    new_state = :sys.get_state(NervesSSH.Daemon)
    assert state.sshd != new_state.sshd

    assert {:ok, "4", 0} == ssh_run("2 + 2")
  end

  test "stopping and starting the application" do
    assert {:ok, ":running_at_start?", 0} == ssh_run(":running_at_start?")

    assert :ok == Application.stop(:nerves_ssh)
    Process.sleep(500)
    assert {:error, :econnrefused} == ssh_run(":really_stopped?")

    assert :ok == Application.start(:nerves_ssh)
    assert {:ok, ":started_again?", 0} == ssh_run(":started_again?")
  end

  test "starting the application after terminate wasn't called" do
    assert :ok == Application.stop(:nerves_ssh)

    # Start a server up manually to simulate terminate not being called
    # to shut down the server.
    {:ok, _pid} =
      GenServer.start(
        NervesSSH.Daemon,
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
    assert :ok == Application.start(:nerves_ssh)
    assert {:ok, ":started_again?", 0} == ssh_run(":started_again?")
  end
end
