defmodule Unless do
  # ----------------------
  # Function version
  # ----------------------
  def fun_unless(clause, do: expression) do
    if !clause, do: expression
  end

  # ----------------------
  # Macro version
  # ----------------------
  defmacro macro_unless(clause, do: expression) do
    quote do
      if !unquote(clause), do: unquote(expression)
    end
  end
end
