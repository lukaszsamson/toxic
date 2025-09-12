# Warning Cases in Toxic Tokenizer

This document catalogs all warning cases found in the Toxic tokenizer codebase, organized by file with code positions and descriptions. All warnings are currently commented out and marked with `TODO: warn`, indicating they are not yet implemented.

## Summary

Total warning patterns found: **20** across **4** files

All warnings are **disabled/commented out** and require implementation.

## Files with Warning Cases

### lib/toxic/tokenizer.ex (12 warning cases)

The main tokenizer module contains the majority of warning patterns:

**Lines 73-93**: Character literal warnings
- **Context**: `?\\` character literal processing
- **Trigger**: Various character escape scenarios
- **Warnings**:
  - Line 81: `prepend_warning` - "found ?\\ followed by code point 0x~.16B (~ts), please use ?~ts instead"
  - Line 85: `prepend_warning` - "unknown escape sequence ?\\~tc, use ?~tc instead"
- **Description**: Warns about deprecated character literal syntax and suggests modern alternatives

**Lines 110-118**: Character literal warnings (simple form)
- **Context**: `?` character literal processing without backslash
- **Trigger**: Characters that have better escape representations
- **Warning**:
  - Line 116: `prepend_warning` - "found ? followed by code point 0x~.16B (~ts), please use ?~ts instead"
- **Description**: Similar to above but for non-escaped character literals

**Line 143-147**: Charlist heredoc deprecation warning
- **Context**: Single-quoted heredoc strings (`'''`)
- **Trigger**: Usage of `'''` heredoc syntax
- **Warning**:
  - Line 146: `prepend_warning` - "single-quoted string represent charlists. Use ~c''' if you indeed want a charlist or use \"\"\" instead"
- **Description**: Warns against single-quoted strings that represent charlists

**Line 157-160**: Charlist string deprecation warning
- **Context**: Single-quoted strings (`'`)
- **Trigger**: Usage of single-quoted string syntax
- **Warning**: Similar charlist warning as heredoc case
- **Description**: Warns against single-quoted strings representing charlists

**Lines 197-202**: Atom syntax ambiguity warning
- **Context**: Triple-colon atom literal (`:::`)
- **Trigger**: Usage of `:::` atom syntax
- **Warning**:
  - Line 200: `prepend_warning` - "atom ::: must be written between quotes, as in :\"::\", to avoid ambiguity"
- **Description**: Prevents ambiguous atom syntax that could be confused with operators

**Line 258**: Repeated character operator warning
- **Context**: Three-token operators like `+++`, `---`, etc.
- **Trigger**: Multiple consecutive identical operator characters
- **Warning**:
  - `maybe_warn_too_many_of_same_char` - Warns about potentially confusing repeated characters
- **Description**: Helps prevent operator confusion and typos

**Lines 378-382**: Deprecated atom quote syntax
- **Context**: Single-quoted atom literals (`:''`)
- **Trigger**: Usage of `:'atom'` syntax
- **Warning**:
  - Line 380: `prepend_warning` - "single quotes around atoms are deprecated. Use double quotes instead"
- **Description**: Enforces modern double-quote atom syntax

**Line 405**: Ambiguous bang operator warning
- **Context**: Atom processing with potential `!=` ambiguity
- **Trigger**: Patterns that could be confused with bang-equals operator
- **Warning**:
  - `maybe_warn_for_ambiguous_bang_before_equals` - Warns about potential operator confusion
- **Description**: Prevents confusion between identifiers and operators

**Line 622**: Ambiguous bang operator warning (identifier context)
- **Context**: Identifier processing with potential `!=` ambiguity
- **Trigger**: Similar to above but for identifiers
- **Warning**:
  - `maybe_warn_for_ambiguous_bang_before_equals` - Same as above for identifiers
- **Description**: Same as above but applies to identifier contexts

### lib/toxic/operator.ex (4 warning cases)

Operator deprecation warnings:

**Lines 117-134**: Deprecated operator warnings
- **Context**: Processing of deprecated bitwise and pipe operators
- **Triggers and warnings**:
  - Line 124: `prepend_warning` - `^^^` operator: "^^^ is deprecated. It is typically used as xor but it has the wrong precedence, use Bitwise.bxor/2 instead"
  - Line 128: `prepend_warning` - `~~~` operator: "~~~ is deprecated. Use Bitwise.bnot/1 instead for clarity"
  - Line 132: `prepend_warning` - `<|>` operator: "<|> is deprecated. Use another pipe-like operator"
