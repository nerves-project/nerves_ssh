defmodule NervesSshTest do
  use ExUnit.Case, async: true

  decode_fun =
    if String.to_integer(System.otp_release()) >= 24 do
      &:ssh_file.decode/2
    else
      &:public_key.ssh_decode/2
    end

  @username_login [
    user: 'test_user',
    password: 'password',
    user_dir: Path.absname("test/fixtures/good_user_dir")
  ]
  @key_login [user: 'anything_but_root', user_dir: Path.absname("test/fixtures/good_user_dir")]
  @base_ssh_port 4022
  @rsa_public_key String.trim(File.read!("test/fixtures/good_user_dir/id_rsa.pub"))
  @ed25519_public_key String.trim(File.read!("test/fixtures/good_user_dir/id_ed25519.pub"))
  @ed25519_public_key_decoded elem(hd(decode_fun.(@ed25519_public_key, :auth_keys)), 0)

  defp nerves_ssh_config() do
    NervesSSH.Options.with_defaults(
      authorized_keys: [@rsa_public_key],
      user_passwords: [
        {"test_user", "password"}
      ],
      system_dir: Path.absname("test/fixtures/system_dir"),
      user_dir: Path.absname("test/fixtures/system_dir"),
      port: ssh_port()
    )
  end

  defp ssh_run(cmd, options \\ @username_login) do
    ssh_options =
      [
        ip: '127.0.0.1',
        port: ssh_port(),
        user_interaction: false,
        silently_accept_hosts: true,
        save_accepted_host: false
      ]
      |> Keyword.merge(options)

    # Short sleep to make sure server is up an running
    Process.sleep(200)

    with {:ok, conn} <- SSHEx.connect(ssh_options) do
      SSHEx.run(conn, cmd)
    end
  end

  defp ssh_port() do
    Process.get(:ssh_port)
  end

  setup context do
    # Use unique ssh port numbers for each test to support async: true
    Process.put(:ssh_port, @base_ssh_port + context.line)
    :ok
  end

  @tag :has_good_sshd_exec
  test "private key login" do
    start_supervised!({NervesSSH, nerves_ssh_config()})
    assert {:ok, "2", 0} == ssh_run("1 + 1", @key_login)
  end

  @tag :has_good_sshd_exec
  test "username/password login" do
    start_supervised!({NervesSSH, nerves_ssh_config()})
    assert {:ok, "2", 0} == ssh_run("1 + 1", @username_login)
  end

  @tag :has_good_sshd_exec
  test "can recover from sshd failure" do
    start_supervised!({NervesSSH, nerves_ssh_config()})

    # Test we can send SSH command
    state = :sys.get_state(NervesSSH)
    assert {:ok, "2", 0} == ssh_run("1 + 1")

    # Simulate sshd failure. restart
    Process.exit(state.sshd, :kill)
    Process.sleep(800)

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
       port: ssh_port(),
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

  @tag :has_good_sshd_exec
  test "starting the application after terminate wasn't called" do
    # Start a server up manually to simulate terminate not being called
    # to shut down the server.
    {:ok, _pid} =
      GenServer.start(
        NervesSSH,
        NervesSSH.Options.new(
          user_passwords: [{"test_user", "not_the_right_password"}],
          port: ssh_port(),
          system_dir: Path.absname("test/fixtures/system_dir"),
          user_dir: Path.absname("test/fixtures/system_dir")
        )
      )

    # Verify that the old server has started and that it won't accept
    # the test credentials.
    assert {:error, 'Unable to connect using the available authentication methods'} ==
             ssh_run(":started_again?")

    # Start the real server up. It should kill our old one.
    start_supervised!({NervesSSH, nerves_ssh_config()})
    Process.sleep(25)
    assert {:ok, ":started_again?", 0} == ssh_run(":started_again?")
  end

  @tag :has_good_sshd_exec
  test "erlang exec works" do
    options = %{nerves_ssh_config() | shell: :erlang, exec: :erlang}
    start_supervised!({NervesSSH, options})
    assert {:ok, "3", 0} == ssh_run("1 + 2.", @username_login)
  end

  @tag :has_good_sshd_exec
  test "lfe exec works" do
    start_supervised!({NervesSSH, Map.put(nerves_ssh_config(), :exec, :lfe)})
    assert {:ok, "2", 0} == ssh_run("(+ 1 1)", @username_login)
  end

  @tag :has_good_sshd_exec
  test "SCP download" do
    start_supervised!({NervesSSH, nerves_ssh_config()})
    assert {:ok, "2", 0} == ssh_run("1 + 1", @key_login)

    filename = "test_download.txt"
    download_path = "/tmp/#{filename}"

    File.chmod!("test/fixtures/good_user_dir/id_rsa", 0o600)
    File.rm_rf!(filename)
    File.rm_rf!(download_path)

    File.write!(download_path, "asdf")

    {_output, 0} =
      System.cmd("scp", [
        "-o",
        "UserKnownHostsFile /dev/null",
        "-o",
        "StrictHostKeyChecking no",
        "-i",
        "test/fixtures/good_user_dir/id_rsa",
        "-P",
        "#{ssh_port()}",
        "test_user@localhost:#{download_path}",
        "#{filename}"
      ])

    assert File.read!(filename) == "asdf"
  end

  @tag :has_good_sshd_exec
  test "SCP upload" do
    start_supervised!({NervesSSH, nerves_ssh_config()})
    assert {:ok, "2", 0} == ssh_run("1 + 1", @key_login)

    filename = "test_upload.txt"
    upload_path = "/tmp/#{filename}"

    File.chmod!("test/fixtures/good_user_dir/id_rsa", 0o600)
    File.rm_rf!(filename)
    File.rm_rf!(upload_path)

    File.write!(filename, "asdf")

    {_output, 0} =
      System.cmd("scp", [
        "-o",
        "UserKnownHostsFile /dev/null",
        "-o",
        "StrictHostKeyChecking no",
        "-i",
        "test/fixtures/good_user_dir/id_rsa",
        "-P",
        "#{ssh_port()}",
        filename,
        "test_user@localhost:#{upload_path}"
      ])

    assert File.read!(upload_path) == "asdf"
  end

  @tag :has_good_sshd_exec
  test "adding public key at runtime" do
    tmp_user_dir = "/tmp/nerves_ssh/user_dir-add_key-#{:rand.uniform(1000)}"
    File.rm_rf!(tmp_user_dir)
    on_exit(fn -> File.rm_rf!(tmp_user_dir) end)

    config = %{
      nerves_ssh_config()
      | user_dir: tmp_user_dir,
        authorized_keys: [],
        decoded_authorized_keys: []
    }

    start_supervised!({NervesSSH, config})

    assert {:error, _} = ssh_run("1 + 1", @key_login)

    NervesSSH.add_authorized_key(@ed25519_public_key)
    new_opts = NervesSSH.configuration()

    assert new_opts.authorized_keys == [@ed25519_public_key]
    assert new_opts.decoded_authorized_keys == [@ed25519_public_key_decoded]
    assert File.exists?(Path.join(tmp_user_dir, "authorized_keys"))

    assert {:ok, "2", 0} == ssh_run("1 + 1", @key_login)
  end

  @tag :has_good_sshd_exec
  test "removing public key at runtime" do
    tmp_user_dir = "/tmp/nerves_ssh/user_dir-add_key-#{:rand.uniform(1000)}"
    File.rm_rf!(tmp_user_dir)
    on_exit(fn -> File.rm_rf!(tmp_user_dir) end)

    config = %{
      nerves_ssh_config()
      | user_dir: tmp_user_dir,
        authorized_keys: [@ed25519_public_key]
    }

    start_supervised!({NervesSSH, config})

    assert {:ok, "2", 0} == ssh_run("1 + 1", @key_login)

    NervesSSH.remove_authorized_key(@ed25519_public_key)
    new_opts = NervesSSH.configuration()

    assert new_opts.authorized_keys == []
    assert new_opts.decoded_authorized_keys == []

    assert {:error, _} = ssh_run("1 + 1", @key_login)
  end

  @tag :has_good_sshd_exec
  test "adding user/password at runtime" do
    start_supervised!({NervesSSH, nerves_ssh_config()})
    refute {:ok, "2", 0} == ssh_run("1 + 1", user: 'jon', password: 'wat')
    NervesSSH.add_user("jon", "wat")
    assert {:ok, "2", 0} == ssh_run("1 + 1", user: 'jon', password: 'wat')
  end

  @tag :has_good_sshd_exec
  test "removing user/password at runtime" do
    start_supervised!({NervesSSH, nerves_ssh_config()})
    login = Keyword.drop(@username_login, [:user_dir])
    assert {:ok, "2", 0} == ssh_run("1 + 1", login)
    NervesSSH.remove_user("#{login[:user]}")
    refute {:ok, "2", 0} == ssh_run("1 + 1", login)
  end
end
