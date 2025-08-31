defmodule Toxic.Dot do
  import Toxic.Scope
  import Toxic.Util
  import Toxic.Comment
  import Toxic.Operator
  import Toxic.CharacterClassifier
  import Toxic.Token

  def tokenize_dot(t, line, column, dot_info, scope = scope(column: scope_column), tokens) do
    case strip_horizontal_space(t, 0) do
      {[?# | r], _} ->
        case tokenize_comment(r, [?#]) do
          {:error, _char} ->
            # error_comment(Char, [?# | R], line, column, scope, tokens)
            {:error, :comment_bidi_error}

          {rest, _comment} ->
            # TODO: preserve comments
            # preserve_comments(line, column, tokens, Comment, rest, scope)
            tokenize_dot(rest, line, scope_column, dot_info, scope, tokens)
        end

      {[?\r, ?\n | rest], _} ->
        tokenize_dot(rest, line + 1, scope_column, dot_info, scope, tokens)

      {[?\n | rest], _} ->
        tokenize_dot(rest, line + 1, scope_column, dot_info, scope, tokens)

      {rest, length} ->
        handle_dot([?. | rest], line, column + length, dot_info, scope, tokens)
    end
  end

  # Three Token Operators
  defp handle_dot([?., t1, t2, t3 | rest], line, column, dot_info, scope, tokens)
       when unary_op3(t1, t2, t3) or comp_op3(t1, t2, t3) or and_op3(t1, t2, t3) or
              or_op3(t1, t2, t3) or
              arrow_op3(t1, t2, t3) or xor_op3(t1, t2, t3) or concat_op3(t1, t2, t3) do
    handle_call_identifier(rest, line, column, dot_info, 3, [t1, t2, t3], scope, tokens)
  end

  # Two Token Operators
  defp handle_dot([?., t1, t2 | rest], line, column, dot_info, scope, tokens)
       when comp_op2(t1, t2) or rel_op2(t1, t2) or and_op(t1, t2) or or_op(t1, t2) or
              arrow_op(t1, t2) or in_match_op(t1, t2) or concat_op(t1, t2) or power_op(t1, t2) or
              type_op(t1, t2) do
    handle_call_identifier(rest, line, column, dot_info, 2, [t1, t2], scope, tokens)
  end

  # Single Token Operators
  defp handle_dot([?., t | rest], line, column, dot_info, scope, tokens)
       when at_op(t) or unary_op(t) or capture_op(t) or dual_op(t) or mult_op(t) or
              rel_op(t) or match_op(t) or pipe_op(t) do
    handle_call_identifier(rest, line, column, dot_info, 1, [t], scope, tokens)
  end

  # Exception for .( as it needs to be treated specially in the parser
  defp handle_dot([?., ?( | rest], line, column, dot_info, scope, _tokens) do
    token = {:dot_call_op, dot_info, :.}
    emit_with_eol(token, [?( | rest], line, column, scope)
  end

  defp handle_dot([?., h | t], line, column, dot_info, base_scope, _tokens) when is_quote(h) do
    # TODO: emit warning
    scope = base_scope
    # scope = case H == $' of
    #   true ->
    #     prepend_warning(line, column, "single quotes around calls are deprecated. Use double quotes instead", Basescope);
    #   false ->
    #     Basescope
    # end,
    # TODO: emit 2 events?
    dot_token = {:., dot_info}
    start_tok = {:quoted_identifier_start, meta(line, column, line, 1, nil), h}

    multiple(
      [{:token_with_eol, dot_token}, {:switch_to_interp, start_tok, :quoted_identifier, true, h}],
      t,
      line,
      column + 1,
      scope
    )
  end

  defp handle_dot([?. | rest], line, column, dot_info, scope, _tokens) do
    token = {:., dot_info}
    emit_with_eol(token, rest, line, column, scope)
  end

  defp handle_call_identifier(rest, line, column, dot_info, length, unencoded_op, scope, _tokens) do
    op_token =
      Toxic.Identifier.check_call_identifier(
        line,
        column,
        length,
        unencoded_op,
        List.to_atom(unencoded_op),
        rest
      )

    dot_token = {:., dot_info}

    multiple(
      [{:token_with_eol, dot_token}, {:token, op_token}],
      rest,
      line,
      column + length,
      scope
    )
  end
end
