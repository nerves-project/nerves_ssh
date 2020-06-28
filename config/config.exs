use Mix.Config

config :nerves_runtime,
  target: "host"

config :nerves_runtime, Nerves.Runtime.KV.Mock, %{"nerves_fw_devpath" => "/dev/will_not_work"}

config :nerves_ssh,
  authorized_keys: [File.read!("test/fixtures/good_user_dir/id_rsa.pub")],
  user_passwords: [
    {"test_user", "password"}
  ],
  port: 4022
