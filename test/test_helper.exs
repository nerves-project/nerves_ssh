# SPDX-FileCopyrightText: 2020 Frank Hunleth
#
# SPDX-License-Identifier: Apache-2.0
#
otp_version = System.otp_release() |> Integer.parse() |> elem(0)

# The OTP ssh exec option is only documented for OTP 23 and later. The undocumented version
# kind of works, but has quirks, so don't test it.
exclude = if otp_version >= 23, do: [], else: [has_good_sshd_exec: true]

# mix nerves_ssh.add_user adds a separate config :nerves_ssh before Elixir 1.17
exclude =
  if Version.match?(System.version(), ">= 1.17.0"),
    do: exclude,
    else: [merges_config: true] ++ exclude

ExUnit.start(exclude: exclude, capture_log: true)
