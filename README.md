# PS5Translator
## Bản 1.28 – Chỉ Data Việt hoá + AI iPhone, khớp data theo nghĩa, mỗi game 1 data riêng
- **Bỏ hẳn Google Dịch.** Thứ tự dịch: Data Việt hoá → Apple Intelligence trên iPhone. Không gửi chữ lên Internet, không còn cảnh câu dịch đổi qua đổi lại. iPhone không có Apple Intelligence thì chỉ dịch được câu có trong data.
- **Vẫn dịch theo từng màn phụ đề** (không đợi gom cả câu). Câu dịch hiện theo câu gốc, lấy từ data; không có trong data thì AI dịch.
- **Khớp data theo NGHĨA** (data dịch ngược từ tiếng Việt / tiếng khác nên chữ Anh khác bản gốc của game). Sau các bước khớp chữ cũ, app thêm bước khớp theo nghĩa:
  - **Từ khoá theo gốc từ:** blessed / blessing → bless; bỏ từ phổ biến; từ càng hiếm càng nặng ký.
  - **Nghĩa cả câu:** bộ so nghĩa câu tiếng Anh có sẵn trên iPhone (Apple NaturalLanguage, chạy trên máy).
  - **Thứ tự kịch bản:** cộng điểm cho các câu ngay sau câu vừa khớp.
  - **Câu ngắn** (≤ 2 từ khoá) phải giống gần như tuyệt đối để tránh nhầm "What have you done?" với "Well done!".
  - **Chưa đủ chắc:** đưa tối đa 3 câu Việt hoá có thể cùng nghĩa cho AI iPhone xét. Cùng nghĩa thì AI trả về **nguyên văn** câu Việt hoá (hiện như câu data); không thì AI tự dịch theo văn phong data.
- **Mỗi game 1 data riêng:**
  - Bỏ danh sách tên nhân vật Until Dawn gõ sẵn trong app. Tên riêng (cho OCR, nhận người nói, giữ tên khi dịch) chỉ lấy từ bảng glossary trong data của game đang chọn.
  - Bản dịch AI lưu riêng theo từng game.
  - Đổi sang game chưa có data thì xoá data của game trước (trước đây vẫn tra data game cũ).
  - Quy tắc dịch dùng chung cho mọi game, không theo riêng game nào.
- **Bỏ giới hạn chữ cao trên 50px.** Lưu ý: chữ to như tiêu đề chương ("MEMENTO MORI") sẽ lại được dịch, trừ dòng chỉ có tên nhân vật.
- **Theo dõi dòng phụ đề:** câu ngắn (≤ 3 từ) phải giống từ 85% trở lên mới coi là cùng một dòng qua các lần quét (trước đây 60%), tránh "Speak!" bị coi là "Speak her name!".

## Bản 1.27 – Sửa dịch theo video test Horizon Zero Dawn
- **Chữ "Sam" xuất hiện sai** ("All-Mother, this child..." → "Sam, cái bé này..."): lỗi từ lần sửa cho Until Dawn.
  - Lời dặn Apple Intelligence có câu ví dụ nhắc "Sam", AI hiểu thành phải chèn "Sam". Đã bỏ ví dụ đó.
  - Danh sách tên nhân vật Until Dawn trước đây áp cho mọi game; giờ chỉ dùng khi chơi Until Dawn.
  - AI chỉ được báo các tên có thật trong câu (trước đây báo cả 40 tên của game).
  - Bản dịch AI chứa tên người không có trong câu gốc thì bị bỏ, dùng Google.
- **Hiện bản dịch của câu khác** (giây 37: "Bạn đã làm gì?" trên câu "I've blessed..."): bản dịch về trễ trước đây được giao cho khung đã chuyển sang câu mới. Giờ chỉ giao cho khung đang hiện đúng câu đã gửi dịch.
- **Chữ dịch tắt trước chữ gốc** (giây 2–5): OCR đọc câu hơi khác đi thì app xoá bản dịch rồi dịch lại.
  - OCR đọc lệch vài chữ (giống từ 80%): giữ nguyên bản dịch.
  - Chữ đổi thật: dịch lại nhưng vẫn hiện bản cũ tới khi bản mới về.
