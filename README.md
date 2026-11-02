# Kiro × Spotify Harness

Bộ kit giúp **Kiro IDE tự setup** cho một project bất kỳ một workflow theo mô hình harness của Spotify (agent nền **Honk**): agent chỉ làm một việc là nhận spec và sửa code; việc kiểm chứng, chặn lệnh nguy hiểm, LLM judge độc lập, cổng trước khi push/PR và chạy hàng loạt repo do lớp harness đảm nhận.

---

## Dành cho bạn (người dùng): cách dùng trong 1 phút

1. Mở **project cần setup** trong Kiro (project phải là git repo).
2. Mở chat với agent mặc định (chế độ Supervised để duyệt từng lệnh) và gửi:

   > Đọc file `/Users/quocphamminh/Desktop/Test/kiro-spotify-harness/README.md` và thực hiện đúng mục **KIRO SETUP PROTOCOL** cho project này.

3. Duyệt các lệnh Kiro xin chạy. Khi Kiro báo `HARNESS SELFTEST: PASS` và `HARNESS LOCKED` là xong.
4. **Mở một session mới** (để Kiro nạp hook, agent và steering mới), rồi làm theo mục **Quy trình làm việc sau khi setup**.

Nâng cấp sau này: tự chạy trong terminal `bash .kiro/harness/setup.sh unlock`, rồi `bash <kit>/install.sh --force <project>`.

---

## KIRO SETUP PROTOCOL

> **Gửi agent Kiro:** đây là một spec. Làm tuần tự từng bước, không bỏ bước, không làm thêm việc ngoài danh sách. Đặt `KIT` = thư mục chứa file README này (ví dụ `/Users/quocphamminh/Desktop/Test/kiro-spotify-harness`), `PROJECT` = thư mục gốc của workspace hiện tại. Nếu gặp điều kiện **DỪNG**, báo người dùng đúng lý do và chờ trả lời.

### Luật chung khi setup
- **Không bao giờ tự tạo, sửa hay xóa file trong `.kiro/harness/`, `.kiro/hooks/`, `.kiro/agents/`, `.kiro/steering/harness-*`.** Các file này chỉ được ghi bởi `install.sh`. Cấu hình chỉ qua lệnh `bash .kiro/harness/setup.sh ...`.
- Không sửa code ứng dụng, không đổi dependency, không commit, không push trong quá trình setup.
- Lệnh kiểm chứng phải là lệnh **thật** mà project đang dùng (lấy từ CI, Makefile, README, `package.json`, Gradle). Không bịa lệnh, không thêm lệnh luôn pass như `true` hay `echo`.

### Bước 1 — Kiểm tra điều kiện
- Chạy `git -C "$PROJECT" rev-parse --show-toplevel`. Nếu lỗi: **DỪNG**, hỏi người dùng có muốn `git init` không.
- Chạy `git -C "$PROJECT" status --porcelain`. Nếu có thay đổi chưa commit: báo cho người dùng biết rồi tiếp tục; installer không đụng vào code.
- Nếu `PROJECT/.kiro/harness/state/locked` tồn tại: harness đã được cài và khóa. **DỪNG**, báo người dùng rằng việc nâng cấp do họ tự làm (xem mục "Dành cho bạn").

### Bước 2 — Cài đặt
- Chạy `bash "$KIT/install.sh" "$PROJECT"`. Thêm `--with-ci` nếu project có thư mục `.github/` hoặc người dùng muốn có CI.
- Kỳ vọng thấy dòng `INSTALL OK`, kèm theo kết quả của `setup.sh detect`.

### Bước 3 — Hiểu project
- Đọc kết quả `detect` (có thể chạy lại `bash .kiro/harness/setup.sh detect`).
- Đọc các file CI và build mà `detect` liệt kê, `README` của project và các file build gốc để tìm lệnh **format/lint**, **build** và **test** mà team đang dùng.

### Bước 4 — Cấu hình verifier
Mục tiêu (Spotify): verifier tự kích hoạt, ẩn chi tiết build, chạy nhanh và mang tính quyết định.
- **Quick** (chạy sau mỗi lần lưu file, nên dưới khoảng 30 giây): chỉ format hoặc lint.
- **Full** (trước khi dừng và trước khi ship): lint + build/compile + unit test.

Chọn một trong hai cách:
- **Dùng auto-detect có sẵn** (Node script `lint/typecheck/build/test`, Gradle, Maven, Python ruff/pytest, Go, Rust). Với Gradle/Android, phải đặt task nhẹ thay cho `check`, ví dụ:
  `bash .kiro/harness/setup.sh set HARNESS_GRADLE_TASKS "ktlintCheck testDebugUnitTest"`
  (chỉ dùng task thật sự có trong build; `detect` có liệt kê plugin gợi ý).