- **Description**: Warns about deprecated bitwise and pipe operators, suggesting modern alternatives

### lib/toxic/dot.ex (2 warning cases)

Dot syntax warnings:

**Line 64**: `TODO: warning` comment
- **Context**: General dot syntax processing
- **Description**: Placeholder for unspecified dot-related warning

**Lines 66-70**: Deprecated quote syntax in calls
- **Context**: Single-quoted function/method calls after dot
- **Trigger**: Usage of `.'method'` syntax
- **Warning**:
  - Line 68: `prepend_warning` - "single quotes around calls are deprecated. Use double quotes instead"
- **Description**: Enforces modern double-quote syntax for method calls

### lib/toxic/interpolation.ex (2 warning cases)

String interpolation warnings:

**Line 158**: `TODO: warn` comment
- **Context**: General interpolation processing
- **Description**: Placeholder for unspecified interpolation warning

**Lines 164-167**: Deprecated sigil escape warning
- **Context**: Uppercase sigil escape sequences
- **Trigger**: Using `\` to escape closing delimiter in uppercase sigils
- **Warning**:
  - Line 166: `prepend_warning` - "using \\~ts to escape the closing of an uppercase sigil is deprecated, please use another delimiter or a lowercase sigil instead"
- **Description**: Discourages escape usage in uppercase sigils

## Warning Categories

### 1. Deprecation Warnings (12 cases)
- Single-quoted strings/atoms/calls
- Deprecated operators (`^^^`, `~~~`, `<|>`)
- Character literal syntax
- Sigil escape sequences

### 2. Ambiguity Prevention Warnings (4 cases)
- Bang operator confusion (`!=` vs identifier)
- Atom syntax ambiguity (`:::`)
- Repeated character operators

### 3. Syntax Modernization Warnings (4 cases)
- Character literal improvements
- Quote style consistency
- Charlist vs string distinction

## Implementation Status

### ❌ Not Implemented
- **All warning functionality is commented out**
- No `prepend_warning` function implementation found
- No warning emission mechanism in place
- Warning helper functions like `maybe_warn_too_many_of_same_char` are undefined

### 🔧 Missing Components
1. **Warning Infrastructure**:
   - `prepend_warning/4` function
   - `maybe_warn_too_many_of_same_char/6` function  
   - `maybe_warn_for_ambiguous_bang_before_equals/6` function
   - `handle_char/1` function for character validation

2. **Warning Storage**:
   - Scope-based warning accumulation
   - Warning message formatting
   - Position tracking for warnings

3. **Warning Emission**:
   - Integration with error/warning reporting system
   - Configurable warning levels
   - Warning suppression mechanisms

## Implementation Priority

### High Priority (Deprecation Warnings)
1. **Single-quote deprecation** - Most common user-facing issue
2. **Deprecated operators** - Prevents future compatibility issues
3. **Character literal modernization** - Syntax consistency

### Medium Priority (Ambiguity Prevention)  
1. **Bang operator warnings** - Prevents subtle bugs
2. **Atom syntax warnings** - Parser clarity

### Low Priority (Style/Consistency)
1. **Repeated character warnings** - Code style/clarity
2. **Sigil escape warnings** - Advanced usage patterns

## Relationship to Error Handling

Unlike error cases which halt parsing, warnings should:
- Continue tokenization after emission  
- Be accumulated in tokenizer scope
- Be retrievable after parsing completion
- Support severity levels and filtering
- Maintain position information for IDE integration

## Implementation Recommendations

When implementing warning system:

1. **Create warning infrastructure first**:
   - Define warning types and severity levels
   - Implement scope-based warning collection
   - Add position tracking for warnings

2. **Implement high-impact warnings**:
   - Start with deprecation warnings (most user-visible)
   - Focus on single-quote related warnings first
   - Add operator deprecation warnings

3. **Add configuration support**:
   - Allow warnings to be enabled/disabled
   - Support warning-as-error modes  
   - Provide granular control over warning types

4. **Integration considerations**:
   - Ensure warnings work with streaming tokenization
   - Support incremental re-parsing scenarios
   - Consider performance impact of warning checks