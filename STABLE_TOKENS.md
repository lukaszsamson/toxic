## Stable vs. unstable tokens in the tokenizer

This document lists all places where tokens that have already been emitted may be retroactively altered or removed by subsequent tokenizer steps. These cases are important for streaming/online tokenization, because they imply the head of the token list is not stable yet.

### 1) EOL coalescing and removal
- The `eol/4` helper mutates the previously emitted token when it is one of `','`, `';'`, or `eol`, by incrementing the end-of-line count in its metadata. Otherwise, it emits a new `eol` token.

```1296:1304:src/toxic_tokenizer.erl
eol(_Line, _Column, [{Kind, {Line, Column, Count}} | Tokens], _Scope) 
  when Kind =:= ','; Kind =:= ';'; Kind =:= eol, is_integer(Line) ->
  [{Kind, {Line, Column, Count + 1}} | Tokens];
eol(_Line, _Column, [{Kind, {{Line, Column}, {EndLine, EndColumn}, _}} | Tokens], _Scope)
  when Kind =:= ','; Kind =:= ';'; Kind =:= eol ->
  [{Kind, {{Line, Column}, {Line + Count + 1, 1}, Count + 1}} | Tokens];
eol(Line, Column, Tokens, Scope) ->
  [{eol, make_meta(Line, Column, Line + 1, 1, 1, Scope)} | Tokens].
```

- `add_token_with_eol/2` drops a previously emitted `eol` token when appending most tokens. Unary ops are the exception and do not consume a preceding `eol`.

```1750:1753:src/toxic_tokenizer.erl
add_token_with_eol({unary_op, _, _} = Left, T) -> [Left | T];
add_token_with_eol(Left, [{eol, _} | T]) -> [Left | T];
add_token_with_eol(Left, T) -> [Left | T].
```

- `reset_eol/1` zeroes-out the `eol` count on the head `eol` token. This is called after comments are preserved/handled.

```1586:1588:src/toxic_tokenizer.erl
reset_eol([{eol, {Line, Column, _}} | Rest]) when is_integer(Line) -> [{eol, {Line, Column, 0}} | Rest];
reset_eol([{eol, {{Line, Column}, {EndLine, EndColumn}, _}} | Rest]) -> [{eol, {{Line, Column}, {EndLine, EndColumn}, 0}} | Rest];
reset_eol(Rest) -> Rest.
```

- Operators and `.` incorporate EOL info into their own metadata (via `previous_was_eol/1`) and then call `add_token_with_eol/2`, which removes the standalone `eol` token.

```1188:1189:src/toxic_tokenizer.erl
Token = {Kind, make_meta_len(Line, Column, Length, previous_was_eol(Tokens), Scope), Op},
add_token_with_eol({Kind, Meta, Atom}, Tokens)
```

```1263:1266:src/toxic_tokenizer.erl
handle_dot([$., $( | Rest], Line, Column, DotInfo, Scope, Tokens) ->
  TokensSoFar = add_token_with_eol({dot_call_op, DotInfo, '.'}, Tokens),
  tokenize([$( | Rest], Line, Column, Scope, TokensSoFar);
```

### 2) Space-sensitive rewrite: identifier -> op_identifier
When a dual operator (like `+`/`-`) is adjacent to an identifier without required spacing, the previously emitted identifier is rewritten to `op_identifier`, and a dual op token is inserted in front of it.

```1329:1334:src/toxic_tokenizer.erl
Rest = [NotMarker | T],
DualOpToken = {dual_op, make_meta_len(Line, Column, 1, nil, Scope), list_to_atom([Sign])},
tokenize(Rest, Line, Column + 1, Scope, [DualOpToken, setelement(1, H, op_identifier) | Tokens]);
```

### 3) Merging `not` + `in` into a single `in_op`
If `in` follows a previously emitted unary `not`, the `not` token is removed and replaced with a single `in_op` token spanning from the start of `not` to the end of `in`.

