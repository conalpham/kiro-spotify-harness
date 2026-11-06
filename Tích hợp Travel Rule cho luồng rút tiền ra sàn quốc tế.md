# Tích hợp Travel Rule cho luồng rút tiền ra sàn quốc tế

Nov 4, 2026 · @Mincuk

## Tổng quan

Khi khách rút tiền ra một sàn quốc tế, sàn của bạn là **sàn gửi** (originator VASP). Sàn phải trao đổi xong dữ liệu người gửi và người nhận với sàn đích **trước khi** ký và broadcast giao dịch on-chain. Tài liệu này mô tả luồng đó qua từng kênh (Notabene, Sumsub, GTR, TRUST) bằng sơ đồ sequence. Luồng chiều ngược (sàn khác rút về sàn của bạn) được mô tả ngắn ở phần cuối.

Trên sơ đồ, các thành phần phía sàn của bạn mang tên như sau:

| Tên trên sơ đồ | Vai trò |
| --- | --- |
| App / Web | Màn hình rút tiền: thu thập ví đích, sàn nhận, tên người nhận |
| Withdrawal service | Quản lý lệnh rút; chỉ ký và broadcast khi Travel Rule cho phép |
| TravelRuleService | Xét ngưỡng, chọn kênh, gọi bên thứ ba, giữ trạng thái |
| Outbox / DB | Ghi bản ghi trước khi gọi API, đảm bảo gọi lại được với cùng `requestId` |
| Webhook receiver | Nhận webhook của Notabene/Sumsub, xác minh chữ ký, ghi inbox, trả 200 ngay |
| Wallet / Signer | Ký giao dịch, broadcast lên blockchain |
| Compliance | Duyệt tay các trường hợp giữ lại, hết hạn, hoặc lệch dữ liệu |

### Chọn kênh theo sàn đích

Không có một mạng duy nhất tới được mọi sàn. `ProviderRouter` chọn kênh cho từng lệnh rút theo sàn đích:

| Sàn đích (ví dụ) | Kênh ưu tiên | Kênh dự phòng |
| --- | --- | --- |
| Binance, OKX, Bybit, Bitget, Gate, HashKey | GTR (nếu sàn của bạn là thành viên) | Sumsub (cầu nối GTR), rồi Notabene |
| Coinbase, Kraken, Gemini, Crypto.com, Robinhood | TRUST (nếu sàn của bạn là thành viên) | TRUSThub, rồi cổng chính |
| Các sàn còn lại | Cổng chính: Notabene hoặc Sumsub | Cổng còn lại, rồi email (Sumsub, GTR Out-of-Network) |
| Không xác định được sàn | Xử lý như ví cá nhân | Compliance duyệt tay |

Bảng trên là ví dụ dựa trên thành viên công bố của từng mạng. Danh sách thật nằm trong bảng `VaspDirectory` do đội compliance duy trì, cập nhật theo tỷ lệ phản hồi thực tế của từng sàn.

### Điều kiện trước khi mở luồng rút

- Khách đã KYC; có họ tên dạng Latin không dấu, ngày sinh, địa chỉ hoặc số giấy tờ, theo yêu cầu IVMS101 của khu vực pháp lý.
- Đã onboarding xong với cổng chính, và với GTR/TRUST nếu dùng.
- Đã chốt ngưỡng áp dụng theo khu vực pháp lý của sàn (FATF khuyến nghị 1.000 USD/EUR; EU áp dụng mọi giao dịch).
- Trên UI rút tiền có ô **chọn sàn nhận**. Sumsub ghi rõ đây là yếu tố lớn nhất quyết định tỷ lệ thành công, vì dò sàn chỉ từ địa chỉ ví thường thất bại.

## Luồng rút chung

Mọi kênh đều đi theo cùng một khung: **ghi DB → gửi dữ liệu → chờ kết quả → ký và broadcast → báo txHash**. Các kênh chỉ khác nhau ở bước "Gửi dữ liệu" và "Kết quả"; các phần sau triển khai chi tiết hai bước này cho từng kênh.

