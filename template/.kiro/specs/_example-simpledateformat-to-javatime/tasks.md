# Tasks

- [ ] 1. Check preconditions (minSdk / desugaring, lenient parsers) and report if not met
  - Verification: reply contains either "preconditions OK" or `PRECONDITION NOT MET: ...`
- [ ] 2. Add characterisation tests for every function that uses SimpleDateFormat and has no test
  - Verification: `bash .kiro/harness/verify.sh --full` → `VERIFY OK`
- [ ] 3. Migrate formatting call sites to DateTimeFormatter (one file per commit)
  - Verification: tests from task 2 pass unchanged; `verify.sh --full` → `VERIFY OK`
- [ ] 4. Migrate parsing call sites, keeping the same error fallback
  - Verification: `verify.sh --full` → `VERIFY OK`; no `SimpleDateFormat` import left in `app/src/main`
- [ ] 5. Write `retro.md` and hand over for judging (`#harness-judge` in a new chat)