```2005:2016:src/toxic_tokenizer.erl
{in_op, [{unary_op, NotInfo, 'not'} | T]} ->
  %% Build a range from the start of 'not' to the end of 'in'
  Start = case NotInfo of
    {{SL, SC}, _, _} -> {SL, SC};
    {SL, SC, _} -> {SL, SC}
  end,
  EndLine = Line,
  EndColumn = Column + Length,
  Meta = make_meta(element(1, Start), element(2, Start), EndLine, EndColumn, nil, Scope),
  add_token_with_eol({in_op, Meta, 'not in'}, T);
```

### 4) `do` rebind: identifier -> do_identifier
For the special `do` keyword terminator case, the immediately preceding identifier (function/macro name) is rewritten to `do_identifier` and a `do` token is emitted.

```2141:2145:src/toxic_tokenizer.erl
tokenize_keyword_terminator(DoLine, DoColumn, do, [{identifier, {Line, Column, Meta}, Atom} | T], Scope) ->
  {ok, add_token_with_eol({do, make_meta_len(DoLine, DoColumn, 2, nil, Scope)},
                          [{do_identifier, {Line, Column, Meta}, Atom} | T])};
```

### 5) Cursor mode pruning and synthetic cursor tokens
When cursor completion is enabled and pruning is requested, the tokenizer rewrites the token stream to a stable prefix and injects synthetic tokens. This both drops tokens and adds new ones:

- Drops the trailing `{identifier, ...}` (if present):

```2255:2256:src/toxic_tokenizer.erl
prune_identifier([{identifier, _, _} | Tokens]) -> Tokens;
prune_identifier(Tokens) -> Tokens.
```

- Prunes tokens to balanced/allowed boundaries (terminators, separators, etc.). The pruning rules are extensive; see `prune_tokens/2`:

```2259:2323:src/toxic_tokenizer.erl
%%% Any terminator needs to be closed
prune_tokens([{'end', _} | Tokens], Opener) ->
  ...
%%% or it is time to stop...
prune_tokens([{';', _} | _] = Tokens, []) -> Tokens;
prune_tokens([{'eol', _} | _] = Tokens, []) -> Tokens;
... (many cases elided) ...
```

- Injects synthetic cursor sequence:

```2245:2253:src/toxic_tokenizer.erl
PrePrunedTokens = prune_identifier(Tokens),
PrunedTokens = prune_tokens(PrePrunedTokens, []),
CursorTokens = [
  {')', {Line, Column + 11, nil}},
  {'(', {Line, Column + 10, nil}},
  {paren_identifier, {Line, Column, nil}, '__cursor__'}
  | PrunedTokens
],
```

### 6) Dot and operators consume standalone EOL
Both the `.` token and most operators call `add_token_with_eol/2`, which removes a preceding standalone `eol` token after embedding its count into the new token’s metadata (via `previous_was_eol/1`). See the citations in section 1.

### 7) Keywords emitting via add_token_with_eol
Many keyword tokens (e.g., `when`, `in`, etc.) are emitted with `add_token_with_eol/2`, which will drop a preceding `eol` token. See `tokenize_keyword/8`:

```2017:2021:src/toxic_tokenizer.erl
PrevEol = previous_was_eol(Tokens),
Meta = make_meta_len(Line, Column, Length, PrevEol, Scope),
add_token_with_eol({Kind, Meta, Atom}, Tokens)
```

### Notes on linearization
The linearization markers (`*_start`/`*_end`, `begin_interpolation`/`end_interpolation`, `string_fragment`, and `quoted_identifier_start/end`) do not themselves alter previously emitted tokens. However, the same EOL coalescing/removal rules apply when these markers are emitted alongside operators or dots.

## Implications for streaming
- Do not treat a trailing `eol` token as stable; it may be consumed by the next token emitted.
- The last emitted identifier can be rewritten to `op_identifier` depending on the next character.
- A trailing unary `not` may be merged into an `in_op` when `in` follows.
- Before `do`, a trailing identifier may be rewritten to `do_identifier`.
- In cursor/prune mode, the tail of the token list is intentionally mutated and truncated before injecting synthetic cursor tokens.