```mermaid
sequenceDiagram
    autonumber
    actor KH as Khách
    participant UI as App / Web
    participant WS as Withdrawal service
    participant TR as TravelRuleService
    participant DB as Outbox / DB
    participant P as Kênh Travel Rule
    participant B as Sàn đích
    participant SG as Wallet / Signer
    participant BC as Blockchain
    KH->>UI: Nhập ví đích, số tiền, chọn sàn nhận, tên người nhận
    UI->>WS: Tạo lệnh rút
    WS->>WS: Kiểm tra số dư, giới hạn, KYT địa chỉ đích
    WS->>TR: Yêu cầu Travel Rule (lệnh rút, khách, sàn nhận)
    TR->>TR: Quy đổi fiat, xét ngưỡng theo khu vực
    alt Dưới ngưỡng hoặc chuyển nội bộ
        TR->>DB: Lưu NOT_REQUIRED
        TR-->>WS: Được phép ký
    else Cần Travel Rule
        TR->>DB: Lưu PENDING_SEND kèm requestId (cùng transaction với lệnh rút)
        TR->>TR: ProviderRouter chọn kênh theo sàn nhận
        TR->>P: Gửi dữ liệu người gửi và người nhận (IVMS101), khoá requestId
        P->>B: Chuyển dữ liệu tới sàn đích
        B->>B: Xác nhận sở hữu ví, đối chiếu tên người nhận
        B-->>P: Chấp nhận hoặc từ chối
        P-->>TR: Kết quả (đồng bộ hoặc qua webhook)
        TR->>DB: Cập nhật trạng thái và lịch sử
        alt APPROVED
            TR-->>WS: Được phép ký
        else REJECTED
            TR-->>WS: Từ chối
            WS-->>UI: Báo khách lý do, cho sửa thông tin
        else ON_HOLD hoặc EXPIRED
            TR-->>WS: Giữ lệnh
            TR->>TR: Đẩy vào hàng chờ Compliance
        end
    end
    opt Được phép ký
        WS->>SG: Ký giao dịch (kiểm tra lại trạng thái APPROVED hoặc NOT_REQUIRED)
        SG->>BC: Broadcast
        BC-->>SG: txHash
        SG-->>WS: txHash
        WS->>TR: Gắn txHash
        TR->>P: Báo txHash cho kênh và sàn đích
        TR->>DB: FINISHED
        WS-->>UI: Lệnh rút đã gửi
    end
```

### Trạng thái của lệnh rút

| Trạng thái | Ý nghĩa | Được ký? |
| --- | --- | --- |
| `NOT_REQUIRED` | Dưới ngưỡng hoặc nội bộ; vẫn lưu vết | Có |
| `PENDING_SEND` | Đã ghi DB, chưa gọi kênh | Không |
| `AWAITING_COUNTERPARTY` | Đã gửi, chờ sàn đích | Không |
| `APPROVED` | Sàn đích chấp nhận hoặc rules cho đi | Có |
| `REJECTED` | Ví không thuộc sàn đích, tên lệch, hoặc bị từ chối | Không |
| `ON_HOLD` | Chờ compliance hoặc chứng minh ví cá nhân | Không |
| `EXPIRED` | Sàn đích không trả lời trong thời gian chờ | Chỉ khi compliance duyệt |
| `BROADCASTED` | Đã lên chain, chưa báo txHash | — |
| `FINISHED` | Đã báo txHash, đóng | — |
| `CANCELLED` | Khách huỷ, đã báo huỷ cho kênh | Không |

Kiểm tra "được ký" phải nằm ở **Wallet / Signer**, không chỉ ở Withdrawal service hay UI, để không đường nào bỏ qua được Travel Rule.

## Rút qua Notabene

Notabene là cổng trung gian: sàn gọi `tx/create` một lần, Notabene tự tìm sàn đích và chọn protocol. Kết quả về qua một loại webhook duy nhất. Chỉ broadcast khi trạng thái là `ACCEPTED` (hoặc `SAVED` khi không cần Travel Rule).

```mermaid
sequenceDiagram
    autonumber
    actor KH as Khách
    participant UI as App / Web
    participant WS as Withdrawal service
    participant TR as TravelRuleService
    participant WH as Webhook receiver
    participant AU as auth.notabene.id
    participant NB as api.notabene.id
    participant B as Sàn đích
    participant SG as Wallet / Signer
    KH->>UI: Nhập ví đích, chọn sàn nhận, tên người nhận
    opt Kiểm tra trước các trường cần hỏi
        UI->>NB: txValidate (hoặc dùng widget Notabene)
        NB-->>UI: Danh sách trường bắt buộc theo khu vực
    end
    UI->>WS: Tạo lệnh rút
    WS->>TR: Yêu cầu Travel Rule
    TR->>TR: Ghi PENDING_SEND, requestId
    opt Token hết hạn hoặc sắp hết (sống 24 giờ)
        TR->>AU: POST /oauth/token (client_credentials, audience)
        AU-->>TR: access_token, expires_in 86400
    end
    TR->>NB: POST /tx/create (Bearer token)
    Note right of TR: transactionRef = requestId, transactionAsset, transactionAmount (đơn vị nhỏ nhất), originatorVASPdid, beneficiaryVASPdid nếu biết, transactionBlockchainInfo, originator, beneficiary
    alt HTTP 401
        NB-->>TR: Unauthorized
        TR->>AU: Lấy token mới
        TR->>NB: Gửi lại tx/create, cùng transactionRef
    else HTTP 400
        NB-->>TR: Bad Request
        TR-->>WS: REJECTED, payload sai, không retry
    end
    NB-->>TR: 200, id và status xa nhất đã đạt
    alt status SAVED (dưới ngưỡng, nội bộ, ví cá nhân)
        TR-->>WS: NOT_REQUIRED, được phép ký
    else status NEW hoặc SENT
        NB->>B: Gửi Travel Rule qua protocol phù hợp hoặc TR:Now
        B-->>NB: ACK, xác nhận sở hữu ví
        NB-)WH: notification.transactionUpdated (ACK)
        WH->>WH: Xác minh chữ ký Svix, ghi inbox theo svix-id
        WH-->>NB: 200
        B-->>NB: ACCEPTED hoặc DECLINED
        NB-)WH: notification.transactionUpdated (ACCEPTED hoặc DECLINED)
        WH->>TR: Cập nhật trạng thái
    end
    alt ACCEPTED
        TR-->>WS: APPROVED
        WS->>SG: Ký và broadcast
        SG-->>WS: txHash
        WS->>TR: Gắn txHash
        TR->>NB: txUpdate (id, txHash)
        NB-)WH: Webhook cùng trạng thái, đã có txHash
        TR->>TR: FINISHED
    else DECLINED hoặc REJECTED (ví không thuộc sàn đích)
        TR-->>WS: REJECTED
        WS-->>UI: Báo khách kiểm tra sàn nhận hoặc tên
    else NOT_READY, WAITING_FOR_INFORMATION, quá thời gian chờ
        TR->>TR: EXPIRED, chuyển Compliance
    else Khách huỷ lệnh rút
        WS->>TR: Huỷ
        TR->>NB: txCancel (id)
    end
```

