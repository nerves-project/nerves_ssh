defmodule NervesSSH.OptionsTest do
  use ExUnit.Case
  import Bitwise

  alias NervesSSH.Options

  decode_fun =
    if String.to_integer(System.otp_release()) >= 24 do
      &:ssh_file.decode/2
    else
      &:public_key.ssh_decode/2
    end

  @rsa_public_key String.trim(File.read!("test/fixtures/good_user_dir/id_rsa.pub"))
  @rsa_public_key_decoded elem(hd(decode_fun.(@rsa_public_key, :auth_keys)), 0)
  @ecdsa_public_key "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBK9UY+mjrTRdnO++HmV3TbSJkTkyR1tEqz0dITc3TD4l+WWIqvbOtUg2MN/Tg+bWtvD6aEX7/fjCGTxwe7BmaoI="
  @ecdsa_public_key_decoded elem(hd(decode_fun.(@ecdsa_public_key, :auth_keys)), 0)

  defp assert_options(got, expected) do
    for option <- expected do
      assert Enum.member?(got, option)
    end
  end

  test "default options match expected" do
    opts = Options.new()
    daemon_options = Options.daemon_options(opts)

    assert opts.system_dir == "/data/nerves_ssh"
    assert opts.user_dir == "/data/nerves_ssh/default_user"
    assert opts.port == 22

    assert_options(daemon_options, [
      {:id_string, :random},
      # {:shell, {Elixir.IEx, :start, [[dot_iex_path: @dot_iex_path]]}},
      # {:exec, &start_exec/3},
      {:subsystems, [:ssh_sftpd.subsystem_spec(cwd: ~c"/")]},
      {:inet, :inet6}
    ])

    {NervesSSH.Keys, key_cb_private} = daemon_options[:key_cb]
    assert map_size(key_cb_private[:host_keys]) > 0
  end

  test "fwup subsystem can be changed" do
    subsystem = {~c"fwup", {SSHSubsystemFwup, []}}

    opts =
      Options.with_defaults(
        subsystems: [
          subsystem
        ]
      )

    assert opts.subsystems == [subsystem]
  end

  test "Options.new/1 shows user dot_iex_path" do
    opts = Options.new(iex_opts: [dot_iex_path: "/my/iex.exs"])
    assert opts.iex_opts[:dot_iex_path] == "/my/iex.exs"
  end

  test "authorized keys passed individually" do
    opts = Options.new(authorized_keys: [@rsa_public_key, @ecdsa_public_key])
    assert opts.decoded_authorized_keys == [@rsa_public_key_decoded, @ecdsa_public_key_decoded]
  end

  test "authorized keys as one string" do
    opts = Options.new(authorized_keys: [@rsa_public_key <> "\n" <> @ecdsa_public_key])
    assert opts.decoded_authorized_keys == [@rsa_public_key_decoded, @ecdsa_public_key_decoded]
  end

  test "add authorized keys" do
    opts = Options.new()
    assert opts.authorized_keys == []

    added =
      opts
      |> Options.add_authorized_key(@rsa_public_key)
      |> Options.add_authorized_key(@ecdsa_public_key)

    assert added.authorized_keys == [@rsa_public_key, @ecdsa_public_key]
    assert added.decoded_authorized_keys == [@rsa_public_key_decoded, @ecdsa_public_key_decoded]
  end

  test "remove authorized key" do
    opts = Options.new(authorized_keys: [@rsa_public_key, @ecdsa_public_key])
    assert opts.authorized_keys == [@rsa_public_key, @ecdsa_public_key]
    assert opts.decoded_authorized_keys == [@rsa_public_key_decoded, @ecdsa_public_key_decoded]

    removed = Options.remove_authorized_key(opts, @rsa_public_key)

    assert removed.authorized_keys == [@ecdsa_public_key]
    assert removed.decoded_authorized_keys == [@ecdsa_public_key_decoded]
  end

  test "load authorized keys from file" do
    opts =
      Options.new(user_dir: "test/fixtures/system_dir")
      |> Options.load_authorized_keys()

    assert opts.authorized_keys == [@rsa_public_key]
    assert opts.decoded_authorized_keys == [@rsa_public_key_decoded]
  end

  test "can save authorized_keys to file" do
    user_dir = ~c"/tmp/nerves_ssh/user_dir-#{:rand.uniform(1000)}"
    authorized_keys = Path.join(user_dir, "authorized_keys")
    File.rm_rf!(user_dir)
    File.mkdir_p!(user_dir)
    on_exit(fn -> File.rm_rf!(user_dir) end)

    %Options{user_dir: user_dir, authorized_keys: [@rsa_public_key]}
    |> Options.save_authorized_keys()

    assert File.exists?(authorized_keys)
    assert String.contains?(File.read!(authorized_keys), @rsa_public_key)
  end

  test "username/passwords turn on the pwdfun option" do
    opts = Options.new(user_passwords: [{"alice", "password"}, {"bob", "1234"}])
    daemon_options = Options.daemon_options(opts)

    assert daemon_options[:pwdfun]
  end

  test "adding user/password to options" do
    opts = Options.new()

    assert opts.user_passwords == []

    updated =
      opts
      |> Options.add_user("jon", "wat")
      |> Options.add_user("frank", "")
      |> Options.add_user("connor", nil)

    assert updated.user_passwords == [
             {"connor", nil},
             {"frank", ""},
             {"jon", "wat"}
           ]
  end

  test "removing user from options" do
    opts = Options.new(user_passwords: [{"howdy", "partner"}])

    assert Options.remove_user(opts, "howdy").user_passwords == []
  end

  test "adding daemon options" do
    opts = Options.new(daemon_option_overrides: [my_option: 1])
    daemon_options = Options.daemon_options(opts)

    assert daemon_options[:my_option] == 1
  end

  test "overriding daemon options" do
    # First check that the default is still inet6
    opts = Options.new()
    daemon_options = Options.daemon_options(opts)
    assert daemon_options[:inet] == :inet6

    # Now check that it can be overridden.
    opts = Options.new(daemon_option_overrides: [inet: :inet])
    daemon_options = Options.daemon_options(opts)

    assert daemon_options[:inet] == :inet
  end

  test "sanitizing out bad subsystems" do
    opts = Options.new(subsystems: ["hello"]) |> Options.sanitize()
    daemon_options = Options.daemon_options(opts)
    assert daemon_options[:subsystems] == []
  end

  test "defaults don't need sanitization" do
    opts = Options.new()

    assert opts == Options.sanitize(opts)
  end

  describe "system host keys" do
    setup context do
      sys_dir = ~c"/tmp/nerves_ssh/sys_#{context.algorithm}-#{:rand.uniform(1000)}"
      File.rm_rf!(sys_dir)
      File.mkdir_p!(sys_dir)
      on_exit(fn -> File.rm_rf!(sys_dir) end)
      [sys_dir: sys_dir]
    end

    @tag algorithm: :ed25519
    test "can generate an Ed25519 host key when missing", %{sys_dir: sys_dir} do
      refute File.exists?(Path.join(sys_dir, "ssh_host_ed25519_key"))

      daemon_opts = Options.daemon_options(Options.new(system_dir: sys_dir))
      {NervesSSH.Keys, key_cb_private} = daemon_opts[:key_cb]

      assert key_cb_private[:host_keys][:"ssh-ed25519"]

      key_path = Path.join(sys_dir, "ssh_host_ed25519_key")
      assert File.exists?(key_path)
      assert (File.stat!(key_path).mode &&& 0o777) == 0o600
    end

    @tag algorithm: :ed25519
    test "can generate an Ed25519 host key when file is bad", %{sys_dir: sys_dir} do
      # assert {:ok, _key} = NervesSSH.Keys.host_key(unquote(alg), system_dir: sys_dir)
      file = Path.join(sys_dir, "ssh_host_ed25519_key")
      File.write!(file, "this is a bad key")

      daemon_opts = Options.daemon_options(Options.new(system_dir: sys_dir))
      {NervesSSH.Keys, key_cb_private} = daemon_opts[:key_cb]

      assert key_cb_private[:host_keys][:"ssh-ed25519"]

      assert File.exists?(Path.join(sys_dir, "ssh_host_ed25519_key"))
    end

    @tag algorithm: :rsa
    test "Falls back to RSA when no host keys and Ed25519 is not supported", %{sys_dir: sys_dir} do
      refute File.exists?(Path.join(sys_dir, "ssh_host_rsa_key"))

      daemon_opts =
        Options.new(
          system_dir: sys_dir,
          daemon_option_overrides: [modify_algorithms: [rm: [public_key: [:"ssh-ed25519"]]]]
        )
        |> Options.daemon_options()

      {NervesSSH.Keys, key_cb_private} = daemon_opts[:key_cb]

      assert key_cb_private[:host_keys][:"rsa-sha2-512"]
      assert key_cb_private[:host_keys][:"rsa-sha2-256"]
      assert key_cb_private[:host_keys][:"ssh-rsa"]

      assert File.exists?(Path.join(sys_dir, "ssh_host_rsa_key"))
    end

    @tag algorithm: :rsa
    test "can generate an RSA host key when no host keys, Ed25519 is not supported, and RSA file is bad",
         %{sys_dir: sys_dir} do
      file = Path.join(sys_dir, "ssh_host_rsa_key")
      File.write!(file, "this is a bad key")

      daemon_opts =
        Options.new(
          system_dir: sys_dir,
          daemon_option_overrides: [modify_algorithms: [rm: [public_key: [:"ssh-ed25519"]]]]
        )
        |> Options.daemon_options()

      {NervesSSH.Keys, key_cb_private} = daemon_opts[:key_cb]

      assert key_cb_private[:host_keys][:"rsa-sha2-512"]
      assert key_cb_private[:host_keys][:"rsa-sha2-256"]
      assert key_cb_private[:host_keys][:"ssh-rsa"]

      assert File.exists?(Path.join(sys_dir, "ssh_host_rsa_key"))
    end
  end

  test "system and user dirs default to /tmp when not existing" do
    sys = "/tmp/some-system"
    user = "/tmp/some-user"
    File.touch(sys)
    File.touch(user)
    opts = Options.new(system_dir: sys, user_dir: user)
    daemon_options = Options.daemon_options(opts)

    assert_options(daemon_options, [
      {:system_dir, ~c"/tmp/nerves_ssh/tmp/some-system"},
      {:user_dir, ~c"/tmp/nerves_ssh/tmp/some-user"}
    ])
  end
end
