# Design

- `DateTimeFormatter` is immutable and thread-safe, so a shared `private val` is fine (unlike `SimpleDateFormat`).
- Conversion path from `java.util.Date`: `date.toInstant().atZone(ZoneId.systemDefault())`, then `.toLocalDate()` / `.toLocalDateTime()` depending on whether the pattern contains a time.
- Parsing: `LocalDate.parse(text, fmt)`; wrap `DateTimeParseException` where the old code caught `ParseException`, keeping the same fallback behaviour.
- Testing strategy: characterisation tests first (pin current output), then migrate, then the same tests must pass unchanged.