| Bước | API | Điểm cần lưu ý |
| --- | --- | --- |
| Lấy token | `POST https://auth.notabene.id/oauth/token` | `audience` = `https://api.notabene.dev` (sandbox) hoặc `https://api.notabene.id` (production). Cache token, làm mới khi hết hạn hoặc gặp 401 |
| Tạo Travel Rule | `POST https://api.notabene.id/tx/create` | `transactionRef` là khoá chống trùng. `transactionAmount` là chuỗi số nguyên theo đơn vị nhỏ nhất (satoshi, wei). Bỏ `beneficiaryVASPdid` thì Notabene tự dò; địa chỉ có nhiều chủ sẽ không dò được |
| Nhận kết quả | Webhook `notification.transactionUpdated` | Gửi qua Svix từ IP EU. Mỗi lần gửi toàn bộ bản ghi, nên xử lý bằng cách so trạng thái |
| Báo txHash | `txUpdate` | Giúp sàn đích khớp tiền về với Travel Rule; sinh thêm một webhook cùng trạng thái |
| Huỷ | `txCancel` | Gọi khi khách bỏ lệnh sau khi đã tạo Travel Rule |

Ngoài `tx/create`, tên và đường dẫn các API còn lại cần đối chiếu trong API reference của Notabene. Notabene không nối trực tiếp vào TRUST, nên lệnh rút tới thành viên TRUST nên đi kênh TRUST nếu sàn của bạn là thành viên.

## Rút qua Sumsub

Với Sumsub, lệnh rút là một giao dịch KYT `type: travelRule`, `direction: out`, gửi **trước khi** có txHash. Sumsub chọn protocol chung với sàn đích, hoặc gửi email nếu không có. Withdrawal service dựa vào **kết quả duyệt** (webhook `Approved` / `Rejected` / `OnHold`), còn trạng thái trao đổi dữ liệu lưu lại để báo cáo.

```mermaid
sequenceDiagram
    autonumber
    actor KH as Khách
    participant UI as App / Web
    participant WS as Withdrawal service
    participant TR as TravelRuleService
    participant WH as Webhook receiver
    participant SS as api.sumsub.com
    participant B as Sàn đích
    participant SG as Wallet / Signer
    UI->>SS: Get available VASPs (q = tên khách gõ)
    SS-->>UI: Danh sách sàn kèm id
    KH->>UI: Chọn sàn nhận, nhập ví đích, tên người nhận
    UI->>WS: Tạo lệnh rút (counterpartyVaspId)
    WS->>TR: Yêu cầu Travel Rule
    TR->>TR: Ghi PENDING_SEND, requestId
    TR->>SS: POST /resources/applicants/{applicantId}/kyt/txns/-/data
    Note right of TR: Header X-App-Token, X-App-Access-Ts, X-App-Access-Sig (HMAC-SHA256). Body type travelRule, info.direction out, không có paymentTxnId, counterparty.paymentMethod.accountId, counterparty.institutionInfo.internalId
    SS-->>TR: id giao dịch Sumsub
    SS-)WH: applicantKytTxnCreated
    WH->>WH: Xác minh x-payload-digest, ghi inbox, trả 200 trong 10 giây
    alt Có internalId
        SS->>SS: Bỏ qua bước dò, chọn protocol chung với sàn đích
    else Không có internalId
        SS->>SS: Dò ví: DB nội bộ, Wallet Address Book, protocol, blockchain analytics
    end
    alt Thiếu trường protocol yêu cầu
        SS-)WH: notEnoughCounterpartyData
        TR-->>UI: Hỏi khách bổ sung đúng trường còn thiếu
    else Không có protocol chung
        SS->>B: Gửi email thông báo, lưu bằng chứng
        SS-)WH: counterpartyVaspNotReachable
    else Không tìm thấy sàn
        SS-)WH: counterpartyVaspNotFound, chuyển luồng ví cá nhân
    else Gửi được
        SS->>B: Dữ liệu qua Sumsub, GTR, CODE, Sygna hoặc TRP
        SS-)WH: applicantKytTxnAwaitingUser (awaitingCounterparty)
        B-->>SS: Phản hồi của sàn đích
    end
    alt applicantKytTxnApproved
        SS-)WH: Approved
        WH->>TR: APPROVED
        TR-->>WS: Được phép ký
        WS->>SG: Ký và broadcast
        SG-->>WS: txHash
        WS->>TR: Gắn txHash
        TR->>SS: PATCH /resources/kyt/txns/{id}/data/info (paymentTxnId)
        SS->>B: Chuyển txHash cho sàn đích
        SS-)WH: applicantKytTxnDataChanged (awaitingOnChainTransfer sang finished)
    else applicantKytOnHold
        SS-)WH: OnHold
        WH->>TR: ON_HOLD, chờ Compliance hoặc chứng minh ví
    else applicantKytTxnRejected
        SS-)WH: Rejected
        WH->>TR: REJECTED
        TR-->>WS: Không ký, báo khách
    else Khách huỷ sau khi đã trao đổi
        WS->>TR: Huỷ
        TR->>SS: POST /resources/api/tr/{id}/cancel
        SS->>B: Báo huỷ qua cùng protocol
    end
```