- **Khai báo tường minh**, khi auto-detect sai hoặc thiếu:
  `bash .kiro/harness/setup.sh set HARNESS_AUTODETECT 0`
  `bash .kiro/harness/setup.sh add-verifier lint quick "<lệnh lint thật>"`
  `bash .kiro/harness/setup.sh add-verifier unit full "<lệnh test thật>"`
- Nếu nhánh chính không phải `main`/`master`: `bash .kiro/harness/setup.sh set HARNESS_BASE origin/<nhánh>`.

### Bước 5 — Baseline phải xanh
- Chạy `bash .kiro/harness/setup.sh baseline`.
- `BASELINE GREEN` → sang bước 6.
- Lỗi do **cấu hình verifier sai** (sai tên task, sai lệnh): sửa bằng `setup.sh set/add-verifier/remove-verifier`, chạy lại. Tối đa 3 lần.
- Lỗi do **code hoặc test đang hỏng sẵn**: **DỪNG**. Báo người dùng danh sách lỗi. Không sửa code, không bỏ test để cho xanh: harness trên nền đỏ là vô nghĩa.
- Báo cho người dùng thời gian baseline. Nếu trên 10 phút, đề xuất task Gradle/test hẹp hơn.

### Bước 6 — Steering của project ("golden state")
Tạo những file **chưa có**; nếu file đã có thì giữ nguyên, không ghi đè. Mỗi file ngắn (≤ 60 dòng), dựa trên những gì **thực sự có** trong repo:
- `.kiro/steering/product.md` (`inclusion: always`): sản phẩm làm gì, cho ai, các luồng chính.
- `.kiro/steering/tech.md` (`inclusion: always`): ngôn ngữ, framework, phiên bản, thư viện chính, lệnh build/test (trỏ tới `verify.sh`, không lặp lại lệnh Gradle).
- `.kiro/steering/structure.md` (`inclusion: always`): cấu trúc thư mục, module, layer và quy ước đặt tên.
- `.kiro/steering/golden-paths.md` (`inclusion: always`): 3–6 pattern **chuẩn** đang dùng trong repo (ví dụ cách viết ViewModel, repository, test, gọi API), mỗi pattern kèm một đường dẫn file mẫu dạng `#[[file:path/to/Example.kt]]` và liệt kê các pattern cũ không được dùng lại. Spotify ghi nhận agent làm tốt hơn hẳn khi codebase nhất quán và có code mẫu để bắt chước.

Front matter phải nằm ở dòng đầu tiên của file:
```
---
inclusion: always
---
```

### Bước 7 — CI (chỉ khi đã cài với `--with-ci`)
- Mở `.github/workflows/harness-verify.yml` và thay khối `TODO(setup)` bằng bước cài toolchain đúng cho project (ví dụ `actions/setup-java` + JDK theo `tech.md`, `actions/setup-node`). Không sửa các bước khác.

### Bước 8 — Selftest và khóa
- Chạy `bash .kiro/harness/setup.sh selftest`. Mọi dòng phải là `PASS`. Nếu có `FAIL`: quay lại bước tương ứng.
- Chạy `bash .kiro/harness/setup.sh lock`.

### Bước 9 — Báo cáo cho người dùng
Trả lời ngắn gọn gồm:
1. Bảng verifier: tên, quick hay full, lệnh, thời gian baseline.
2. Các file steering đã tạo.
3. Những việc người dùng phải tự làm:
   - mở **session mới**;
   - commit thư mục `.kiro/` (và `.github/workflows/harness-verify.yml` nếu có) để cả team dùng chung;
   - tùy chọn: thêm rule quyền ở cấp user (mục "Lớp quyền cấp user" bên dưới);
   - tùy chọn: đặt `KIRO_API_KEY` nếu muốn chạy fleet.
4. Rủi ro còn lại, ví dụ project không có unit test thì verifier chỉ bảo vệ được ở mức compile.

### Tiêu chí hoàn thành (EARS)
- WHEN setup kết thúc THE SYSTEM SHALL có `HARNESS SELFTEST: PASS` và file `.kiro/harness/state/locked`.
- WHEN chạy `bash .kiro/harness/verify.sh --full` trên cây code sạch THE SYSTEM SHALL in `VERIFY OK` và chạy ít nhất một verifier test hoặc build thật.
- IF baseline đỏ vì code có sẵn THEN THE SYSTEM SHALL dừng và báo lỗi, không thay đổi code hay test.
- THE SYSTEM SHALL NOT sửa file ứng dụng, dependency hay file steering đã có của người dùng.

---

## Quy trình làm việc sau khi setup