- **Khung lời thoại hiện / tắt theo chữ gốc:**
  - Câu mới xuất hiện thì khung câu cũ tắt ngay.
  - Lời thoại chỉ giữ thêm 0,35 giây sau khi chữ gốc tắt (trước đây bản AI giữ 1,6–4,5 giây nên đè lên câu sau).
  - Bản dịch về sau khi chữ gốc đã tắt thì không hiện.
- **Nhanh hơn:** lời thoại gửi Google sau 0,4 giây để có chữ ngay; Apple Intelligence về sau sẽ thay bằng bản tốt hơn.
- **Dịch sát văn phong Việt hoá:**
  - Mỗi câu gửi AI kèm tối đa 4 câu Việt hoá chính thức giống nhất trong data của game, để AI theo xưng hô, văn phong và thuật ngữ. Ví dụ "All-Mother" → "Mẹ Chúng Sinh", "outcast" → "kẻ ruồng bỏ", Rost xưng "ta" – gọi "con".
  - Bỏ quy tắc xưng hô riêng của Until Dawn (tớ/cậu); không dùng "bạn" giữa các nhân vật.
  - Đổi file lưu bản dịch (`ai_translation_cache_v127.json`) để bỏ các bản dịch cũ sai.
- **Người nói:**
  - OCR đọc sai 1 chữ của tên ("leersa:" → "Teersa:") vẫn nhận đúng người nói.
  - AI lặp tên người nói ("Rost: Rost Tôi...") thì bỏ phần lặp.

## Bản 1.26 – Sửa lỗi "Thiếu file tv_app_icon.png", sao lưu / khôi phục data game
- **Cài app TV từ iPhone:** bản 1.25 đổi icon thành `.bin` nhưng Xcode không chép file `.bin` vào app → lỗi
  "Thiếu file tv_app_icon.png". Bản 1.26 nhúng icon PNG thẳng vào mã Swift (`11B_TVAppIcon.swift`),
  không phụ thuộc bước build nào nữa, TV luôn nhận PNG chuẩn → có icon.
- **Data Việt hoá mất sau khi cập nhật app:** data nằm trong thư mục của app; nếu cách cài bản mới làm iOS xoá app cũ
  (ký lại bằng chứng chỉ/Apple ID khác, đổi bundle ID, phải xoá app trước khi cài) thì data bị xoá theo.
  Thêm mục **Thư viện game → Sao lưu data**: chọn 1 thư mục trong app Tệp, app tự sao lưu mỗi khi data thay đổi;
  sau khi cài bản mới bấm **Khôi phục data** và chọn lại thư mục `PS5Translator_SaoLuu`.

## Bản 1.25 – Sửa app TV cài từ iPhone không có icon
- Nguyên nhân: khi build app iOS, Xcode tự chuyển mọi file .png lẻ sang định dạng PNG riêng của Apple (CgBI).
  Icon app TV đi qua bước này nên TV Samsung không đọc được → app TV không có icon.
- Sửa: workflow đổi `tv_app_icon.png` thành `tv_app_icon.bin` trong app (Xcode không đụng tới), tắt `COMPRESS_PNG_FILES`,
  và bộ cài kiểm tra icon là PNG chuẩn trước khi gửi sang TV. App TV lên bản 1.0.20.

## Bản 1.24 – Không bao giờ bỏ tên riêng ("Sam") trong câu thoại
Bản 1.20 mới sửa nhãn người nói "(Sam)" bị tách rời. Bản này sửa nốt các chỗ còn làm rơi tên:
- **Bản dịch cũ lưu trên máy:** bản dịch AI / Google đã thiếu "Sam" được lưu ra file và dùng lại mỗi lần gặp câu đó, nên sửa ở bản 1.20 không có tác dụng với câu đã dịch rồi.
  - Đổi sang file lưu mới (`ai_translation_cache_v124.json`), bỏ hết bản dịch cũ.
  - Bản đã lưu nào thiếu tên riêng của câu gốc thì bị bỏ và dịch lại.
