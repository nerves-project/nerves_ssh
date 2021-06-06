defmodule NervesSSH.Exec do
  @moduledoc """
  This module contains helper methods for running commands over SSH
  """

  @doc """
  Run one Elixir command coming over ssh
  """
  @spec run_elixir(charlist()) :: {:ok, binary()} | {:error, binary()}
  def run_elixir(cmd) do
    {result, _env} = Code.eval_string(to_string(cmd))
    {:ok, inspect(result)}
  catch
    kind, value ->
      {:error, "** (#{kind}) #{inspect(value)}"}
  end

  @doc """
  Run one LFE command coming over ssh
  """
  @spec run_lfe(charlist()) :: {:ok, binary()} | {:error, binary()}
  def run_lfe(cmd) do
    {value, _} = apply(:lfe_shell, :run_string, [cmd])
    {:ok, apply(:lfe_io, :prettyprint1, [value, 30])}
  catch
    kind, value ->
      {:error, "** (#{kind}) #{inspect(value)}"}
  end

  @doc """
  Run one Erlang command coming over ssh
  """
  @spec run_erlang(charlist()) :: {:ok, binary()} | {:error, binary()}
  def run_erlang(cmd) do
    with {:ok, tokens} <- erl_scan(cmd),
         {:ok, expr_list} <- erl_parse(tokens) do
      {:value, value, _new_bindings} = :erl_eval.exprs(expr_list, :erl_eval.new_bindings())
      {:ok, value}
    end
  end

  defp erl_scan(cmd) do
    case :erl_scan.string(cmd) do
      {:ok, tokens, _} -> {:ok, tokens}
      {:error, {_, :erl_scan, cause}} -> {:error, :erl_scan.format_error(cause)}
    end
  end

  defp erl_parse(tokens) do
    case :erl_parse.parse_exprs(tokens) do
      {:ok, expr_list} -> {:ok, expr_list}
      {:error, {_, :erl_parse, cause}} -> {:error, :erl_parse.format_error(cause)}
      {:error, other} -> {:error, other}
    end
  end
end