| Bước | Ai | Làm gì |
|---|---|---|
| 1. Viết spec | Bạn + Kiro | Specs → `+`. Steering `harness-spec-guide` tự nạp: trạng thái đích, **khi nào KHÔNG làm**, ví dụ trước/sau, tiêu chí EARS kiểm chứng được, một thay đổi mỗi task. Xem mẫu `.kiro/specs/_example-…` |
| 2. Code | Agent **harness-coder** | Chọn agent `harness-coder`, chạy từng task. Mỗi lần lưu file → verify quick. Khi agent dừng → verify full. Xong → agent viết `retro.md` |
| 3. Judge | Agent **harness-judge** ở **session mới** | Gõ "judge". Agent chỉ đọc (Kiro chặn mọi lệnh ghi file), chạy `judge-packet.sh`, chấm theo checklist, ghi PASS/FAIL. Session đã sửa code bị chặn không cho ghi verdict |
| 4. Sửa nếu FAIL | harness-coder | Dán lý do veto vào session code, sửa, rồi quay lại bước 3 |
| 5. Ship | **Bạn** trong terminal | `git commit` rồi `bash .kiro/harness/ship.sh`: chỉ push và mở PR khi gate mở (verify PASS + judge PASS trên đúng cây code này). PR kèm bằng chứng verify, verdict và retro |
| 6. Cải tiến spec | Bạn | Đọc `retro.md`, bổ sung phần còn thiếu vào spec để lần sau dùng lại |
| Fleet | Bạn / CI | `bash .kiro/harness/fleet.sh repos.txt path/to/spec [--dry-run]`: áp một spec cho nhiều repo bằng Kiro CLI headless, xuất `fleet-report.tsv` |

Xem trạng thái bất cứ lúc nào: `bash .kiro/harness/setup.sh status`.

---

## Kế thừa ưu điểm của Spotify Harness

| Ưu điểm của Spotify | Cách bộ kit hiện thực trong Kiro |
|---|---|
| Agent tập trung, ít công cụ → kết quả dễ đoán | Agent `harness-coder`: chỉ có `read/write/shell`, không web, không MCP, có allowlist lệnh; steering luôn nạp: một task, không mở rộng phạm vi |
| Prompt lớn, tĩnh, có version, dùng lại được | Spec trong `.kiro/specs/` commit vào git + `harness-spec-guide` + spec mẫu |
| Có điều kiện "khi nào không làm" | Spec bắt buộc có mục Preconditions; agent trả lời `PRECONDITION NOT MET`, fleet tự đánh SKIP |
| Đích đến kiểm chứng được | Tiêu chí EARS ánh xạ vào test; "Done" = `VERIFY OK` |
| Verifier tự kích hoạt, ẩn chi tiết build, output ngắn | `verify.sh`: auto-detect + verifier khai báo; trả về `VERIFY OK` hoặc tối đa 40 dòng lỗi đã lọc |
| Phản hồi tăng dần (inner loop) | Hook `PostFileSave` → verify quick |
| Stop hook: không PR khi verifier fail | Hook `Stop` → verify full; **gate** chặn `git push`/`gh pr create` của agent, đồng thời là điều kiện của `ship.sh` và `fleet.sh` |
| LLM judge chặn việc làm vượt phạm vi | Agent `harness-judge` chỉ đọc, chạy ở session riêng, verdict gắn với hash của cây code; đổi một dòng là phải chấm lại. Có thể đặt `model` khác cho judge trong `harness-judge.json` |
| Git tool hạn chế, bash allowlist | 2 lớp: quyền trong agent profile (Kiro thực thi thật) + hook `guard-shell.sh` |
| Agent không biết và không sửa được harness | Ghi file và lệnh shell vào `.kiro/harness`, `hooks`, `agents` đều bị chặn; cấu hình bị khóa sau setup; chỉ người dùng mở khóa được trong terminal thật |
| Hạ tầng bên ngoài lo push/PR | `ship.sh` và `fleet.sh` do người dùng hoặc CI chạy; agent bị chặn không chạy được |
| Fleet Management (nhiều repo) | `fleet.sh` + Kiro CLI headless: branch → coder → verify → judge (một lần chạy riêng, tức session riêng) → gate → commit → PR |
| Codebase nhất quán / golden state | `golden-paths.md` sinh lúc setup, trỏ tới file mẫu thật trong repo |
| Đổi được agent/model | Spec và script không phụ thuộc agent (Claude Code, Codex… đều chạy được `verify.sh`, `gate.sh`); model đặt riêng cho từng agent profile |
| Quan sát (trace/MLflow) | `state/trace.log` (mọi tool call), `verdict-history.log`, `fleet-report.tsv` |
| Hỏi agent góp ý cho prompt | `retro.md` sau mỗi lần chạy, được đưa vào PR |
| *Spotify ghi là việc tương lai:* outer loop trên CI | `ci/harness-verify.yml` chạy cùng bộ verifier trên mỗi PR |