| Bước | API | Điểm cần lưu ý |
| --- | --- | --- |
| Danh sách sàn cho UI | Get available VASPs | Tìm theo tên thương hiệu qua `q`; chọn nhóm sàn thì Sumsub tự chọn pháp nhân phù hợp |
| Ký request | 3 header `X-App-*` | Chuỗi ký = timestamp + method + path + body; lệch giờ dưới 1 phút. Sandbox và production cùng host, phân biệt bằng token `sbx:` / `prod:` |
| Tạo giao dịch | `POST .../kyt/txns/-/data` (khách đã là applicant) | Khách chưa là applicant: dùng API "Submit transaction without applicant". Có `paymentTxnId` thì thành luồng sau khi lên chain |
| Trường tối thiểu theo protocol | `counterparty` | GTR và CODE cần `type` và tên (`fullName`, hoặc `firstNameEn` + `lastNameEn` + `nameType`); CODE cần thêm `dob` của khách |
| Nhận kết quả | Webhook | Xác minh `x-payload-digest` theo thuật toán trong `X-Payload-Digest-Alg` (nên dùng `HMAC_SHA256_HEX`). Trả 401/403/404 thì Sumsub không gửi lại |
| Báo txHash | `PATCH /resources/kyt/txns/{id}/data/info` | Bước duy nhất đưa giao dịch về `finished`; hay bị bỏ sót nhất |
| Huỷ | `POST /resources/api/tr/{id}/cancel` | Không huỷ thì chiếm hàng chờ của sàn đích và bị ghi nhận là không phản hồi |

Có thể thay bước 1–5 bằng **Travel Rule SDK** của Sumsub: SDK tự hỏi khách chọn sàn, thu đủ trường protocol cần, xử lý ví cá nhân và tạo giao dịch. Mức hỗ trợ cầu nối sang GTR (giao dữ liệu đầy đủ hay chỉ xác thực) cần Sumsub xác nhận trước khi dựa vào Sumsub cho lệnh rút tới Binance.

## Rút qua GTR

GTR là kênh trực tiếp tới Binance và các thành viên GTR. Toàn bộ xác minh chạy **đồng bộ** trong một lời gọi `one_step` (tối đa 30 giây): GTR hỏi sàn đích địa chỉ có thuộc họ không, đúng thì mới chuyển PII. Sàn của bạn phải tự chỉ định sàn đích (`targetVaspCode`) và tự mã hoá PII bằng Curve25519.

