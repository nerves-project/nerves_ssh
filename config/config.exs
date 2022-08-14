import Config

config :nerves_runtime,
  target: "host"

config :nerves_runtime, Nerves.Runtime.KV.Mock, %{"nerves_fw_devpath" => "/dev/will_not_work"}

if System.get_env("CI") == "true" or System.cmd("whoami", []) == {"root\n", 0} do
  config :erlexec,
    root: true,
    user: "root",
    limit_users: ["root"]
end