**Phần chưa kế thừa được:** sandbox container ít quyền (hãy chạy Kiro trong dev container/VM, hoặc thử `kiro-cli --sandbox`), chạy hàng nghìn phiên song song trên Kubernetes, và đánh giá có hệ thống chất lượng judge/prompt (Spotify cũng chưa có).

---

## Lớp quyền cấp user (tùy chọn, bạn tự thêm)

Agent không được ghi vào `~/.kiro`, nên phần này bạn tự thêm vào `~/.kiro/settings/permissions.yaml`. Quy tắc `deny` thắng mọi `allow`, bất kể agent nào:

```yaml
rules:
  - capability: shell
    match: ["git push --force*", "git push -f*", "git config *", "sudo *", "rm -rf /*", "rm -rf ~*"]
    effect: deny
  - capability: shell
    match: ["bash .kiro/harness/verify.sh*", "bash .kiro/harness/setup.sh status*", "git status*", "git diff*"]
    effect: allow
```

---

## Cấu trúc kit

```
kiro-spotify-harness/
├── README.md                 # file này (con người + KIRO SETUP PROTOCOL)
├── install.sh                # cài idempotent vào project, không ghi đè file của bạn
├── ci/harness-verify.yml     # outer loop trên GitHub Actions
└── template/.kiro/
    ├── hooks/spotify-harness.json        # guard shell, guard write, quick verify, trace, stop verify
    ├── agents/harness-coder.json         # agent sửa code, quyền hẹp
    ├── agents/harness-judge.json         # agent judge, chỉ đọc
    ├── steering/harness-principles.md    # always
    ├── steering/harness-judge.md         # manual (#harness-judge)
    ├── steering/harness-spec-guide.md    # auto, khi viết spec
    ├── specs/_example-simpledateformat-to-javatime/
    └── harness/
        ├── setup.sh   detect | set | add-verifier | remove-verifier | baseline | selftest | lock | unlock | status
        ├── verify.sh  gate.sh  guard-shell.sh  guard-write.sh  trace.sh
        ├── judge-packet.sh  record-verdict.sh  ship.sh  fleet.sh  lib.sh
        └── (sinh ra) config.sh, verifiers.local.sh, state/ (đã gitignore)
```

## Giới hạn đã biết

- **Đã kiểm thử bằng mô phỏng, chưa chạy trong Kiro thật.** Toàn bộ quy trình đã chạy thử trên Linux với repo mẫu: install, detect, cấu hình, baseline, selftest 16/16, lock, các lệnh bị chặn, gate, push lên remote. Hook và agent profile viết theo tài liệu Kiro 1.x. Nếu Kiro của bạn không hiện 5 hook `harness-*` hoặc 2 agent, hãy chạy `setup.sh selftest` và kiểm tra phiên bản Kiro.
- Theo tài liệu Kiro, hook `Stop` chỉ báo lỗi cho agent chứ không ép agent làm tiếp; chỗ chặn thật là gate ở `PreToolUse` và trong `ship.sh`.
- Guard bằng regex là lớp thứ hai. Lớp mạnh hơn là permissions trong agent profile. Khi dùng agent mặc định thay cho `harness-coder`, chỉ còn lớp hook.
- Cơ chế "judge độc lập" dựa vào trường `session_id` trong payload của hook. Nếu bản Kiro không gửi trường này, vẫn còn quyền chỉ-đọc của agent judge và gate.
- `fleet.sh` dùng đúng các flag trong tài liệu headless của Kiro CLI (`--v3 --no-interactive --trust-all-tools --agent`) nhưng chưa được chạy với `kiro-cli` thật; hãy thử `--dry-run` trên 1–2 repo trước.

## Nguồn

- Spotify Engineering — Honk [Part 1](https://engineering.atspotify.com/2025/11/spotifys-background-coding-agent-part-1), [Part 2](https://engineering.atspotify.com/2025/11/context-engineering-background-coding-agents-part-2), [Part 3](https://engineering.atspotify.com/2025/12/feedback-loops-background-coding-agents-part-3), [Coding is no longer the constraint](https://engineering.atspotify.com/2026/6/code-with-claude-coding-is-no-longer-the-constraint)
- Kiro docs: [Hooks](https://kiro.dev/docs/hooks/index), [Hook triggers](https://kiro.dev/docs/hooks/types/), [Hook actions](https://kiro.dev/docs/hooks/actions/), [Steering](https://kiro.dev/docs/steering/), [Specs](https://kiro.dev/docs/specs/), [Custom agents](https://kiro.dev/docs/custom-agents/configuration-reference/), [Permissions](https://kiro.dev/docs/permissions/), [CLI headless](https://kiro.dev/docs/cli/headless/), [What's new 1.0](https://kiro.dev/docs/ide/whats-new-v1/)