```mermaid
sequenceDiagram
    autonumber
    actor KH as Khách
    participant UI as App / Web
    participant WS as Withdrawal service
    participant TR as TravelRuleService
    participant G as platform.globaltravelrule.com
    participant B as Sàn đích (callback server)
    participant SG as Wallet / Signer
    KH->>UI: Chọn sàn nhận (ví dụ Binance), nhập ví, tag, tên người nhận
    UI->>WS: Tạo lệnh rút
    WS->>TR: Yêu cầu Travel Rule
    TR->>TR: Ghi PENDING_SEND, requestId dạng TÊN_SÀN-UUIDv4
    opt Chưa biết sàn đích hoặc chưa có public key
        TR->>G: Detect Address, danh sách VASP
        G-->>TR: targetVaspCode, targetVaspPublicKey (cache lại)
    end
    opt Hỏi trước trường PII sàn đích cần
        TR->>G: Preflight Check
        G->>B: Callback 11
        B-->>G: Danh sách trường
        G-->>TR: Trường bắt buộc
    end
    TR->>TR: Đóng gói IVMS101-2020, mã hoá Curve25519 (piiSecuredInfo)
    TR->>TR: Sinh App token mới, hiệu lực 15 giây
    TR->>G: POST /api/verify/v2/one_step qua mTLS, header X-Authorization
    Note right of TR: verifyDirection 2, network, ticker, amount, fiatName, fiatPrice, address, tag, targetVaspCode, targetVaspPublicKey, initiatorPublicKey, expectVerifyFields, piiSecuredInfo
    G->>B: Callback 6, xác minh địa chỉ và tag
    alt Ví không thuộc sàn đích
        B-->>G: 200001 Address Not Found
        G-->>TR: verifyStatus 200001, không gửi PII
        TR-->>WS: REJECTED
        WS-->>UI: Báo khách kiểm tra lại sàn nhận
    else Ví đúng
        B-->>G: 100000
        G->>B: Callback 4, PII đã mã hoá
        B->>B: Giải mã, đối chiếu KYC người nhận
        B-->>G: verifyFields, PII mã hoá lại kèm thông tin sàn đích
        alt Khớp
            G-->>TR: verifyStatus 100000 (đồng bộ, tối đa 30 giây)
            TR-->>WS: APPROVED
            WS->>SG: Ký và broadcast
            SG-->>WS: txId
            WS->>TR: Gắn txId
            TR->>G: POST /api/verify/v2/notify_tx_id (requestId, txId)
            G->>B: Callback 7, txId ứng với requestId
            TR->>TR: FINISHED
        else Lệch PII
            G-->>TR: verifyStatus 200003, verifyFields chỉ ra trường lệch
            TR-->>WS: REJECTED
            WS-->>UI: Cho khách sửa tên người nhận, gửi lại bằng requestId mới
        end
    end
    opt Quá 30 giây hoặc lỗi mạng
        TR->>TR: ON_HOLD, không broadcast
        TR->>G: Gửi lại với cùng requestId theo backoff
    end
    opt Khách huỷ sau khi đã xác minh
        TR->>G: End Travel Rule (requestId)
    end
```

| Bước | API | Điểm cần lưu ý |
| --- | --- | --- |
| Kết nối | mTLS bằng `certificate.p12` | UAT: `uat-platform.globaltravelrule.com`. Production: `platform.globaltravelrule.com`, khoá và chứng chỉ riêng, không dùng lại khoá UAT |
| Xác thực | Header `X-Authorization` (App token) | `vaspSecretKeyHash` = SHA-512(`secretKey` + `vaspCode`); `secretToken` = SHA-512 của `accessKey`, `vaspSecretKeyHash`, `nonce`, `timestamp`, `expires`, `verifyType` nối bằng `\|`; token = Base64 của JSON các trường này |
| Tìm sàn đích | Detect Address, danh sách VASP | Cache `targetVaspCode` và public key; làm mới khi giải mã lỗi |
| Mã hoá PII | Thư viện `encryption-tools` của GTR | `piiSecretFormatType` = `FULL_JSON_OBJECT_ENCRYPT`, `piiSpecVersion` = `ivms101-2020`. Không tự cài đặt mật mã |
| Gửi Travel Rule | `POST /api/verify/v2/one_step` | Luôn trả HTTP 200, kết quả ở `verifyStatus`: `100000` thành công, `200001` sai ví, `200003` lệch PII. `fiatPrice` chốt tại thời điểm gửi |
| Báo txId | `POST /api/verify/v2/notify_tx_id` | Bắt buộc sau broadcast để sàn đích khớp tiền về |
| Huỷ | End Travel Rule | Đóng phiên khi khách bỏ lệnh |

Nếu sàn đích không có trong GTR, dùng Out-of-Network API (email bảo mật kèm link xem PII) hoặc để router chuyển sang cổng chính. Gói Trial chỉ 100 request/ngày, chỉ đủ cho UAT.

## Rút qua TRUST

TRUST là kênh trực tiếp tới Coinbase, Kraken, Gemini, Crypto.com và các thành viên khác, nhưng chỉ dùng được khi sàn của bạn cũng là thành viên. TRUST không công bố spec API; sơ đồ dưới đây là luồng nguyên lý dựa trên mô tả công khai: **chứng minh sở hữu địa chỉ trước, rồi mới gửi PII trực tiếp giữa hai sàn**. Tên thông điệp thật lấy theo spec cấp cho thành viên.