- **Google làm mất mã giữ chỗ của tên** (`ZQX0Q`): giờ nhận cả khi Google chèn khoảng trắng / đổi hoa thường. Nếu mất hẳn thì chèn lại tên: tên ở nửa đầu câu gốc thì đặt đầu câu ("Sam, đợi đã!"), ở nửa sau thì đặt cuối câu ("Cậu có đi không, Sam?").
- **Apple Intelligence** (chế độ chỉ Apple) làm rơi tên: chèn lại tên theo cùng cách trên. Ở chế độ "Tất cả", câu thiếu tên vẫn chuyển sang Google.
- **Câu Việt hoá trong data** thiếu tên nhân vật có trong câu gốc (1/894 câu, ví dụ "Wait, those are Sam's..." → "Khoan, đó là--"): chèn lại tên.
- **Lời thoại chỉ gọi tên** "(Chris) Sam!" trước đây bị bỏ cả câu vì "chỉ có tên riêng". Giờ vẫn hiện, giữ nguyên "(Chris) Sam!".
- **Nhãn "(Sam)" OCR chấm điểm thấp** (dưới 0,3) trước đây bị bỏ. Giờ luôn được gắn vào lời thoại.

## Bản 1.23 – Nhớ ghép đôi PS5 vĩnh viễn, ô IP TV có dấu chấm, không mất kết nối khi khoá màn hình
- **Ghép đôi PS5 lưu vĩnh viễn:**
  - Khoá ghép đôi (RegistKey + RP-Key) PS5 cấp một lần và dùng mãi. Tắt / bật PS5, PS5 vào chế độ nghỉ, đổi Wi-Fi đều KHÔNG cần nhập lại 8 số. Chỉ cần nhập lại khi xoá iPhone khỏi "Thiết bị đã liên kết" trên PS5.
  - Bản cũ chỉ lưu trong UserDefaults, nên xoá app trước khi cài bản mới là mất. Giờ app lưu thêm vào **Keychain** của iPhone (vẫn còn sau khi xoá rồi cài lại app) và tự khôi phục khi mở app.
  - Nút **Sao lưu / Khôi phục** ở mục "Tài khoản đã liên kết": chép mã `PS5T1:...` vào Ghi chú, dán lại khi cần. Dùng khi công cụ cài app ký bằng chứng chỉ khác làm mất Keychain.
  - Mở app: gửi gói đánh thức PS5 (Rest Mode) rồi tự kết nối bằng tài khoản đã ghép đôi.
- **Ô IP TV Samsung:** bàn phím `.decimalPad` theo vùng Việt Nam chỉ có dấu phẩy. Đổi sang bàn phím số có dấu chấm, và tự đổi "192,168,2,3" thành "192.168.2.3".
- **Khoá màn hình:**
  - Công tắc mới "Không tự khoá màn hình" (mặc định BẬT): màn hình luôn sáng khi đang kết nối / đang kết nối lại PS5.
  - Lỡ khoá máy: phiên rớt khi máy khoá không còn bị hiểu nhầm là "PS5 đổi tài khoản" (trước đây phải bấm Kết nối lại). Mở khoá là app tự kết nối lại.
  - Phiên còn chạy nhưng mất hình sau khi mở khoá: sau 4 giây app tự khởi động lại phiên.
  - Âm thanh im lặng giữ app chạy nền tự bật lại khi iOS ngắt (khoá máy, cuộc gọi, Siri, Control Center).

## Bản 1.22 – Sửa thẻ "Đang chơi" ở tab Game
- Bỏ ảnh bìa nhỏ bị lệch xuống dưới khung. Ảnh bìa lớn hiện rõ (không làm mờ), cắt gọn trong khung bo tròn.
- Tên game, nhãn "Đang chơi" và thông tin data nằm bên dưới ảnh. Chạm vào ảnh để chọn ảnh bìa khác.

## Bản 1.21 – Ảnh bìa game, thư viện game có sẵn, màn Kết nối PS5 kiểu mới

- **Ảnh bìa (avatar) cho từng game** (`13_GameCovers.swift`): app tự tải ảnh bìa vuông từ trang PlayStation Store
  của game (mã concept lưu sẵn), lưu thành `cover.jpg` trong thư mục game, lần sau không cần mạng.
  Game tự thêm: app tìm trên PlayStation Store theo tên. Muốn đổi: menu "…" → "Chọn ảnh bìa từ Ảnh"
  hoặc "Tải lại ảnh bìa"; ở tab Game chạm vào ảnh bìa để chọn ảnh khác.
- **Thêm sẵn 21 game** có trong máy PS5 vào Thư viện Game (chỉ thêm 1 lần, game đã xoá không bị thêm lại;
  game trùng tên với game đã có thì bỏ qua).
