defmodule Toxic.NormalTokenizer.Terminator do
  @moduledoc false
  import Toxic.Scope
  import Toxic.Util

  def handle_terminator(_rest, _, _, _scope, {:"(", meta}, [{:alias, _, alias} | _tokens])
      when is_atom(alias) do
    {{line, column}, _, _} = meta

    {:error,
     %Toxic.Error{
       code: :alias_unexpected_paren,
       domain: :alias,
       token_display: ~c"(",
       details: %{line: line, column: column, alias: alias}
     }}
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
    scope(indentation: indentation, mismatch_hints: mismatch_hints) = scope

    # If the do/fn is indented equally or less than the previous do/fn, it may be a missing end error!
    new_scope =
      case terminators do
        [{^start, _, previous_indentation} = previous | _]
        when indentation <= previous_indentation ->
          scope(scope, mismatch_hints: [previous | mismatch_hints])

        _ ->
          scope
      end

    {:ok, scope(new_scope, terminators: [{start, meta, indentation} | terminators])}
  end

  def check_terminator({:end, end_meta}, [{:do, _, do_indentation} | terminators], scope) do
    scope(indentation: current_indentation, mismatch_hints: mismatch_hints) = scope
    {{end_line, _end_column}, _, _} = end_meta

    # If the end is more indented than the do, it may be a missing do error!
    new_scope =
      if current_indentation > do_indentation do
        hint = {:end, end_line, current_indentation}
        scope(scope, mismatch_hints: [hint | mismatch_hints])
      else
        scope
      end

    {:ok, scope(new_scope, terminators: terminators)}
  end

  def check_terminator(
        {end_token, end_meta},
        [{start_token, start_meta, _} | terminators],
        scope
      )
      when end_token in ~w|end ) ] } >>|a do
    case terminator(start_token) do
      ^end_token ->
        {:ok, scope(scope, terminators: terminators)}

      expected_end ->
        {{start_line, start_column}, _, _} = start_meta
        {{_end_line, _end_start_column}, {end_line_end, end_column_end}, _} = end_meta

        err = %Toxic.Error{
          code: :terminator_mismatched_closer,
          domain: :terminator,
          token_display: String.to_charlist("#{end_token}"),
          position: {{start_line, start_column}, {end_line_end, end_column_end}},
          details: %{
            opening_delimiter: start_token,
            closing_delimiter: end_token,
            expected_delimiter: expected_end
          }
        }

        {:error, err}
    end
  end

  def check_terminator({:end, meta}, [], scope) do
    {{line, column}, _, _} = meta
    scope(mismatch_hints: mismatch_hints) = scope

    # Check for hint about mismatched end based on indentation
    suffix =
      case :lists.keyfind(:end, 1, mismatch_hints) do
        {:end, hint_line, _indentation} ->
          :io_lib.format(
            ~c"\nhint: the \"end\" on line ~B may not have a matching \"do\" " ++
              ~c"defined before it (based on indentation)",
            [hint_line]
          )

        false ->
          []
      end

    {:error,
     %Toxic.Error{
       code: :reserved_unexpected_end,
       domain: :reserved,
       token_display: ~c"end",
       details: %{line: line, column: column, suffix_iolist: suffix}
     }}
  end

  def check_terminator({end_token, meta}, [], _scope)
      when end_token in ~w|) ] } >>|a do
    {{line, column}, _, _} = meta

    {:error,
     %Toxic.Error{
       code: :terminator_unexpected_closer,
       domain: :terminator,
       token_display: String.to_charlist("#{end_token}"),
       details: %{line: line, column: column}
     }}
  end

  # dead code in elixir
  # def check_terminator(_, _, scope), do: {:ok, scope}

  defp terminator(:fn), do: :end
  # This clause never matches, handled by do-end special check_terminator clause
  defp terminator(:do), do: :end
  defp terminator(:"("), do: :")"
  defp terminator(:"["), do: :"]"
  defp terminator(:"{"), do: :"}"
  defp terminator(:"<<"), do: :">>"
end