```mermaid
sequenceDiagram
    autonumber
    actor KH as Khách
    participant UI as App / Web
    participant WS as Withdrawal service
    participant TR as TravelRuleService
    participant T as TRUST (directory)
    participant B as Endpoint thành viên đích
    participant SG as Wallet / Signer
    KH->>UI: Chọn sàn nhận (ví dụ Coinbase), nhập ví, tên người nhận
    UI->>WS: Tạo lệnh rút
    WS->>TR: Yêu cầu Travel Rule
    TR->>TR: Ghi PENDING_SEND, requestId
    TR->>T: Tra địa chỉ đích thuộc thành viên nào
    alt Không phải thành viên TRUST
        T-->>TR: Không tìm thấy
        TR->>TR: Router chuyển sang TRUSThub hoặc cổng chính
    else Là thành viên
        T-->>TR: Thành viên và endpoint
        TR->>B: Yêu cầu chứng minh sở hữu địa chỉ (challenge)
        B-->>TR: Chữ ký chứng minh
        TR->>TR: Kiểm tra chữ ký bằng khoá công khai của thành viên
        alt Chứng minh không hợp lệ
            TR-->>WS: REJECTED, không gửi PII
        else Hợp lệ
            TR->>B: Gửi PII đã mã hoá, trực tiếp P2P, không lưu tập trung
            B->>B: Giải mã, đối chiếu KYC
            B-->>TR: Chấp nhận hoặc từ chối
            alt Chấp nhận
                TR-->>WS: APPROVED
                WS->>SG: Ký và broadcast
                SG-->>WS: txHash
                WS->>TR: Gắn txHash
                TR->>B: Báo txHash theo spec TRUST
            else Từ chối
                TR-->>WS: REJECTED
            end
        end
    end
```

| Hạng mục | Nội dung |
| --- | --- |
| Điều kiện | Là thành viên TRUST sau thẩm định AML, bảo mật, quyền riêng tư; VASP nhỏ có thể xin gói miễn phí |
| Điểm khác biệt | Bắt buộc chứng minh sở hữu địa chỉ bằng mật mã trước khi gửi PII; không có nơi lưu dữ liệu trung gian |
| Sàn đích ngoài mạng | TRUSThub (ra mắt 05/2026), hoặc router chuyển sang cổng chính |
| Đường tắt | 21 Analytics có kết nối TRUST sẵn; sàn vẫn phải tự xin thành viên |
| Rủi ro | Theo Notabene, nhiều thành viên chưa chạy TRUST thật; đo tỷ lệ phản hồi theo từng sàn và hạ ưu tiên nếu thấp |

## Trường hợp đặc biệt

Ba tình huống dưới đây xảy ra với mọi kênh và nên xử lý một lần trong `TravelRuleService`. Nguyên tắc chung: khi không chắc chắn thì không ký, đưa vào hàng chờ compliance.

### Rút về ví cá nhân hoặc không xác định được sàn

Không có sàn đích để trao đổi dữ liệu, nên sàn phải tự lưu thông tin người nhận và, tùy khu vực pháp lý, yêu cầu khách chứng minh sở hữu ví. EU yêu cầu xác minh với giao dịch trên 1.000 EUR tới ví tự quản.

```mermaid
sequenceDiagram
    autonumber
    actor KH as Khách
    participant UI as App / Web
    participant WS as Withdrawal service
    participant TR as TravelRuleService
    participant P as Kênh Travel Rule
    participant CP as Compliance
    participant SG as Wallet / Signer
    KH->>UI: Chọn "Ví cá nhân" hoặc không tìm thấy sàn nhận
    UI->>WS: Tạo lệnh rút
    WS->>TR: Yêu cầu Travel Rule
    TR->>P: Tạo bản ghi, đánh dấu ví không lưu ký
    P-->>TR: Không xác định được VASP (unhosted)
    alt Cần chứng minh sở hữu theo quy định khu vực
        TR-->>UI: Yêu cầu chứng minh ví
        alt Ký thông điệp
            UI->>KH: Hiện thông điệp cần ký
            KH->>UI: Chữ ký từ ví
            UI->>TR: Gửi chữ ký
            TR->>TR: Kiểm tra chữ ký khớp địa chỉ
        else Micro-transfer
            KH->>KH: Gửi một khoản nhỏ từ ví về địa chỉ sàn chỉ định
            TR->>TR: Phát hiện khoản nhỏ đúng số tiền, đúng ví
        end
        TR->>P: Lưu bằng chứng (beneficiaryProof hoặc tương đương)
    end
    alt Bằng chứng hợp lệ và không có cờ rủi ro
        TR-->>WS: APPROVED
        WS->>SG: Ký và broadcast
    else Không chứng minh được hoặc có cờ rủi ro
        TR->>CP: ON_HOLD, chờ duyệt tay
        CP-->>TR: Cho đi hoặc từ chối
    end
```

Ở Notabene, bằng chứng đi qua `beneficiaryProof` (chữ ký mật mã, ảnh chụp, tự khai, hoặc micro-transfer). Ở Sumsub, luồng Unhosted wallet verification tự kích hoạt khi trạng thái là `counterpartyVaspNotFound`. Ở GTR, dùng Wallet Verify API.

### Kênh ưu tiên không tới được sàn đích

Router thử kênh kế tiếp thay vì từ chối ngay. Mỗi lần thử được ghi lại để làm bằng chứng đã cố liên lạc với sàn đích.