- **Tab Game:** ảnh bìa ở thẻ "Đang chơi" (nền mờ lấy từ ảnh bìa). Bỏ nút Apple AI / Google / Chỉ data:
  app luôn dùng "Tất cả" (Data Việt hoá → Apple Intelligence → Google).
- **Màn Kết nối PS5** đổi sang giao diện đen mờ & trắng, bo tròn như phần còn lại của app.
- Công tắc bật dùng màu xám bạc để nút gạt trắng luôn nhìn thấy.
- Game chưa có data hiện "Chưa có câu Việt hoá · dịch bằng AI" thay vì "Data lỗi (0 câu)".

## Bản 1.20 – Sửa dịch thông minh theo video "video text"
- **Giữ tên người nói "(Sam)":** OCR hay tách "(Sam)" thành một mảnh riêng. Bản 1.16 coi mảnh này là "dòng chỉ có tên riêng" nên bỏ đi, làm câu dịch mất tên người nói.
  - Giờ nhãn "(Sam)", "[Ashley]", "Chris:" được gắn lại vào lời thoại cùng hàng.
  - Khung dịch phủ cả nhãn và hiện "(Sam) Này, lạ nhỉ. Cửa bị khoá rồi."
- **Tên riêng trong câu:** nếu Apple Intelligence làm rơi tên có trong câu gốc (ví dụ "Sam"), app dùng bản Google. Bản Google khoá tên bằng mã giữ chỗ nên tên không bị mất.
- **Bỏ bản dịch về trễ:** "CỐT TRUYỆN CỦA CHÚNG TA" ở giây 4–6 là bản dịch AI của chữ viết tay trên tấm bảng ("THE PAST IS BEYOND OUR CONTROL") ở cảnh trước. Bản dịch về sau khi đã chuyển cảnh nhưng vẫn được giữ trên màn hình. Cách sửa:
  - Bản dịch về khi chữ gốc đã biến mất thì không hiện. Riêng lời thoại ngắn được nới thêm 1,5 giây.
  - App nhận biết cắt cảnh (cả khung hình đổi hẳn). Khi đó các khung dịch không phải lời thoại của cảnh cũ tắt ngay.
  - Chữ ngoài phụ đề, không có trong data, OCR chưa chắc chắn: phải đọc được ở 2 lần quét và đứng yên mới hiện.
- **Lời thoại luôn chữ vàng:** "(Sam) Creepy." bị tách thành "Creepy." đứng một mình (1 từ, không có người nói), nên trước đây bị coi là menu, thành chữ trắng trong khung hẹp xuống 2 dòng. Giờ:
  - Chữ nằm đúng dòng phụ đề quen thuộc (cùng đáy dòng, cùng cỡ chữ, gần giữa) luôn là lời thoại.
  - Khung đã là lời thoại thì giữ là lời thoại, kể cả khi lần quét sau OCR đọc khác.
- Độ tin cậy OCR của dòng gộp lấy theo mảnh dài hơn, để nhãn "(Sam)" ngắn bị chấm điểm thấp không kéo cả câu thoại bị bỏ.

## Bản 1.19 – Giao diện mới (iOS 27: đen mờ & trắng, bo tròn) + logo MQ

- **Logo MQ** (chữ MQ ở giữa tay cầm): icon app iPhone (`icon.png`), icon app TV (`TVApp/tv_app_icon.png`),
  logo trên thanh đầu app (`app_logo.png`), file gốc vector `design/logo_mq.svg`.
- **3 tab dưới:** Trang chủ · Game (game đang chơi) · Thư viện Game. Bỏ tab Cài đặt (cài đặt TV / kết nối nằm ở nút bánh răng).
- **Bỏ "Vùng quét chữ"** (Toàn màn / Chỉ phụ đề / Nhiệm vụ) và khung căn ROI: app luôn dịch toàn màn hình.
- **Gộp "Kết nối PS5" và "Liên kết máy PS5"** thành 1 nút.
- **Log quét chữ cỡ lớn** thay dòng "Quét (0 vùng)": mỗi câu có nhãn DATA (khớp data Việt hoá), AI (dịch AI),
  RÁC (bị bỏ qua, ghi lý do), kèm bộ đếm. Xem / xuất toàn bộ ở "Lịch sử câu đã dịch".
- File mới: `12_ModernUI.swift` (theme, thanh tab, log, tab Game, cài đặt).

