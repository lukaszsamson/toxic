defmodule Toxic.Driver do
  defstruct [
    line: 1,
    column: 1,
    scope: nil,
    modes: [:normal]
  ]

  require Record

  Record.defrecord(:scope, :toxic_tokenizer, Record.extract(:toxic_tokenizer, from: "src/toxic.hrl"))

  def new() do
    %__MODULE__{
      scope: scope()
    }
  end
  def next([?} | rest], %__MODULE__{modes: [:normal | modes_rest]} = state) do
    {:ok, {:end_interpolation, {{state.line, state.column}, {state.line, state.column + 1}, nil}}, rest, %{state | modes: modes_rest, column: state.column + 1}}
  end
  def next(string, %__MODULE__{modes: [:normal | _] = modes} = state) when is_list(string) do
    # TODO: eliminate tokens
    tokens = []
    dbg()
    case :toxic_tokenizer.tokenize_single(string, state.line, state.column, state.scope, tokens) |> dbg do
      {:token, token, rest, line, column, scope} ->
        {:ok, token, rest, %{state | line: line, column: column, scope: scope}}

      {:switch_to_interp, token = {kind, _, delim}, rest, line, column, scope} ->
        {:ok, token, rest, %{state | line: line, column: column, scope: scope, modes: [{:interp, kind, delim} | modes]}}
      {:eof, line, column, scope} ->
        {:eof, %{state | line: line, column: column, scope: scope}}
    end
  end
  def next(string, %__MODULE__{modes: [{:interp, kind, interpolation, delim} | _]} = state) do
    case :toxic_interpolation.extract_stream_event(state.line, state.column, state.scope, interpolation, string, delim) do
      {:fragment, meta, binary_part, rest, line, column, scope} ->
        {:ok, {:binary_part, meta, binary_part}, rest, %{state | line: line, column: column, scope: scope}}
    end
  end
end
