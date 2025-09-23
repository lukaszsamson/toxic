defmodule Toxic.Terminator do
  import Toxic.Scope
  import Toxic.Util

  def handle_terminator(_rest, _, _, _scope, {:"(", meta}, [{:alias, _, alias} | _tokens])
      when is_atom(alias) do
    {{line, column}, _, _} = meta

    reason =
      "unexpected ( after alias #{alias}. Function names and identifiers in Elixir " <>
      "start with lowercase characters or underscore. For example:\n\n" <>
      "    hello_world()\n" <>
      "    _starting_with_underscore()\n" <>
      "    numb3rs_are_allowed()\n" <>
      "    may_finish_with_question_mark?()\n" <>
      "    may_finish_with_exclamation_mark!()\n\n" <>
      "Unexpected token: "

    {:error, {[line: line, column: column], String.to_charlist(reason), [~c"("]}}
  end

  # In elixir_tokenizer this clause is used only in eex
  def handle_terminator(rest, line, column, scope(terminators: :none) = scope, token, _tokens) do
    emit(token, rest, line, column, scope)
  end

  def handle_terminator(rest, line, column, scope, token, _tokens) do
    scope(terminators: terminators) = scope

    case check_terminator(token, terminators, scope) do
      {:error, reason} ->
        {:error, reason}

      # error(Reason, atom_to_list(element(1, Token)) ++ rest, scope, tokens);
      {:ok, new_scope} ->
        emit(token, rest, line, column, new_scope)
    end
  end

  def check_terminator({start, meta}, terminators, scope)
      when start in ~w|( [ { <<|a do
    scope(indentation: indentation) = scope
    {:ok, scope(scope, terminators: [{start, meta, indentation} | terminators])}
  end

  def check_terminator({start, meta}, terminators, scope) when start in [:fn, :do] do
    scope(indentation: indentation) = scope
    # TODO: hints
    # Newscope =
    #   case Terminators of
    #     %% If the do is indented equally or less than the previous do, it may be a missing end error!
    #     [{Start, _, PreviousIndentation} = Previous | _] when Indentation =< PreviousIndentation ->
    #       scope#elixir_tokenizer{mismatch_hints=[Previous | scope#elixir_tokenizer.mismatch_hints]};

    #     _ ->
    #       scope
    #   end,

    {:ok, scope(scope, terminators: [{start, meta, indentation} | terminators])}
  end

  def check_terminator({:end, _end_meta}, [{:do, _, _indentation} | terminators], scope) do
    # TODO: hints
    # Newscope =
    #   %% If the end is more indented than the do, it may be a missing do error!
    #   case scope#elixir_tokenizer.indentation > Indentation of
    #     true ->
    #       Hint = {'end', Endline, scope#elixir_tokenizer.indentation},
    #       scope#elixir_tokenizer{mismatch_hints=[Hint | scope#elixir_tokenizer.mismatch_hints]};

    #     false ->
    #       scope
    #   end,

    {:ok, scope(scope, terminators: terminators)}
  end

  def check_terminator(
        {end_token, _end_meta},
        [{start_token, _start_meta, _} | terminators],
        scope
      )
      when end_token in ~w|end ) ] } >>|a do
    case terminator(start_token) do
      ^end_token ->
        {:ok, scope(scope, terminators: terminators)}

      _expected_end ->
        {:error, :unexpected_token_or_reserved}
        #   Meta = [
        #     {line, Startline},
        #     {column, Startcolumn},
        #     {end_line, Endline},
        #     {end_column, Endcolumn},
        #     {error_type, mismatched_delimiter},
        #     {opening_delimiter, Start},
        #     {closing_delimiter, End},
        #     {expected_delimiter, ExpectedEnd}
        #  ],
        #  {error, {Meta, unexpected_token_or_reserved(End), [atom_to_list(End)]}}
    end
  end

  def check_terminator({:end, meta}, [], _scope) do
    {{line, column}, _, _} = meta
    {:error, {[line: line, column: column], ~c"unexpected reserved word: ", ~c"end"}}
    # Suffix =
    #   case lists:keyfind('end', 1, Hints) of
    #     {'end', Hintline, _Indentation} ->
    #       io_lib:format("\n~ts the \"end\" on line ~B may not have a matching \"do\" "
    #                     "defined before it (based on indentation)", [elixir_errors:prefix(hint), Hintline]);
    #     false ->
    #       ""
    #   end,

    # {error, {?LOC(line, column), {"unexpected reserved word: ", Suffix}, "end"}}
  end

  def check_terminator({end_token, meta}, [], _scope)
      when end_token in ~w|) ] } >>|a do
    {{line, column}, _, _} = meta
    {:error, {[line: line, column: column], ~c"unexpected token: ", [~c"#{end_token}"]}}
  end

  # TODO: report dead code to elixir
  # def check_terminator(_, _, scope), do: {:ok, scope}

  defp terminator(:fn), do: :end
  # This clause never matches, handled by do-end special check_terminator clause
  defp terminator(:do), do: :end
  defp terminator(:"("), do: :")"
  defp terminator(:"["), do: :"]"
  defp terminator(:"{"), do: :"}"
  defp terminator(:"<<"), do: :">>"
end