## Bản 1.18 – Cài app TV Samsung ngay từ iPhone, sửa kết nối và vị trí phụ đề trên TV

- **Cài app TV không cần máy tính** (`11_TVInstaller.swift`, mã nguồn app TV ở thư mục `TVApp/`):
  Thư viện game → TV Samsung → "Cài / cập nhật app lên TV Samsung".
  iPhone tự nói chuyện với TV qua SDB (cổng 26101), đăng nhập tài khoản Samsung, xin chứng chỉ cho đúng DUID của TV,
  ký gói .wgt, cài và mở app. IP Wi-Fi của iPhone được ghi sẵn vào app TV.
  TV cần: Developer Mode ON, Host PC IP = IP iPhone, tắt hẳn rồi bật lại TV.
  Chứng chỉ + khoá ký được lưu trong Keychain để lần sau cập nhật không bị lỗi "author mismatch".
- **Kết nối iPhone ↔ TV:** iPhone gửi "hello" + phụ đề cuối khi TV kết nối, "ping" mỗi 3 giây, tự khởi động lại máy chủ khi mạng đổi.
  App TV hết lỗi tự ngắt–nối lại mỗi 3 giây, nhập được IP bằng remote, tự quét mạng tìm iPhone khi sai IP.
- **Vị trí phụ đề trên TV khớp iPhone:** TV vẽ theo `boxes` (toạ độ 0..1, cỡ chữ, màu, căn giữa/neo đáy) bằng đúng công thức của iPhone.

## Bản 1.11 – Quét chữ thông minh

File mới: `7_SmartSubtitleEngine.swift`

- **Lọc chữ rác:**
  - OCR dùng chế độ chính xác (`.accurate`) và nhận cả tiếng Việt; chữ đã là tiếng Việt (ví dụ giao diện PS5) thì bỏ qua.
  - Bỏ ký tự lạ, từ trộn chữ với số hoặc hoa/thường lộn xộn, số liệu HUD, chữ đơn lẻ vô nghĩa, và từ game cơ bản (OK, BACK, HP...).
  - Dòng chữ chỉ được nhận nếu đa số từ trong đó là từ tiếng Anh thật (kiểm tra bằng UITextChecker).
- **Khung dịch ổn định:** mỗi khung có ID cố định. Vị trí chỉ đổi khi chữ gốc thật sự di chuyển. Chữ có độ tin cậy thấp phải xuất hiện ở 2–3 lần quét mới được hiện. Khung ẩn ngay khi chữ gốc biến mất.
- **Kiểu chữ khớp chữ gốc:** cỡ chữ tính theo chiều cao dòng gốc. Màu chữ và màu nền lấy từ chính khung hình (tách bằng ngưỡng Otsu). Thoại nhân vật luôn màu vàng.
- **Bố cục:** khung neo ở góc trái-trên của chữ gốc, kéo dài sang phải, tự xuống dòng, tự thu nhỏ chữ để không đè lên khung khác.
- **Nút bấm tay cầm:** câu được tách ra quanh L1/R2/✕/○/△/□ và quanh khoảng trống có icon nút, nên khung dịch không che nút.
- **Tên riêng:** tên có sẵn trong danh sách, cộng với bảng `glossary` trong data, được giữ nguyên. Khi dịch AI, tên riêng được thay bằng mã giữ chỗ trước khi gửi đi.
- **Người nói:** nhận ra `[Ashley]`, kể cả khi OCR đọc thành `IAshleyl`. Tên người nói được giữ nguyên, chỉ phần lời thoại được dịch.

### Data Việt hoá
Chạy `python tools/vietsub_db_tool.py check <file.sqlite>` để kiểm tra một file data.
Để tạo data chuẩn, dùng `build` (từ CSV, hoặc TXT dạng `Anh ||| Việt`) hoặc `build-parallel` (từ 2 file Anh và Việt có thứ tự dòng khớp nhau).

## Bản 1.12 – Tab Dịch YouTube, xoay ngang, Apple Intelligence, Thư viện game

- **Tab "Dịch YouTube"** (`8_YouTubeTranslator.swift`)
  - Mở m.youtube.com ngay trong app.
  - Chặn các tên miền quảng cáo, tự bỏ qua quảng cáo video và ẩn khung quảng cáo.
  - Dùng chung bộ máy quét chữ với màn hình PS5.
  - Khung hình được lấy từ thẻ `<video>` bằng canvas. Nếu bị chặn, app chuyển sang chụp ảnh trình duyệt. Thanh trạng thái cho biết đang dùng cách nào.
