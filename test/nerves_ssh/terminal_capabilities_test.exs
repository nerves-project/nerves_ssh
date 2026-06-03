# SPDX-FileCopyrightText: 2025 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesSSH.TerminalCapabilitiesTest do
  use ExUnit.Case, async: false

  alias NervesSSH.TerminalCapabilities

  @system_dir Path.absname("test/fixtures/system_dir")

  # A kitty-class terminal's answers to the detection batch, in query order.
  @kitty_bundle IO.iodata_to_binary([
                  # XTVERSION
                  "\eP>|kitty(0.32.0)\e\\",
                  # kitty keyboard flags
                  "\e[?1u",
                  # DECRPM synchronized output: 2 = reset/supported
                  "\e[?2026;2$y",
                  # kitty graphics ok
                  "\e_Gi=31;OK\e\\",
                  # DA1: 62 = VT220, 4 = sixel
                  "\e[?62;4c"
                ])

  describe "parse/1" do
    test "parses a full kitty-class response" do
      caps = TerminalCapabilities.parse(@kitty_bundle)

      assert caps.queried?
      assert caps.term == "kitty(0.32.0)"
      assert caps.primary_da == "62;4"
      assert caps.sixel
      assert caps.kitty_graphics
      assert caps.kitty_keyboard
      assert caps.synchronized_output
    end

    test "a plain DA1-only response detects nothing extra" do
      caps = TerminalCapabilities.parse("\e[?62c")

      assert caps.queried?
      assert caps.primary_da == "62"
      refute caps.sixel
      refute caps.kitty_graphics
      refute caps.kitty_keyboard
      refute caps.synchronized_output
    end

    test "sixel is taken from DA1 attribute 4" do
      assert TerminalCapabilities.parse("\e[?62;4;6c").sixel
      refute TerminalCapabilities.parse("\e[?62;22c").sixel
    end

    test "synchronized output requires a recognized DECRPM value" do
      assert TerminalCapabilities.parse("\e[?2026;1$y\e[?62c").synchronized_output
      assert TerminalCapabilities.parse("\e[?2026;2$y\e[?62c").synchronized_output
      # 0 = not recognized, 4 = permanently reset
      refute TerminalCapabilities.parse("\e[?2026;0$y\e[?62c").synchronized_output
      refute TerminalCapabilities.parse("\e[?2026;4$y\e[?62c").synchronized_output
    end

    test "an empty response (terminal didn't answer) is queried but all-false" do
      caps = TerminalCapabilities.parse("")
      assert caps.queried?
      assert caps.primary_da == nil
      refute caps.kitty_graphics
    end
  end

  describe "per-connection detection over SSH" do
    setup %{line: line} do
      # The capability registry normally lives in the :nerves_ssh app
      # supervision tree, but ApplicationTest stops the app and leaves it
      # stopped. Make sure the registry is up regardless of test ordering.
      unless Process.whereis(NervesSSH.TerminalCapabilities.Registry) do
        start_supervised!(NervesSSH.TerminalCapabilities.Registry)
      end

      port = 4500 + line
      {:ok, port: port}
    end

    test "detects a kitty-class terminal and exposes it to the session", %{port: port} do
      start_daemon(port, true)
      result = run_session(port, answer: @kitty_bundle)
      assert result == "kg=true,sx=true,q=true"
    end

    test "a non-responding terminal yields queried? with no features", %{port: port} do
      start_daemon(port, timeout: 300)
      result = run_session(port, answer: nil)
      assert result == "kg=false,sx=false,q=true"
    end

    test "detection can be disabled", %{port: port} do
      start_daemon(port, false)
      result = run_session(port, answer: nil)
      assert result == "none"
    end
  end

  # --- helpers ---

  defp start_daemon(port, detect) do
    opts =
      NervesSSH.Options.with_defaults(
        user_passwords: [{"u", "p"}],
        system_dir: @system_dir,
        user_dir: @system_dir,
        port: port,
        detect_terminal_capabilities: detect
      )

    start_supervised!({NervesSSH, opts})
    # let the daemon bind
    Process.sleep(150)
  end

  # Connect, allocate a pty, start the shell, optionally answer the detection
  # query batch, then drive the IEx prompt to print the detected capabilities.
  defp run_session(port, opts) do
    answer = Keyword.get(opts, :answer)

    {:ok, conn} =
      :ssh.connect(~c"127.0.0.1", port, [
        {:user, ~c"u"},
        {:password, ~c"p"},
        {:user_interaction, false},
        {:silently_accept_hosts, true},
        {:save_accepted_host, false}
      ])

    {:ok, ch} = :ssh_connection.session_channel(conn, 5000)
    :success = :ssh_connection.ptty_alloc(conn, ch, [{:term, ~c"xterm-kitty"}])
    :ok = :ssh_connection.shell(conn, ch)

    # "RESULT" and the value text are assembled at runtime so they never appear
    # in the command's local echo -- only in the real output.
    # `\#{...}` keeps the interpolation literal here so it runs on the *remote*
    # IEx, not at compile time. `\r` submits the line via the SSH line editor.
    cmd =
      "IO.puts(\"RES\" <> \"ULT\" <> \":\" <> (case NervesSSH.TerminalCapabilities.get() do nil -> \"none\"; c -> \"kg=\#{c.kitty_graphics},sx=\#{c.sixel},q=\#{c.queried?}\" end))\r"

    state = %{acc: "", answer: answer, answered: false, sent_cmd: false, cmd: cmd}
    out = drive(conn, ch, state, 10_000)
    :ssh.close(conn)
    out
  end

  defp drive(conn, ch, state, timeout) do
    receive do
      {:ssh_cm, ^conn, {:data, ^ch, _type, data}} ->
        state = %{state | acc: state.acc <> data}
        state = maybe_answer(conn, ch, state)
        state = maybe_send_cmd(conn, ch, state)

        case extract_result(state.acc) do
          nil -> drive(conn, ch, state, timeout)
          result -> result
        end

      {:ssh_cm, ^conn, {:closed, ^ch}} ->
        extract_result(state.acc) || {:closed, state.acc}

      {:ssh_cm, ^conn, _other} ->
        drive(conn, ch, state, timeout)
    after
      timeout -> {:timeout, extract_result(state.acc), state.acc}
    end
  end

  # Respond to the DA1 query (end of the detection batch) once.
  defp maybe_answer(conn, ch, %{answered: false} = state) do
    if String.contains?(state.acc, "\e[c") do
      if is_binary(state.answer), do: :ssh_connection.send(conn, ch, 0, state.answer)
      %{state | answered: true}
    else
      state
    end
  end

  defp maybe_answer(_conn, _ch, state), do: state

  # Once the IEx prompt appears, send the probe command once.
  defp maybe_send_cmd(conn, ch, %{sent_cmd: false} = state) do
    if String.contains?(state.acc, "iex(") do
      :ssh_connection.send(conn, ch, 0, state.cmd)
      %{state | sent_cmd: true}
    else
      state
    end
  end

  defp maybe_send_cmd(_conn, _ch, state), do: state

  defp extract_result(acc) do
    case Regex.run(~r/RESULT:([^\r\n]*)/, acc) do
      [_, payload] -> payload
      _ -> nil
    end
  end
end
