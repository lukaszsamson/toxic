# Error Cases in Toxic Tokenizer

This document catalogs all error cases (`{:error, _}`) found in the Toxic tokenizer codebase, organized by file with code positions and descriptions.

## Summary

Total error patterns found: **52** across **11** files

## Files with Error Cases

### lib/toxic/tokenizer.ex (25 error cases)

The main tokenizer module contains the majority of error handling patterns:

**Line 16**: `{:error, :vc_marker}`
- **Context**: Version control merge conflict detection
- **Trigger**: Input starting with `<<<<<<<` at column 1
- **Description**: Detects version control conflict markers

**Line 48**: `{:error, :comment_bidi_error}`
- **Context**: Comment tokenization with bidirectional text
- **Trigger**: Invalid bidirectional characters in comments
- **Description**: Error from comment bidi formatting check

**Line 238**: `{:error, :unexpected_token_ternary}`
- **Context**: Ternary operator handling
- **Trigger**: Unexpected token in ternary expression
- **Description**: Ternary operation parsing error

**Line 292**: `{:error, :unexpected_space}`
- **Context**: Map syntax validation
- **Trigger**: `{` following `%` token with unexpected spacing
- **Description**: Invalid spacing in map literal syntax

**Line 411**: `{:error, :unexpected_token_empty_identifier}`
- **Context**: Identifier parsing
- **Trigger**: Empty identifier when cursor completion is disabled
- **Description**: Empty identifier not allowed

**Line 419**: `{:error, :unexpected_token_identifier}`
- **Context**: Identifier validation  
- **Trigger**: Invalid identifier format returned from parser
- **Description**: Malformed identifier token

**Line 424**: `{:error, reason}`
- **Context**: Generic error propagation
- **Trigger**: Error from identifier parsing subsystem
- **Description**: Passes through error from identifier tokenizer

**Line 435**: `{:error, reason}`
- **Context**: Number parsing
- **Trigger**: Error from number tokenization
- **Description**: Propagates number parsing errors

**Line 453**: `{:error, :invalid_character_after_number}`
- **Context**: Number validation
- **Trigger**: Invalid character immediately following a number
- **Description**: Characters that cannot follow numeric literals

