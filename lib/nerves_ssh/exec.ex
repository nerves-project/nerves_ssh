defmodule NervesSSH.Exec do
  @doc """
  Run one command coming over ssh
  """

  def run_elixir(cmd) do
    try do
      {result, _env} = Code.eval_string(to_string(cmd))
      {:ok, inspect(result)}
    catch
      kind, value ->
        {:error, "** (#{kind}) #{inspect(value)}"}
    end
  end
end
