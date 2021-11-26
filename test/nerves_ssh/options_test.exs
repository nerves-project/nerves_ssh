defmodule NervesSSH.OptionsTest do
  use ExUnit.Case
  use Bitwise

  alias NervesSSH.Options

  @rsa_public_key "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDT6lRp4wT80iA/GW2Vo+d37ytXGZ/e03h8znlPtwybn9k9ZDbx+EAc7jPNJmXsy7+lIpWGfYtBlgKZomEDYKI7HOSfQTtPS6mWRaHbP58lSkunLEL851kh3HO3/ikaC+TXZJEMtb+5NTJ+vwqg2ysrUlz1L91M0AQNk73eW+KLh/pSDsH5XCvVSWqrpMiHySL4IQV9eY+/4Q9Pq9D9vBk/jaSRXWhTUxo09IYxgVnYK2Sd9gxF97cM7mCQdj6A38bfMFrOZManlbGReUwpFoBWsIIDbGYvNBMsVQF7WLy0FGt4UGqYTZUppWZTEpkmiyMwPCVwBsfJtyXh1gQzU4iH"
  @rsa_public_key_decoded :public_key.ssh_decode(@rsa_public_key, :auth_keys)
  @ecdsa_public_key "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBK9UY+mjrTRdnO++HmV3TbSJkTkyR1tEqz0dITc3TD4l+WWIqvbOtUg2MN/Tg+bWtvD6aEX7/fjCGTxwe7BmaoI="
  @ecdsa_public_key_decoded :public_key.ssh_decode(@ecdsa_public_key, :auth_keys)

  defp assert_options(got, expected) do
    for option <- expected do
      assert Enum.member?(got, option)
    end
  end

  test "default options match expected" do
    opts = Options.new()
    daemon_options = Options.daemon_options(opts)

    assert opts.port == 22

    assert_options(daemon_options, [
      {:id_string, :random},
      {:system_dir, '/data/nerves_ssh'},
      # {:shell, {Elixir.IEx, :start, [[dot_iex_path: @dot_iex_path]]}},
      # {:exec, &start_exec/3},
      {:subsystems, [:ssh_sftpd.subsystem_spec(cwd: '/')]},
      {:inet, :inet6}
    ])

    {NervesSSH.Keys, key_cb_private} = daemon_options[:key_cb]
    assert key_cb_private[:authorized_keys] == []
    assert map_size(key_cb_private[:host_keys]) > 0
  end

  test "Options.new/1 shows user dot_iex_path" do
    opts = Options.new(iex_opts: [dot_iex_path: "/my/iex.exs"])
    assert opts.iex_opts[:dot_iex_path] == "/my/iex.exs"
  end

  test "authorized keys passed individually" do
    opts = Options.new(authorized_keys: [@rsa_public_key, @ecdsa_public_key])
    daemon_options = Options.daemon_options(opts)

    {NervesSSH.Keys, key_cb_private} = daemon_options[:key_cb]

    assert key_cb_private[:authorized_keys] ==
             @rsa_public_key_decoded ++ @ecdsa_public_key_decoded
  end

  test "authorized keys as one string" do
    opts = Options.new(authorized_keys: [@rsa_public_key <> "\n" <> @ecdsa_public_key])
    daemon_options = Options.daemon_options(opts)

    {NervesSSH.Keys, key_cb_private} = daemon_options[:key_cb]

    assert key_cb_private[:authorized_keys] ==
             @rsa_public_key_decoded ++ @ecdsa_public_key_decoded
  end

  test "username/passwords are turned into charlists" do
    opts = Options.new(user_passwords: [{"alice", "password"}, {"bob", "1234"}])
    daemon_options = Options.daemon_options(opts)

    assert daemon_options[:user_passwords] ==
             [{'alice', 'password'}, {'bob', '1234'}]
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
      sys_dir = '/tmp/nerves_ssh/sys_#{context.algorithm}-#{:rand.uniform(1000)}'
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
end