**Line 487**: `{:error, :invalid_escape}`
- **Context**: Escape sequence handling
- **Trigger**: Backslash at end of file (`\`)
- **Description**: Incomplete escape sequence

**Line 492**: `{:error, :invalid_escape}`
- **Context**: Escape sequence handling  
- **Trigger**: Backslash followed by newline (`\n`)
- **Description**: Invalid escape at line end

**Line 497**: `{:error, :invalid_escape}`
- **Context**: Escape sequence handling
- **Trigger**: Backslash followed by CRLF (`\r\n`)
- **Description**: Invalid escape at Windows line end

**Line 520**: `{:error, :invalid_map}`
- **Context**: Map literal syntax
- **Trigger**: `%(` - parentheses after percent sign
- **Description**: Expected `%{` for map, got `%(`

**Line 526**: `{:error, :invalid_map}`
- **Context**: Map literal syntax
- **Trigger**: `%[` - square brackets after percent sign
- **Description**: Expected `%{` for map, got `%[`

**Line 587**: `{:error, :keyword_arg_not_followed_by_space}`
- **Context**: Keyword argument parsing
- **Trigger**: `:` in keyword argument without proper spacing
- **Description**: Keyword arguments require space after colon

**Line 594**: `{:error, :invalid_character}`
- **Context**: At-symbol handling
- **Trigger**: Invalid usage of `@` character
- **Description**: At-symbol used incorrectly

**Line 600**: `{:error, :reserved_token}`
- **Context**: Reserved word validation
- **Trigger**: Usage of reserved words `__aliases__` or `__block__`
- **Description**: Reserved tokens cannot be used as identifiers

**Line 630**: `{:error, :unexpected_token_other}`
- **Context**: Generic token parsing
- **Trigger**: Unexpected token in parsing context
- **Description**: Catch-all for unexpected tokens

**Line 647**: `{:error, :unexpected_token_empty}`
- **Context**: Empty token handling
- **Trigger**: Empty token where content expected
- **Description**: Empty token not allowed in this context

**Line 660**: `{:error, :unexpected_token_end}`
- **Context**: End token validation
- **Trigger**: Unexpected `end` token
- **Description**: End token in wrong context

**Line 664**: `{:error, :unexpected_token_identifier}`
- **Context**: Identifier validation
- **Trigger**: Invalid identifier in specific context
- **Description**: Identifier token not expected here

**Line 675**: `{:error, reason}`
- **Context**: Generic error propagation
- **Trigger**: Error from subsystem processing
- **Description**: Propagates errors from lower-level tokenizers

### lib/toxic/terminator.ex (4 error cases)

Handles terminator matching and validation:

**Line 7**: `{:error, :unexpected_token_after_alias}`
- **Context**: Alias followed by parentheses
- **Trigger**: `(` immediately after alias (e.g., `Foo()`)
- **Description**: Function calls on aliases are invalid

**Line 34**: `{:error, reason}`
- **Context**: Terminator checking
- **Trigger**: Error from terminator validation
- **Description**: Propagates terminator checking errors

**Line 90**: `{:error, :unexpected_token_or_reserved}`
- **Context**: End token matching
- **Trigger**: `end` token doesn't match expected terminator
- **Description**: Mismatched block terminators

**Line 106**: `{:error, :unexpected_reserved_word}`
- **Context**: End without matching start
- **Trigger**: `end` token with empty terminator stack
- **Description**: End token without corresponding block start

**Line 121**: `{:error, :unexpected_token_terminator}`
- **Context**: Unmatched closing tokens
- **Trigger**: Closing tokens `)`, `]`, `}`, `>>` without matching open
- **Description**: Unmatched closing delimiters

### lib/toxic/sigil.ex (5 error cases)

Sigil parsing and validation:

**Line 13**: `{:error, reason}`
- **Context**: Sigil tokenization
- **Trigger**: Error from sigil name parsing
- **Description**: Propagates sigil name parsing errors

**Line 37**: `{:error, :invalid_sigil_name}`
- **Context**: Lowercase sigil names
- **Trigger**: Multi-character lowercase sigil name
- **Description**: Only single-character lowercase sigil names allowed

**Line 63**: `{:error, :invalid_sigil_name}`  
- **Context**: Uppercase sigil names
- **Trigger**: Invalid characters in uppercase sigil name
- **Description**: Invalid sigil name format

**Line 96**: `{:error, :invalid_char_after_heredoc_open}`
- **Context**: Heredoc syntax
- **Trigger**: Invalid character after heredoc opening
- **Description**: Malformed heredoc delimiter

**Line 122**: `{:error, :invalid_sigil_delimiter}`
- **Context**: Sigil delimiter parsing
- **Trigger**: Invalid delimiter character for sigil
- **Description**: Unsupported sigil delimiter

### lib/toxic/keyword.ex (3 error cases)

Keyword and reserved word handling:

**Line 17**: `{:error, message}`
- **Context**: Keyword processing
- **Trigger**: Error from keyword validation
- **Description**: Propagates keyword parsing errors

**Line 66**: `{:error, :invalid_do_with_fn_error, ~c"do"}`
- **Context**: Do-block with function
- **Trigger**: `do` keyword used with `fn` token
- **Description**: Do-blocks cannot be used with anonymous functions

**Line 72**: `{:error, :unexpected_reserved_word, ~c"do"}`
- **Context**: Reserved word validation
- **Trigger**: `do` keyword in invalid context
- **Description**: Reserved word used incorrectly

### lib/toxic/identifier.ex (3 error cases)

Identifier parsing and validation:

**Line 33**: `{:error, reason}`
- **Context**: Identifier processing
- **Trigger**: Error from identifier validation
- **Description**: Propagates identifier parsing errors

**Line 37**: `{:error, :mixed_script}`
- **Context**: Unicode script validation
- **Trigger**: Mixed scripts in identifier (e.g., Latin + Cyrillic)
- **Description**: Identifiers cannot mix Unicode scripts

**Line 66**: `{:error, :empty}`
- **Context**: Empty identifier check
- **Trigger**: Identifier with no content
- **Description**: Empty identifiers not allowed

### lib/toxic/util.ex (3 error cases)

Utility functions for atom and encoding validation:

**Line 51**: `{:error, :atom_length_system_limit}`
- **Context**: Atom length validation
- **Trigger**: Atom or atom part exceeds 255 characters
- **Description**: Atom length exceeds system limits

**Line 94**: `{:error, :syntax_error}`
- **Context**: Syntax validation  
- **Trigger**: Generic syntax error from parsing
- **Description**: Catch-all syntax error

**Line 105**: `{:error, :invalid_encoding}`
- **Context**: Character encoding validation
- **Trigger**: Invalid UTF-8 or character encoding
- **Description**: String contains invalid character encoding

### lib/toxic/token_stream.ex (2 error cases)

High-level token streaming interface:

**Line 21**: `{:error_mode, :tolerant | :strict}`
- **Context**: Type specification (not actual error)
- **Trigger**: N/A (type annotation)
- **Description**: Configuration option for error handling mode

**Line 22**: `{:error_sync, [:semicolon | :newline | :closer]}`
- **Context**: Type specification (not actual error)  
- **Trigger**: N/A (type annotation)
- **Description**: Configuration for error recovery sync points

**Line 483**: `{:error, reason, rest_string, driver}`
- **Context**: Token fetching from driver
- **Trigger**: Error returned by driver tokenization
- **Description**: Propagates driver-level errors to stream level

### lib/toxic/number.ex (1 error case)

Number parsing and validation:

**Line 76**: `{:error, :invalid_float, Enum.reverse(acc)}`
- **Context**: Float parsing
- **Trigger**: `ArgumentError` exception during float parsing
- **Description**: Invalid float format or value

### lib/toxic/string.ex (1 error case)

String parsing:

**Line 21**: `{:error, :invalid_char_after_heredoc_open}`
- **Context**: Heredoc string parsing
- **Trigger**: Invalid character after heredoc opening sequence
- **Description**: Malformed heredoc string delimiter

### lib/toxic/interpolation.ex (1 error case)

String interpolation handling:

**Line 340**: `{:error, :bidi_formatting}`
- **Context**: Bidirectional text formatting
- **Trigger**: Invalid bidirectional formatting characters
- **Description**: Bidirectional text formatting not allowed

### lib/toxic/dot.ex (1 error case)

Dot operator parsing:

**Line 15**: `{:error, :comment_bidi_error}`
- **Context**: Comment parsing in dot context
- **Trigger**: Bidirectional text in comment after dot
- **Description**: Invalid bidirectional text in dot-prefixed comment

### lib/toxic/comment.ex (1 error case)

Comment parsing:

**Line 13**: `{:error, h}`
- **Context**: Comment character validation
- **Trigger**: Invalid bidirectional character in comment
- **Description**: Returns the invalid character code

### lib/toxic/alias.ex (1 error case)

Alias validation:

**Line 7**: `{:error, :invalid_character}`
- **Context**: Alias character validation
- **Trigger**: Non-ASCII or special characters in alias
- **Description**: Aliases must be ASCII without special characters

## Error Categories

### 1. Syntax Errors (19 cases)
- Invalid escape sequences
- Malformed map literals  
- Invalid sigil syntax
- Mismatched terminators
- Reserved word misuse

### 2. Character/Encoding Errors (7 cases)
- Bidirectional text formatting
- Invalid UTF-8 encoding
- Mixed Unicode scripts
- Invalid characters

### 3. Token Validation Errors (15 cases)
- Empty or malformed identifiers
- Invalid numbers
- Unexpected tokens
- Wrong token context

### 4. System Limit Errors (1 case)
- Atom length limits

### 5. Version Control Errors (1 case)  
- Merge conflict markers

## Implementation Notes

1. **Error Propagation**: Most modules use `{:error, reason}` pattern to propagate errors from lower-level functions
2. **Context Preservation**: Errors often include position information (line/column) in commented code
3. **Recovery Points**: Some errors indicate potential sync points for error recovery
4. **Specificity**: Error reasons are specific atoms that clearly indicate the error type
5. **Unimplemented**: Many error handling paths are commented out, indicating incomplete error recovery implementation

## Missing Error Handling

Based on the codebase analysis, error handling is **not fully implemented**. Most error cases return error tuples but don't include:
- Position information in the actual returns
- Error recovery mechanisms
- Detailed error messages for users
- Sync point recovery as mentioned in the design docs

This aligns with the CLAUDE.md documentation stating "Error handling not implemented - No error recovery or error tokens".