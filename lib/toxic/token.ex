defmodule Toxic.Token do
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

  defmacro int(meta, original_representation) do
    quote do
      {:int, unquote(meta), unquote(original_representation)}
    end
  end

  defmacro flt(meta, original_representation) do
    quote do
      {:flt, unquote(meta), unquote(original_representation)}
    end
  end

  defmacro char(meta, original_representation) do
    quote do
      {:char, unquote(meta), unquote(original_representation)}
    end
  end

  defmacro atom(meta, original_representation) do
    quote do
      {:atom, unquote(meta), unquote(original_representation)}
    end
  end

  defmacro kw_identifier(meta, original_representation) do
    quote do
      {:kw_identifier, unquote(meta), unquote(original_representation)}
    end
  end
end
