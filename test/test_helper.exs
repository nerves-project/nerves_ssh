otp_version = System.otp_release() |> Integer.parse() |> elem(0)

# The OTP ssh exec option is only documented for OTP 23 and later. The undocumented version
# kind of works, but has quirks, so don't test it.
exclude = if otp_version >= 23, do: [], else: [has_good_sshd_exec: true]

System.put_env("SHELL", System.find_executable("sh"))

ExUnit.start(exclude: exclude, capture_log: true)