- **Xoay ngang toàn màn hình** cho cả YouTube và PS5.
  - Nút toàn màn hình của YouTube được chuyển thành chế độ xoay ngang của app, nên khung dịch vẫn hiện.
- **Apple Intelligence** (`10_AppleIntelligenceTranslator.swift`)
  - Dịch trên iPhone bằng Foundation Models (cần iOS 26, máy hỗ trợ Apple Intelligence, và đã bật Apple Intelligence).
  - Có ngữ cảnh: tên game, loại chữ, người nói, 3 câu thoại trước đó, tên riêng cần giữ nguyên.
  - Chọn bộ dịch trong Thư viện game: Apple → Google / chỉ Apple / chỉ Google / chỉ data.
- **Thư viện game** (`9_GameLibraryView.swift`)
  - Thẻ game đang chơi và lưới danh sách game.
  - "Thêm game mới": nhập tên và chọn file data trong cùng một màn hình.
  - Nhập được .sqlite / .db / .csv / .tsv / .txt (dạng Anh ||| Việt).
- **Workflow**: tự chọn Xcode mới nhất; weak-link FoundationModels để app vẫn chạy trên iOS < 26.

## Bản 1.13 – Ghép data theo đoạn câu, chống chớp tắt, nền đen

- **Ghép data:** game (ví dụ Until Dawn) chia một câu dài thành nhiều đoạn hiện lần lượt. App giờ tìm câu trong data chứa liền mạch đoạn đang hiện, và ưu tiên câu vừa khớp cùng các câu kế tiếp theo thứ tự kịch bản.
  - Đoạn tiếp theo của cùng một câu dùng lại đúng khung cũ, nên khung không chớp.
  - Khi data giữ đúng thứ tự kịch bản, khâu ghép đoạn chạy tốt nhất. Hãy tạo data từ `until_dawn_full_report.csv`, đừng dùng bản đã sắp xếp theo ABC.
- **Thời gian giữ chữ:** câu lấy từ data giữ thêm 0,35 giây sau khi chữ gốc biến mất. Câu dịch AI giữ 1,6–4,5 giây tuỳ độ dài. Câu mới hiện ở cùng chỗ sẽ thay ngay.
- **Cỡ chữ thoại cố định:** lấy trung vị nhiều lần đo, chỉ đổi khi khác trên 12%. Lời thoại căn giữa, đáy khung cố định. Cỡ chữ của menu được khoá theo từng khung.
- **Kiểu khung:** nền đen cho mọi khung dịch, chữ đậm.
- **Tên người nói và lựa chọn:**
  - "(Dr. Hill)   Interesting." không còn bị cắt đôi; các dòng cùng hàng được gộp lại.
  - Lựa chọn câu trả lời ngắn (1–4 từ hợp lệ) không còn bị coi là chữ rác.
  - Chữ có trong data luôn được chấp nhận.
- **Dòng "Chữ gốc"** ghi rõ nguồn dịch của từng câu: 📗Data / 🤖AI / ⏳AI (đang chờ) / ✗ (không dịch được).

## Bản 1.14 – Dịch từng câu, cố định cỡ chữ, sửa AI cho lựa chọn

- **Dịch từng câu:** mỗi dòng data (nhiều khi là cả một đoạn văn) được tách thành từng câu Anh và câu Việt, rồi ghép cặp theo độ dài (kiểu Gale-Church). Khi game hiện đoạn nào, app chỉ hiện đúng câu Việt của đoạn đó, ẩn và hiện cùng câu gốc.
  - Chạy thử trên 13 đoạn phụ đề lấy từ video: cả 13 đều ra đúng câu.
- **Cỡ chữ cố định:**
  - Cỡ chữ thoại chỉ đổi khi phụ đề game đổi cỡ trên 25%.
  - SwiftUI không còn tự thu nhỏ chữ (đã bỏ `minimumScaleFactor`). Nếu chữ dài hơn dự tính, khung tự giãn thêm dòng.
  - Khung thoại neo đáy và căn giữa; khung menu/lựa chọn neo góc trái-trên.