```mermaid
sequenceDiagram
    autonumber
    participant WS as Withdrawal service
    participant TR as TravelRuleService
    participant R as ProviderRouter
    participant K1 as Kênh ưu tiên (GTR hoặc TRUST)
    participant K2 as Cổng chính (Notabene hoặc Sumsub)
    participant CP as Compliance
    WS->>TR: Yêu cầu Travel Rule
    TR->>R: Chọn kênh cho sàn đích
    R-->>TR: Thứ tự kênh K1 rồi K2
    TR->>K1: Gửi Travel Rule (requestId)
    alt K1 thành công
        K1-->>TR: APPROVED hoặc REJECTED
    else K1 không tới được sàn đích (không là thành viên, not reachable)
        K1-->>TR: COUNTERPARTY_UNREACHABLE
        TR->>TR: Ghi lại lần thử K1, giữ cùng lệnh rút
        TR->>K2: Gửi Travel Rule (requestId mới cho kênh mới)
        alt K2 tới được
            K2-->>TR: Kết quả
        else K2 cũng không tới được
            K2-->>TR: Not reachable, đã gửi email cho sàn đích
            TR->>CP: ON_HOLD, kèm bằng chứng đã cố liên lạc
        end
    end
    TR-->>WS: Trạng thái cuối
```

`REJECTED` (sàn đích đã trả lời "không") **không** được chuyển sang kênh khác để thử lại. Chỉ chuyển kênh khi kênh trước không tới được sàn đích.

### Timeout, lỗi mạng và webhook bị mất

```mermaid
sequenceDiagram
    autonumber
    participant TR as TravelRuleService
    participant DB as Outbox / DB
    participant OW as Outbox worker
    participant P as Kênh Travel Rule
    participant WH as Webhook receiver
    participant RJ as ReconciliationJob
    participant CP as Compliance
    TR->>DB: PENDING_SEND (requestId)
    OW->>DB: Lấy bản ghi chưa gửi
    OW->>P: Gửi Travel Rule (requestId)
    alt Timeout hoặc 5xx
        P--xOW: Không có phản hồi
        OW->>DB: Tăng attempts, hẹn gửi lại
        loop Backoff, tối đa N lần
            OW->>P: Gửi lại với cùng requestId
        end
        OW->>DB: Hết lượt thì ON_HOLD
        DB-->>CP: Vào hàng chờ duyệt
    else Gửi được
        P-->>OW: Đã nhận
        OW->>DB: AWAITING_COUNTERPARTY
    end
    alt Webhook về bình thường
        P-)WH: Webhook kết quả
        WH->>DB: Ghi inbox (unique theo eventId), cập nhật trạng thái tiến lên
    else Webhook bị mất
        loop Mỗi 5 phút
            RJ->>DB: Tìm bản ghi mở quá 15 phút
            RJ->>P: fetchStatus(providerRef)
            P-->>RJ: Trạng thái hiện tại
            RJ->>DB: Cập nhật nếu tiến lên
        end
    end
    opt Quá thời gian chờ của chính sách
        RJ->>DB: EXPIRED
        DB-->>CP: Compliance quyết định cho đi, giữ hay huỷ
    end
```

Các con số 5 phút, 15 phút và N lần là gợi ý ban đầu; điều chỉnh theo SLA của sàn. Với GTR, `one_step` là đồng bộ nên không có webhook kết quả; trường hợp timeout thì gửi lại với cùng `requestId` hoặc tra Travel Rule History trước khi tạo yêu cầu mới.

## Bổ sung: luồng rút từ sàn khác về sàn của bạn

Khi khách rút từ sàn khác về, sàn của bạn là **sàn nhận** (beneficiary VASP). Việc của sàn là: xác nhận ví thuộc mình, đối chiếu tên người nhận với KYC, rồi chỉ ghi có khi khoản tiền khớp với một Travel Rule đã chấp nhận. Có hai trường hợp: sàn gửi gửi dữ liệu trước, hoặc tiền về trước khi có dữ liệu.

```mermaid
sequenceDiagram
    autonumber
    participant S as Sàn gửi
    participant P as Kênh Travel Rule
    participant TR as TravelRuleService
    participant DS as Deposit service
    participant BC as Blockchain
    participant CP as Compliance
    alt Sàn gửi gửi Travel Rule trước khi lên chain
        S->>P: Travel Rule tới ví nạp của sàn bạn
        P->>TR: Ví (kèm memo/tag) có phải của bạn?
        TR-->>P: Có hoặc không
        P->>TR: PII người gửi và người nhận
        TR->>TR: Đối chiếu tên người nhận với KYC, sàng lọc người gửi
        TR-->>P: Chấp nhận hoặc từ chối
        S->>BC: Broadcast
        P->>TR: txHash ứng với Travel Rule
        BC->>DS: Tiền về
        DS->>TR: Khớp txHash
        TR-->>DS: Đã chấp nhận, ghi có
    else Tiền về trước, chưa có Travel Rule
        BC->>DS: Tiền về
        DS->>TR: Không khớp Travel Rule nào
        TR-->>DS: Giữ tiền
        TR->>P: Hỏi sàn gửi dữ liệu người gửi (kèm txHash)
        P->>S: Yêu cầu dữ liệu
        alt Sàn gửi trả lời và dữ liệu đạt
            S-->>P: Dữ liệu người gửi
            P-->>TR: Kết quả
            TR-->>DS: Ghi có
        else Không trả lời hoặc dữ liệu lệch
            TR->>CP: Duyệt tay: ghi có, hoàn trả hay báo cáo
        end
    end
```

