# Exposé — Mission Control cho Hyprland

Plugin overlay cho [Omarchy 4](https://omarchy.org/), trải mọi cửa sổ của
workspace hiện tại lên một màn hình. Vuốt **bốn ngón lên**, tất cả cửa sổ nhấc
khỏi desktop và xếp thành lưới; **bốn ngón xuống** là trả về chỗ cũ. Overview
bám theo ngón tay suốt quá trình — không phải một animation chạy sau khi vuốt
xong.

*[English](README.md)*

## Không cửa sổ nào bị di chuyển

Cửa sổ giữ nguyên vị trí và kích thước thật trong suốt cử chỉ. Thứ bay vào lưới
là ảnh screencopy trực tiếp của từng cửa sổ, vẽ trên một lớp phía trên desktop,
đè lên nền mờ.

Đây là chủ ý. Layout của Omarchy là `scrolling`, nên một cách làm "xếp thật vào
lưới rồi khôi phục" sẽ phá nát trạng thái cột, mà không có cách nào bảo Hyprland
đặt lại y như cũ. Vì thumbnail là ảnh trực tiếp, video vẫn chạy và terminal vẫn
cuộn khi overview đang mở.

## Yêu cầu

- **Omarchy 4** trở lên — bản đưa desktop sang `omarchy-shell` (Quickshell).
  Omarchy 3 chưa có plugin host.
- Tài khoản của bạn thuộc **nhóm `input`**, để bộ đọc cử chỉ đọc được
  `/dev/input/event*`. Kiểm tra bằng `groups`; nếu thiếu `input`:

  ```bash
  sudo usermod -aG input $USER   # đăng xuất rồi đăng nhập lại
  ```
- Có `libinput` và `stdbuf` (coreutils) trong `PATH`. Bản Omarchy nguyên gốc đã
  có sẵn cả hai.

## Cài đặt

```bash
omarchy plugin add https://github.com/hoojiNT/omarchy-expose.git
omarchy plugin enable hooji.expose
```

Repo tên `omarchy-expose`, nhưng nó cài vào
`~/.config/omarchy/plugins/hooji.expose/` — Omarchy đặt tên thư mục theo `id`
trong manifest, không theo tên repo. Đây là chuyện bình thường, không phải lỗi.

> **Plugin chạy không sandbox, ngay trong tiến trình `omarchy-shell`.** Điều này
> đúng với mọi plugin Omarchy, kể cả plugin này. `omarchy plugin add` cài ở
> trạng thái tắt để bạn đọc code trước, và `omarchy plugin update` cho xem diff
> trước khi áp dụng. Chỉ cài những repo mà bạn sẵn sàng chạy code của nó.

Cập nhật và gỡ:

```bash
omarchy plugin update hooji.expose
omarchy plugin remove hooji.expose
```

## Cách dùng

| Thao tác | Kết quả |
|---|---|
| Bốn ngón lên | Mở overview, bám theo ngón tay |
| Bốn ngón xuống | Đóng lại |
| Bốn ngón trái/phải, khi overview đóng | Workspace trước/sau |
| Bốn ngón trái/phải, khi overview mở | Di chuyển lựa chọn trong lưới |
| Bấm vào một cửa sổ | Focus cửa sổ đó và đóng overview |
| Bấm vào nền | Đóng |
| `←` `→` / `Tab` | Đổi lựa chọn |
| `Enter` | Focus cửa sổ đang chọn |
| `Esc` | Đóng |

Cách nhả tay quan trọng ngang quãng đường vuốt: một cú flick nhanh vẫn mở hoặc
đóng dù bạn chưa vuốt xa, còn một cú kéo chậm dừng giữa chừng sẽ bám về đầu gần
hơn. Buông tay khi chưa dứt khoát thì nó bật ngược về chỗ cũ.

Cũng có thể điều khiển không cần touchpad — đây là thứ nên bind nếu bạn muốn
phím tắt. Thêm vào `~/.config/hypr/bindings.lua`:

```lua
o.bind("SUPER + TAB", "Window overview", "omarchy-shell shell toggle hooji.expose '{}'")
```

## Vì sao plugin ôm cả bốn hướng

Swipe chuyển workspace mặc định của Hyprland không bật/tắt được lúc đang chạy,
nên một plugin chỉ nhận hướng "lên" sẽ giành giật hướng ngang với compositor mỗi
khi overview đang mở. Plugin này ôm cả bốn hướng của cử chỉ bốn ngón và tự
dispatch lệnh chuyển workspace. **Cử chỉ ba ngón không bị đụng tới** và vẫn làm
đúng việc bạn đã gán cho nó.

## Tinh chỉnh

Chưa có giao diện cài đặt. Các tham số là property đặt ngay đầu file, và lưu file
là plugin tự nạp lại:

| Property | File | Mặc định | Tác dụng |
|---|---|---|---|
| `fingers` | `SwipeSource.qml` | `4` | Lắng nghe cử chỉ mấy ngón |
| `threshold` | `SwipeSource.qml` | `220` | Quãng đường (đơn vị libinput) tính là một cử chỉ trọn vẹn |
| `axisLockDistance` | `SwipeSource.qml` | `12` | Quãng đường trước khi khoá trục, để vuốt hơi chéo vẫn tính là dọc |
| `naturalWorkspaceSwipe` | `Expose.qml` | `true` | Vuốt sang phải thì desktop đi sang phải; đảo lại nếu thấy ngược |

## Nó hoạt động thế nào

| File | Vai trò |
|---|---|
| `SwipeSource.qml` | Cử chỉ bốn ngón, đọc thẳng từ libinput |
| `Expose.qml` | Overlay: chụp trạng thái, xếp lưới, thumbnail screencopy, giao ước với shell |
| `manifest.json` | Thông tin để shell nạp plugin |

API cử chỉ của Hyprland chỉ bắn **một lần, lúc kết thúc** cú vuốt — không có
event nào mang tiến độ vuốt. Một overview bám ngón tay cần delta ngay lúc nó xảy
ra, nên plugin mở touchpad thêm một lần nữa song song: hỏi
`libinput list-devices` xem node `/dev/input/event*` nào là touchpad, rồi đọc
`libinput debug-events` trên node đó. Ở chế độ debug-events, libinput không
`EVIOCGRAB`, nên compositor vẫn nhận nguyên vẹn các event đó — đây là bộ lắng
nghe, không phải bộ chặn, và nó không lấy đi thứ gì của Hyprland. Nếu bộ đọc
chết, hai giây sau nó tự bật lại.

Delta được dùng là loại *chưa qua gia tốc*. Pointer acceleration được chỉnh cho
con trỏ chuột, đem dùng ở đây sẽ làm overview giật cục khi vuốt nhanh.

Lưới không chia `sqrt(count)` cột. Đó là lựa chọn hiển nhiên và sai trên màn
hình rộng: ba cửa sổ sẽ rơi vào lưới 2×2 thủng một ô, với kích thước chỉ bằng
nửa so với lưới 3×1. Thay vào đó, mọi số cột đều được thử, và số cột cho cả bộ
cửa sổ rộng rãi nhất sẽ thắng.

## Giới hạn đã biết

- Chỉ workspace hiện tại, trên màn hình đang focus. Đây là overview của một
  workspace, không phải của tất cả.
- Workspace trống thì không mở, thay vì hiện ra một nền mờ trơ trọi.
- Chỉ dùng touchpad. Chưa có tương đương cho chuột hay trackpoint — hãy bind
  lệnh IPC.
- `0.1.0`: còn sớm. Lưới vẫn là lưới đơn giản, chưa có kéo-để-đóng hay kéo cửa
  sổ sang workspace khác.

## Giấy phép

[MIT](LICENSE) © 2026 Nguyen The Hoi
