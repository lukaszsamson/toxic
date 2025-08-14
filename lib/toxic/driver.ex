defmodule Toxic.Driver do
  defstruct [
    line: 1,
    column: 1,
    scope: nil,
    modes: [:normal]
  ]

  require Record

  Record.defrecord(:scope, :toxic_tokenizer, Record.extract(:toxic_tokenizer, from: "src/toxic.hrl"))

  defguard is_vertical_space(char) when char in [?\n, ?\r]
  defguard is_horizontal_space(char) when char in [?\s, ?\t]
  defguard is_space(char) when is_vertical_space(char) or is_horizontal_space(char)

  def new() do
    tokenizer = :toxic_config.identifier_tokenizer()
    %__MODULE__{
      scope: scope(identifier_tokenizer: tokenizer)
    }
  end
  def next([?} | rest], %__MODULE__{modes: [:normal | modes_rest]} = state) do
    {:ok, {:end_interpolation, {{state.line, state.column}, {state.line, state.column + 1}, nil}, :string}, rest, %{state | modes: modes_rest, column: state.column + 1}}
  end
  def next(string, %__MODULE__{modes: [:normal | _] = modes} = state) when is_list(string) do
    # TODO: eliminate tokens
    tokens = []
    case :toxic_tokenizer.tokenize_single(string, state.line, state.column, state.scope, tokens) do
      {:token, token, rest, line, column, scope} ->
        {:ok, token, rest, %{state | line: line, column: column, scope: scope}}

      {:switch_to_interp, token, rest, line, column, scope, interp_kind, delim, interpolation} ->
        {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: [{:interp, interp_kind, interpolation, delim} | modes]}}

      {:error, {[line: _, column: error_column], _, _}, [?} | _] = string, _tokens, _warnings} when length(modes) > 1 ->
        # Handle empty interpolation case - treat closing } as end_interpolation
        {:ok, {:end_interpolation, {state.line, error_column, nil}, :string}, tl(string), %{state | modes: tl(modes), column: error_column + 1}}

      {:eof, line, column, scope} ->
        {:eof, %{state | line: line, column: column, scope: scope}}
    end
  end
  def next(string, %__MODULE__{modes: [{:interp, kind, _interpolation, delim} | modes_rest]} = state) do
    case :toxic_interpolation.extract_stream_event(state.line, state.column, state.scope, true, string, delim) do
      {:fragment, meta, binary_part, rest, line, column, scope} ->
        case :toxic_tokenizer.unescape_tokens([binary_part], line, column, scope) do
          {:ok, [unescaped]} ->
            {:ok, {:string_fragment, meta, unescaped}, rest, %{state | line: line, column: column, scope: scope}}
        end

      {:begin_interpolation, meta, _kind, rest, line, column, scope} ->
        {:ok, {:begin_interpolation, meta, kind}, rest, %{state | line: line, column: column, scope: scope, modes: [:normal | state.modes]}}

      {:done, meta, _binary_part, indent, rest, line, column, scope} when kind in [:bin_heredoc, :list_heredoc] ->
        end_token_type = case kind do
          :list_heredoc -> :list_heredoc_end
          :bin_heredoc -> :bin_heredoc_end
        end
        {:ok, {end_token_type, meta, delim, indent}, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}

      {:done, meta, _binary_part, rest, line, column, scope} ->
        case rest do
          [?:, ws | tail] when is_space(ws) ->
            adj_meta = case meta do
              {{sl, sc}, {el, ec}, extra} -> {{sl, sc}, {el, ec + 1}, extra}
              other -> other
            end
            end_token_type = case scope do
              scope(existing_atoms_only: true) -> :kw_identifier_safe_end
              _ -> :kw_identifier_unsafe_end
            end
            {:ok, {end_token_type, adj_meta, delim}, [ws | tail], %{state | line: line, column: column + 1, scope: scope, modes: modes_rest}};
          _ ->
            end_token_type = case kind do
              :charlist -> :list_string_end
              :atom_safe -> :atom_safe_end
              :atom_unsafe -> :atom_unsafe_end
              _ -> :bin_string_end
            end
            {:ok, {end_token_type, meta, delim}, rest, %{state | line: line, column: column, scope: scope, modes: modes_rest}}
        end

      {:error, reason} ->
        # Handle errors from interpolation extraction
        {:error, reason, string, %{state | modes: modes_rest}}
    end
  end
end
