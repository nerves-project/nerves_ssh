defmodule NervesSSH.OptionsTest do
  use ExUnit.Case

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
      {:key_cb, {NervesSSH.Keys, [{:authorized_keys, []}]}},
      {:system_dir, '/etc/ssh'},
      {:shell, {Elixir.IEx, :start, [[dot_iex_path: ""]]}},
      # {:exec, &start_exec/3},
      {:subsystems,
       [
         :ssh_sftpd.subsystem_spec(cwd: '/'),
         NervesFirmwareSSH2.subsystem_spec()
       ]},
      {:inet, :inet6}
    ])
  end

  test "authorized keys passed individually" do
    opts = Options.new(authorized_keys: [@rsa_public_key, @ecdsa_public_key])
    daemon_options = Options.daemon_options(opts)

    assert daemon_options[:key_cb] ==
             {NervesSSH.Keys,
              [
                authorized_keys:
                  @rsa_public_key_decoded ++
                    @ecdsa_public_key_decoded
              ]}
  end

  test "authorized keys as one string" do
    opts = Options.new(authorized_keys: [@rsa_public_key <> "\n" <> @ecdsa_public_key])
    daemon_options = Options.daemon_options(opts)

    assert daemon_options[:key_cb] ==
             {NervesSSH.Keys,
              [
                authorized_keys:
                  @rsa_public_key_decoded ++
                    @ecdsa_public_key_decoded
              ]}
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
end
