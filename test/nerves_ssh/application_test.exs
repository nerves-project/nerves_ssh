defmodule NervesSSH.ApplicationTest do
  # These tests modify the global application environment so they can't be run concurrently
  use ExUnit.Case, async: false

  @rsa_public_key String.trim(File.read!("test/fixtures/good_user_dir/id_rsa.pub"))

  defp ssh_run(cmd) do
    ssh_options = [
      ip: ~c"127.0.0.1",
      port: 2222,
      user_interaction: false,
      silently_accept_hosts: true,
      save_accepted_host: false,
      user: ~c"test_user",
      password: ~c"password",
      user_dir: Path.absname("test/fixtures/good_user_dir")
    ]

    # Short sleep to make sure server is up an running
    Process.sleep(200)

    with {:ok, conn} <- SSHEx.connect(ssh_options) do
      SSHEx.run(conn, cmd)
    end
  end

  @tag :has_good_sshd_exec
  test "stopping and starting the application" do
    # The application is running, but without a config. Stop
    # it, so that we can set a config and have it autostart.
    assert :ok == Application.stop(:nerves_ssh)

    Application.put_all_env([
      {:nerves_ssh,
       port: 2222,
       authorized_keys: [@rsa_public_key],
       user_dir: Path.absname("test/fixtures/system_dir"),
       system_dir: Path.absname("test/fixtures/system_dir")}
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
end
