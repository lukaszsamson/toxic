defmodule Toxic.Token do
  @moduledoc false
  defmacro meta(line, column, length, extra) do
    quote do
      {{unquote(line), unquote(column)}, {unquote(line), unquote(column) + unquote(length)},
       unquote(extra)}
    end
  end

  defmacro meta(line, column, end_line, end_column, extra) do
    quote do
      {{unquote(line), unquote(column)}, {unquote(end_line), unquote(end_column)}, unquote(extra)}
    end
  end

  @tokens_3 ~w(int flt char atom kw_identifier)a

  for token <- @tokens_3 do
    defmacro unquote(token)(meta, original_representation) do
      tok = unquote(token)

      quote do
        {unquote(tok), unquote(meta), unquote(original_representation)}
      end
    end
  end

  defmacro alias_token(meta, original_representation) do
    quote do
      {:alias, unquote(meta), unquote(original_representation)}
    end
  end

  defmacro dot_token(meta) do
    quote do
      {:., unquote(meta)}
    end
  end
end
