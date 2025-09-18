defmodule Toxic.Keyword do
  import Toxic.Token
  import Toxic.Util
  import Toxic.Terminator

  def tokenize_keyword(:terminator, rest, line, column, atom, length, scope, tokens) do
    case tokenize_keyword_terminator(line, column, atom, length, tokens) do
      {:ok, list} ->
        {_, check} = List.last(list)

        case handle_terminator(rest, line, column + length, scope, check, tokens) do
          {:error, reason} ->
            {:error, reason}
          {_, rest, line, column, scope} ->
            {list, rest, line, column, scope}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def tokenize_keyword(:token, rest, line, column, atom, length, scope, _tokens) do
    token = {atom, meta(line, column, length, nil)}
    emit(token, rest, line, column + length, scope)
  end

  def tokenize_keyword(:block, rest, line, column, atom, length, scope, _tokens) do
    token = {:block_identifier, meta(line, column, length, nil), atom}
    emit(token, rest, line, column + length, scope)
  end

  def tokenize_keyword(kind, rest, line, column, atom, length, scope, tokens) do
    case strip_horizontal_space(rest, 0) do
      {[?/ | _], _} ->
        token = {:identifier, meta(line, column, length, nil), atom}
        emit(token, rest, line, column + length, scope)

      _ ->
        case {kind, tokens} do
          {:in_op,
           [
             {:unary_op, meta(start_line, start_column, _end_line, _end_column, extra), :not}
             | _t
           ]} ->
            not_info_meta = meta(start_line, start_column, line, column + length, extra)
            token = {:in_op, not_info_meta, :"not in"}
            multiple([:drop_not, {:token_with_eol, token}], rest, line, column + length, scope)

          {_, _} ->
            token = {kind, meta(line, column, length, previous_was_eol(tokens)), atom}
            emit_with_eol(token, rest, line, column + length, scope)
        end
    end
  end

  defp tokenize_keyword_terminator(do_line, do_column, :do, length, [{token, _, _} | _t])
       when token in [:identifier, :quoted_identifier_end] do
    {:ok,
     [
       :transform_into_do_identifier,
       {:token_with_eol, {:do, meta(do_line, do_column, length, nil)}}
     ]}
  end

  defp tokenize_keyword_terminator(line, column, :do, _length, [{:fn, _} | _]) do
    message =
      {~c"unexpected reserved word: ",
       ~c". Anonymous functions are written as:\n\n    fn pattern -> expression end\n\nPlease remove the \"do\" keyword"}

    {:error, {[line: line, column: column], message, ~c"do"}}
  end

  defp tokenize_keyword_terminator(line, column, :do, length, tokens) do
    case valid_do?(tokens) do
      true ->
        {:ok, [{:token_with_eol, {:do, meta(line, column, length, nil)}}]}

      false ->
        # TODO: coverage
        {:error, {[line: line, column: column], ~c"unexpected reserved word: ", ~c"do"}}
    end
  end

  defp tokenize_keyword_terminator(line, column, atom, length, _tokens) do
    {:ok, [{:token, {atom, meta(line, column, length, nil)}}]}
  end

  defp valid_do?([{atom, _} | _]) when atom in ~w(
,
;
not
and
or
when
in
after
else
catch
rescue
)a,
    do: false

  defp valid_do?(_), do: true
end