Mỗi kênh hiện thực các bước trên theo cách riêng:

| Kênh | Xác nhận ví và nhận PII | Khi tiền về | Tiền về trước, chưa có dữ liệu |
| --- | --- | --- | --- |
| Notabene | Address webhook (hoặc `txConfirm`), rồi `txAccept` / `txDecline` hoặc rules engine | Gọi `txNotify` cho **mọi** khoản nạp, backoff tới khoảng 1 giờ | `txNotify` trả `INCOMPLETE`: hỏi khách thông tin người gửi, `txUpdate` |
| Sumsub | Giao dịch mirrored + webhook `applicantKytTxnCreated`; xác nhận sở hữu, bổ sung người nhận | Khớp txHash với giao dịch đã duyệt | Tạo giao dịch `direction: in` có `paymentTxnId`; chờ `completed` hoặc bị từ chối |
| GTR | Callback 6 (địa chỉ), callback 4 (PII) — trả lời **đồng bộ** | Callback 7 cho ánh xạ txId với requestId | Gọi `one_step` với `verifyDirection = 1` và `txId` |
| TRUST | Endpoint của sàn ký chứng minh ví, rồi nhận PII P2P | Khớp theo thông báo txHash của sàn gửi | Theo spec TRUST cấp cho thành viên |

Hai điểm dễ sai ở chiều nhận:

- **Xác định khách bằng địa chỉ và memo/tag của giao dịch**, không dùng địa chỉ nằm trong PII. GTR nói rõ điều này cho callback 4.
- **Endpoint nhận phải luôn sẵn sàng và nhanh.** GTR chờ phản hồi đồng bộ; Sumsub chỉ đợi 10 giây; endpoint TRUST ngừng là mọi khoản nạp từ thành viên TRUST bị kẹt. Tra ví và KYC từ cache, giám sát ngang với API nạp tiền.

## Nguồn

Notabene: [Generate accessToken](https://devx.notabene.id/v1.0/docs/auth0) · [Create transfer](https://devx.notabene.id/reference/txcreate-1) · [Travel Rule statuses](https://devx.notabene.id/docs/tr-status_vnext) · [System interactions](https://devx.notabene.id/docs/how-does-our-apis-interact-with-your-system) · [txNotify](https://devx.notabene.id/v1.0/docs/calling-txnotify-for-every-deposit) · [Notification webhook](https://devx.notabene.id/v1.0/docs/updating)

Sumsub: [Quickstart](https://docs.sumsub.com/docs/travel-rule-quickstart-guide) · [Authentication](https://docs.sumsub.com/reference/authentication) · [Start exchange before settlement](https://docs.sumsub.com/docs/start-exchange-before-settlement) · [After on-chain incoming transfer](https://docs.sumsub.com/docs/after-on-chain-incoming-transfer) · [Transaction scenarios](https://docs.sumsub.com/docs/transaction-scenarios) · [Webhook manager](https://docs.sumsub.com/docs/webhook-manager) · [GTR protocol](https://docs.sumsub.com/docs/gtr-protocol)

GTR: [Before Integration](https://www.globaltravelrule.com/documentation/before-integration) · [Authentication](https://www.globaltravelrule.com/documentation/authentication) · [Submit One Step Travel Rule](https://www.globaltravelrule.com/documentation/api-references/gtr-2-0-sync-api/post-api-verify-v-2-one-step) · [Address Existence Verify Callback](https://www.globaltravelrule.com/documentation/callback-api-references/callback-api/post-address-exists-verify-6) · [PII Verification Callback](https://www.globaltravelrule.com/documentation/callback-api-references/callback-api/post-pii-verify-4) · [TXID Notify Callback](https://www.globaltravelrule.com/documentation/standard2-api/callback-api-5-update-tx-id) · [Subscription](https://www.globaltravelrule.com/documentation/subscription)

TRUST: [Coinbase – TRUST](https://www.coinbase.com/travelrule) · [Expanding TRUST (05/2026)](https://www.coinbase.com/blog/expanding-trust-a-privacy-first-network-for-global-crypto-compliance) · [Notabene – phân tích TRUST](https://notabene.id/travel-rule-messaging-protocols/ustrwg) · [21 Analytics – TRUST](https://www.21analytics.co/coinbase-trust/)

Tài liệu liên quan: [Tích hợp Travel Rule vào sàn CEX (Java)](https://claude.ai/artifact/3uP1UaZVoFMsm8pgrkGqmi), có code Java mẫu và danh mục sự cố đầy đủ.
