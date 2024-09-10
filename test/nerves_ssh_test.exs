defmodule NervesSSHTest do
  use ExUnit.Case, async: true

  decode_fun =
    if String.to_integer(System.otp_release()) >= 24 do
      &:ssh_file.decode/2
    else
      &:public_key.ssh_decode/2
    end

  @username_login [
    user: ~c"test_user",
    password: ~c"password",
    user_dir: Path.absname("test/fixtures/good_user_dir")
  ]
  @key_login [user: ~c"anything_but_root", user_dir: Path.absname("test/fixtures/good_user_dir")]
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
        ip: ~c"127.0.0.1",
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
    Process.put(:ssh_port, @base_ssh_port + :erlang.phash2({context.module, context.test}, 10000))
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
    assert {:error, ~c"Unable to connect using the available authentication methods"} ==
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

    # SCP can sometimes return 1 even when it succeeds,
    # so we'll just ignore the return here and rely on the file
    # check below
    _ =
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

    assert File.exists?(filename)
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

    # SCP can sometimes return 1 even when it succeeds,
    # so we'll just ignore the return here and rely on the file
    # check below
    _ =
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

    assert File.exists?(upload_path)
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
    refute {:ok, "2", 0} == ssh_run("1 + 1", user: ~c"jon", password: ~c"wat")
    NervesSSH.add_user("jon", "wat")
    assert {:ok, "2", 0} == ssh_run("1 + 1", user: ~c"jon", password: ~c"wat")
  end

  @tag :has_good_sshd_exec
  test "removing user/password at runtime" do
    start_supervised!({NervesSSH, nerves_ssh_config()})
    login = Keyword.drop(@username_login, [:user_dir])
    assert {:ok, "2", 0} == ssh_run("1 + 1", login)
    NervesSSH.remove_user("#{login[:user]}")
    refute {:ok, "2", 0} == ssh_run("1 + 1", login)
  end

  @tag :has_good_sshd_exec
  test "can start multiple named daemons" do
    config = nerves_ssh_config() |> Map.put(:name, :daemon_a)
    other_config = %{config | name: :daemon_b, port: config.port + 1}
    # start two servers, starting with identical configs, except the port
    start_supervised!(Supervisor.child_spec({NervesSSH, config}, id: :daemon_a))

    start_supervised!(Supervisor.child_spec({NervesSSH, other_config}, id: :daemon_b))

    assert {:ok, "2", 0} == ssh_run("1 + 1", @key_login)

    # login with username and password at :daemon_b
    assert {:ok, "2", 0} ==
             ssh_run("1 + 1", Keyword.put(@username_login, :port, other_config.port))

    # try to login with other user that is only added later
    refute {:ok, "2", 0} ==
             ssh_run("1 + 1", port: other_config.port, user: ~c"jon", password: ~c"wat")

    # add new user to :daemon_b
    NervesSSH.add_user(:daemon_b, "jon", "wat")

    assert {:ok, "2", 0} ==
             ssh_run("1 + 1", port: other_config.port, user: ~c"jon", password: ~c"wat")

    # :daemon_a must be unaffected
    refute {:ok, "2", 0} == ssh_run("1 + 1", user: ~c"jon", password: ~c"wat")
  end
end
