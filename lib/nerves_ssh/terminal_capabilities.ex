# SPDX-FileCopyrightText: 2025 Lars Wikman
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule NervesSSH.TerminalCapabilities do
  @moduledoc """
  Per-connection detection of modern terminal features.

  When an interactive SSH session starts, NervesSSH can query the connecting
  terminal for the features it supports and remember the answers for the life of
  that session. Unlike `TERM`/environment sniffing (which doesn't survive the
  hop onto a Nerves device), this works by sending escape-sequence *queries* and
  reading the terminal's *responses* back over the SSH pty.

  Detection happens in the `t:IEx` shell-startup callback, before the prompt is
  shown, so it adds at most one `:timeout` (default #{500} ms) to session
  startup when the terminal doesn't answer.

  ## Querying from inside a session

      iex> NervesSSH.TerminalCapabilities.get()
      %NervesSSH.TerminalCapabilities{
        queried?: true,
        kitty_graphics: true,
        sixel: false,
        ...
      }

  Use this to decide, e.g., whether to render an inline image with the Kitty
  graphics protocol or fall back to ASCII.

  ## Detection technique

  Queries are sent as a single batch, terminated by a Primary Device Attributes
  (DA1, `ESC [ c`) request. DA1 is supported by essentially every terminal and
  responses arrive in order, so the DA1 reply doubles as a "we're done"
  sentinel: anything that was going to answer has answered by the time it
  arrives. See https://github.com/sindresorhus/terminal-query for the same idea.
  """

  alias NervesSSH.TerminalCapabilities.Registry

  @default_timeout 500

  defstruct queried?: false,
            term: nil,
            primary_da: nil,
            sixel: false,
            kitty_graphics: false,
            kitty_keyboard: false,
            synchronized_output: false,
            raw: nil

  @type t :: %__MODULE__{
          queried?: boolean(),
          term: String.t() | nil,
          primary_da: String.t() | nil,
          sixel: boolean(),
          kitty_graphics: boolean(),
          kitty_keyboard: boolean(),
          synchronized_output: boolean(),
          raw: binary() | nil
        }

  @doc """
  Return the capabilities detected for the current SSH session, or `nil` if none
  were detected (e.g. detection was disabled or this isn't an SSH session).
  """
  @spec get() :: t() | nil
  def get() do
    Registry.lookup(Process.group_leader())
  end

  @doc """
  Shell-startup callback. Detects capabilities for the current session's
  terminal and stores them in the registry.

  This is used as the `IEx` startup callback (see
  `NervesSSH.Options`). It must never crash: a non-normal exit here would
  prevent the IEx prompt from starting.
  """
  @spec detect_callback(keyword()) :: :ok
  def detect_callback(opts \\ []) do
    caps = detect(opts)
    Registry.track(Process.group_leader(), caps)
    :ok
  catch
    kind, reason ->
      require Logger

      Logger.warning(
        "[NervesSSH] terminal capability detection failed: #{inspect({kind, reason})}"
      )

      :ok
  end

  @doc """
  Query the terminal behind `device` (default: the current group leader) and
  return its capabilities.

  Options:

    * `:device` - the IO device / group leader to query. Defaults to
      `Process.group_leader/0`.
    * `:timeout` - total milliseconds to wait for responses. Defaults to
      `#{@default_timeout}`.
  """
  @spec detect(keyword()) :: t()
  def detect(opts \\ []) do
    device = Keyword.get(opts, :device) || Process.group_leader()
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    # echo off -> the Erlang `group` routes input through its "dumb" state where
    # get_chars returns bytes immediately instead of waiting for a newline.
    # binary -> read raw bytes rather than charlists.
    :ok = :io.setopts(device, [{:echo, false}, {:binary, true}])

    try do
      :ok = :io.put_chars(device, queries())
      device |> read_until_da(timeout) |> parse()
    after
      # Restore what the IEx prompt expects.
      _ = :io.setopts(device, [{:echo, true}, {:binary, false}])
    end
  end

  # Sent as one batch. DA1 (ESC[c) MUST be last so its reply is the sentinel.
  defp queries() do
    IO.iodata_to_binary([
      # XTVERSION: terminal name + version
      "\e[>q",
      # Kitty keyboard protocol: query progressive enhancement flags
      "\e[?u",
      # DECRQM: synchronized output (mode 2026)
      "\e[?2026$p",
      # Kitty graphics: a no-op query image (a=q) -> replies ";OK" if supported
      "\e_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\e\\",
      # Primary Device Attributes (sentinel + sixel detection)
      "\e[c"
    ])
  end

  # Read one byte at a time until the DA1 reply terminates the buffer or we time
  # out. A separate reader process does the blocking reads and streams bytes
  # back, so a terminal that never answers can't block us past the deadline.
  defp read_until_da(device, timeout) do
    parent = self()
    reader = spawn(fn -> reader_loop(device, parent) end)
    deadline = System.monotonic_time(:millisecond) + timeout
    acc = collect(deadline, <<>>)
    Process.exit(reader, :kill)
    acc
  end

  defp reader_loop(device, parent) do
    case IO.getn(device, "", 1) do
      <<b>> ->
        send(parent, {:byte, b})
        reader_loop(device, parent)

      :eof ->
        send(parent, :eof)

      _other ->
        reader_loop(device, parent)
    end
  end

  defp collect(deadline, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      acc
    else
      receive do
        {:byte, b} ->
          acc = acc <> <<b>>
          if da_reply?(acc), do: acc, else: collect(deadline, acc)

        :eof ->
          acc
      after
        remaining -> acc
      end
    end
  end

  # True once the accumulated buffer ends with a complete DA1 reply: ESC [ ? … c
  defp da_reply?(buf), do: Regex.match?(~r/\x1b\[\?[0-9;]*c\z/, buf)

  @doc false
  @spec parse(binary()) :: t()
  def parse(raw) do
    %__MODULE__{
      queried?: true,
      raw: raw,
      primary_da: capture(raw, ~r/\x1b\[\?([0-9;]*)c/),
      term: capture(raw, ~r/\x1bP>\|([^\x1b]*)\x1b\\/),
      sixel: sixel?(raw),
      kitty_graphics: Regex.match?(~r/\x1b_G[^\x1b]*;OK/, raw),
      kitty_keyboard: Regex.match?(~r/\x1b\[\?\d+u/, raw),
      synchronized_output: synchronized_output?(raw)
    }
  end

  # Sixel is advertised as attribute "4" in the DA1 parameter list.
  defp sixel?(raw) do
    case capture(raw, ~r/\x1b\[\?([0-9;]*)c/) do
      nil -> false
      params -> "4" in String.split(params, ";")
    end
  end

  # DECRPM reply: ESC [ ? 2026 ; <value> $ y. value 1 (set) or 2 (reset) means
  # the mode is recognized/supported; 0 (not recognized) or 4 (permanently
  # reset) means it isn't.
  defp synchronized_output?(raw) do
    case capture(raw, ~r/\x1b\[\?2026;(\d+)\$y/) do
      value when value in ["1", "2"] -> true
      _ -> false
    end
  end

  defp capture(raw, regex) do
    case Regex.run(regex, raw) do
      [_, captured] -> captured
      _ -> nil
    end
  end
end
