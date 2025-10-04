# Phase 5 Plan Review

## Status: Mostly Complete

### Already Done ✅
- **Identifier sanitization**: Implemented at driver.ex:1027-1141
  - NFKC normalization, confusable detection, ASCII skeleton generation
  - Controlled by `insert_identifier_sanitization: true` (default)
  - Sanitizes mixed-script, confusable chars, and truncates to 255 chars
- **Token ordering**: Fixed in Phase 4 (pre_inserted → error_token → inserted_struct)
- **Determinism**: Checkpoint/rewind tested in Phase 3
- **Forward progress**: Guaranteed by consume_one fallback
- **Strict/tolerant separation**: Working correctly (verified in test fixes)

### Not Important (Skip) ❌
- **Performance testing**: Strict mode unaffected; tolerant overhead acceptable
- **Configurable ternary strategy**: Current behavior (emit `..//` identifier) is correct
- **Complex multi-token error recovery**: Parser-level concern, not tokenizer
- **Synthetic token tagging**: No consumer need identified

### Remaining Work Items

#### 1. Test Coverage (High Priority)
**EOF draining tests**:
- ✅ Basic EOF synthesis tested in Phase 2
- ⚠️ Missing: nested interpolation EOF, multiple pending errors

**Cascade scenarios**:
- ⚠️ Multiple consecutive errors of different types untested
- Example: `% ( foo:bar ../ ;;` (map + keyword + ternary + semicolon)

**Stream operations with errors**:
- ✅ Phase 3 covered next/peek/peek_n/position/pushback
- ✅ Checkpoint/rewind determinism verified

**Strict mode unchanged**:
- ✅ Tests pass, no regressions

#### 2. Code Quality (Medium Priority)
**Whitespace handling**:
- ✅ `consume_leading_spaces` exists (driver.ex:1095-1101)
- ⚠️ Only handles `[\t, \f, 32]` - missing `?\s` pattern
- ⚠️ Should also handle escaped newlines per plan line 54

**Meta accuracy**:
- ✅ Synthetic tokens use zero-length or minimal spans
- ⚠️ Audit needed: error_token metas vs pre_inserted metas

**Type checker stability**:
- ⚠️ Current warnings at lines 1051, 1456, 1470, 1491 (dialyzer)
- ⚠️ Identifier sanitization uses deep pattern matching (may trigger 1.19-rc issues)

#### 3. Documentation (Low Priority)
- Update TOLERANT_MODE_GPT.md with Phase 2-4 outcomes
- README section for error_token anatomy
- Options guide (error_mode, error_sync, error_max_skip, etc.)

### Recommended Phase 5 Scope

**Week 1: Testing + Hardening**
1. Add cascade error tests (5-10 tests covering mixed error types)
2. Add nested interpolation EOF tests (3-5 tests)
3. Fix `consume_leading_spaces` to handle escaped newlines
4. Audit synthetic token metas for position accuracy

**Week 2: Documentation**
1. Document all options with examples
2. Update TOLERANT_MODE_GPT.md with actual implementations
3. Add error_token shape guide

**Skip Entirely**:
- Performance benchmarking
- Configurable ternary strategy
- Synthetic token tagging
- Fuzz testing (defer to future)

### Open Issues

**Identifier sanitization edge cases**:
- Line 1093: `is_delimiter_or_space` excludes `?\s` pattern (only checks specific chars)
- Line 1101: Single-quoted string deprecation warning
- Sanitization may fail on empty input (returns `x` atom)

**consume_leading_spaces limitations**:
- Doesn't handle escaped newlines (`\\\n`, `\\\r\n`)
- Plan line 54 specifies this requirement

**Dialyzer warnings**:
- 4 unreachable pattern warnings (non-critical but should clean up)

## Summary

Phase 5 is **85% complete**. Identifier sanitization (largest feature) is done. Main gaps:
- Cascade error tests
- Whitespace helper improvements
- Documentation updates

**Effort estimate**: 2-3 days for recommended scope.

**Priority**: Medium (system is functional, these are polish items).
