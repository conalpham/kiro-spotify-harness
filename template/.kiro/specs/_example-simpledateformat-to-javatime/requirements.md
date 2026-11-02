# Requirements: replace SimpleDateFormat with java.time

> Example spec written in the harness style. Copy this folder (without the leading `_`) as a starting point.

## Goal (end state)
Every date formatting/parsing in `app/src/main` uses `java.time` (`DateTimeFormatter`, `LocalDate`, `Instant`, `ZonedDateTime`). No `java.text.SimpleDateFormat` import remains in production code. Behaviour, output strings and time zones stay exactly the same.

## Preconditions / when NOT to act
- IF `minSdk` < 26 AND `coreLibraryDesugaringEnabled` is not `true` THEN stop and reply `PRECONDITION NOT MET: java.time not available`.
- IF a `SimpleDateFormat` pattern relies on lenient parsing (`isLenient = true`) THEN leave that call untouched and list it in the retro.
- Do not touch test code, generated code (`build/`) or third-party modules.

## Examples
Before:
```kotlin
private val fmt = SimpleDateFormat("dd/MM/yyyy", Locale.US)
fun label(date: Date): String = fmt.format(date)
```
After:
```kotlin
private val fmt = DateTimeFormatter.ofPattern("dd/MM/yyyy", Locale.US)
fun label(date: Date): String =
    date.toInstant().atZone(ZoneId.systemDefault()).toLocalDate().format(fmt)
```

## Acceptance criteria (EARS)
1. WHEN the project is built THE SYSTEM SHALL contain no `import java.text.SimpleDateFormat` under `app/src/main`.
2. WHEN `label()` and every other migrated function receives the inputs in the existing unit tests THE SYSTEM SHALL return the same strings as before.
3. IF a migrated function has no unit test THEN THE SYSTEM SHALL gain one that pins the current output before the migration.
4. WHEN `bash .kiro/harness/verify.sh --full` runs THE SYSTEM SHALL print `VERIFY OK`.

## Out of scope
- Changing date patterns, locales or time zones.
- Replacing `java.util.Date` in public signatures.
- Any other refactor in the touched files.