- **Lựa chọn câu trả lời:**
  - Bản dịch AI được giao đúng về khung đã gửi, kể cả khi OCR đọc chữ hơi khác ở lần quét sau. Đây chính là lỗi khiến "IT MAKES ME HAPPY" không được dịch.
  - Icon nút bị OCR đọc lệch (`[12]`, `(2)`, `(r2)`…) được nhận là nút bấm; khung dịch không che lên các icon này.
  - Chữ IN HOA được gửi AI dưới dạng câu thường, rồi bản dịch được in hoa lại.
  - Nếu Apple Intelligence chưa trả kết quả sau 1,2 giây, app gửi Google song song; bản nào về trước thì hiện.
- Data Until Dawn hiện có: các lựa chọn câu trả lời chỉ có tiếng Việt, thiếu tiếng Anh, nên luôn được dịch bằng AI.

## Bản 1.15 – Bộ dịch "Dùng chung tất cả"
- Chế độ mặc định mới: **Data Việt hoá → Apple Intelligence → Google Dịch**.
  - Câu có trong data thì lấy từ data.
  - Câu không có trong data thì dịch bằng Apple Intelligence trên iPhone.
  - Nếu Apple Intelligence không dịch được, quá 1,2 giây chưa trả kết quả, hoặc máy không có Apple Intelligence, thì dùng Google Dịch.
- Cả 4 chế độ đều ưu tiên data trước. Chế độ "Chỉ data Việt hoá" ghi rõ là lựa chọn và câu thiếu trong data sẽ KHÔNG được dịch.
- Lựa chọn bộ dịch cũ được đặt lại về "Dùng chung tất cả" khi cập nhật lên bản này.

## Bản 1.16 – Không dịch chữ trên vật phẩm, chữ to, tên riêng; đọc chữ nhỏ nhanh hơn
- **Chữ dính vào vật thể trong game** (lá thư, biển báo, chữ viết tay): bị bỏ qua khi
  1. dòng chữ nghiêng quá 3° hoặc méo phối cảnh (cạnh trái lệch quá 22% chiều cao chữ), hoặc
  2. chữ di chuyển theo máy quay ở phần lớn các lần quét.
  Chữ giao diện (bảng chữ bên phải, phụ đề, lựa chọn) thì thẳng và đứng yên, nên vẫn được dịch.
- **Chữ to** (cao trên 50px ở thang 720, ví dụ "SAM", "MEMENTO MORI"): không dịch, để không che màn hình game.
- **Dòng chỉ gồm tên riêng** ("SAM", "Dr. Hill"): không dịch. Tên có đuôi sở hữu ("HANNAH'S") vẫn được nhận là tên riêng và giữ nguyên ("BẠN THÂN NHẤT CỦA HANNAH").
- **Chữ IN HOA không có người nói** ("TEN HOURS UNTIL DAWN") không còn bị coi là lời thoại, nên khung dịch nằm đúng chỗ chữ gốc ngay từ lần đầu.
- **Đọc chữ nhỏ** (nhãn địa điểm khoảng 10px): ngưỡng `minimumTextHeight` của Vision hạ từ 0.018 xuống 0.011, nên những chữ này được đọc ngay thay vì phải chờ vài giây.

## Bản 1.17 – Không dịch chữ trên giấy / thư / biển báo
- **Mực tối trên nền sáng:** chữ trên giấy, thư, biển báo luôn tối hơn mặt giấy. Chữ giao diện game (phụ đề, bảng chữ bên phải, lựa chọn) thì sáng hơn nền.
  - App so sánh tương đối (mực tối hơn nền ít nhất 1,5 lần), nên vẫn đúng ở cảnh đêm, khi tờ giấy rất tối.
  - Vùng quanh khối chữ cũng phải là mặt giấy (phần mực tối chiếm thiểu số).
- **Cùng nội dung xuất hiện 2 lần** (tờ thư cùng bảng chữ giao diện): app chỉ dịch bản chữ sáng.
- Lời thoại có người nói và phụ đề luôn được dịch, để phụ đề trên nền tuyết trắng không bị bỏ nhầm.
- Công tắc trong Thư viện game: "Không dịch chữ trên giấy, thư, biển báo" (mặc định bật). Tắt đi nếu game có menu chữ đen trên nền trắng.
- Kết hợp với bộ lọc của bản 1.16 (chữ nghiêng/méo và chữ trôi theo máy quay).
