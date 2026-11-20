# OpenWrt for Arcadyan WE410443-TC (中華電信 Wi-Fi Mesh)

中華電信版 Arcadyan WE410443（白色、Wi-Fi 5 mesh extender）的 OpenWrt 移植。
OpenWrt 上游已支援 KPN / BT 版的 WE410443（32MB flash），但中華版是 **16MB flash + 雙韌體槽**，
分區、MAC 位置、開機格式都不同，無法直接使用官方映像。

> 這份移植是我和 Claude（Anthropic 的 AI）一起完成的：DTS、patch、說明文件由 Claude 撰寫，
> 在我手上的實機上逐項驗證過。

## 硬體

| | |
|---|---|
| SoC | MediaTek MT7621AT |
| RAM | 128 MB |
| Flash | 16 MB SPI NOR |
| Wi-Fi | 2× MT7615N（PCIe；phy0 = 2.4G、phy1 = 5G），2×2 |
| Ethernet | 1× Gigabit（`lan`） |
| 按鍵 | WPS = GPIO 3、Reset = GPIO 18 |
| LED | 藍 = GPIO 41、橘 = GPIO 42、紅 = GPIO 44（KPN 版 GPIO 42 是綠燈） |
| Bootloader | MTK SDK U-Boot 1.1.3（UART 57600，有 TFTP 選單） |

## Flash 佈局

| 位址 | 大小 | 原廠名稱 | OpenWrt |
|---|---|---|---|
| 0x000000 | 0x30000 | Bootloader | `u-boot`（唯讀） |
| 0x030000 | 0x10000 | Config | `config`（唯讀，bootloader 會寫 0x1000） |
| 0x040000 | 0x10000 | Factory | `factory`（唯讀；EEPROM @0x0 / @0x8000，MAC @0xfff0） |
| 0x050000 | 0x7b0000 | Kernel + RootFS | **`firmware`（OpenWrt 放這裡）** |
| 0x800000 | 0x10000 | crash_dump | 唯讀 |
| 0x810000 | 0x7b0000 | Kernel2 + RootFS2 | `firmware2`（唯讀，原廠韌體保留當備援） |
| 0xfc0000 | 4×0x10000 | seccfg / pricfg / arc_log / board_data | 唯讀 |

- MAC：`factory` 0xfff0 存 6 bytes binary；LAN = +0、2.4G = +1、5G = +2（跟原廠相同）。
- 映像使用 `uimage-lzma-loader`（原廠 U-Boot 吃標準 uImage，不需要 Arcadyan TRX 包裝）。

## 映像內容

為了塞進 7.69 MB 的槽並留下設定空間，預設映像是 **有線 AP** 用的精簡版：
拿掉 firewall4 / nftables、PPP、IPv6 DHCP、ubi-utils、ca-bundle。
保留 LuCI、dnsmasq（首次設定用）、wpad-basic-mbedtls。overlay（jffs2）約 768 KB。

要當路由器用的話，自行在 `.config` 加回套件，但要注意 `IMAGE_SIZE := 7872k` 的上限。

## 編譯

在 Linux（或 WSL）上：

```sh
./build.sh            # 預設 OpenWrt v25.12.6
./build.sh v25.12.6   # 指定版本
```

或手動：clone OpenWrt → `git am patches/*.patch` → 選 `arcadyan_we410443-tc` → `make`。
產物：`bin/targets/ramips/mt7621/openwrt-ramips-mt7621-arcadyan_we410443-tc-squashfs-sysupgrade.bin`

## 安裝（從原廠韌體）

> ⚠️ 刷機有變磚風險。建議先準備 CH341A + SOIC8 夾子或 USB-TTL，並先備份整顆 flash。
> 本流程只寫 Kernel 槽（mtd4），bootloader 與 factory 不會動到，最壞情況是軟磚。

1. 用 SSH 登入原廠系統（帳號 `cht`）。
2. **先備份整顆 flash**（原廠 `wget` 被鎖，可用 `nc` 傳到電腦）：
   ```sh
   md5sum /dev/mtd0
   nc <電腦IP> <port> < /dev/mtd0
   ```
3. 把 sysupgrade.bin 傳到路由器的 `/tmp`（例如電腦開 TCP server，路由器 `nc <電腦IP> <port> > /tmp/owrt.bin`），核對 md5。
4. 寫入並讀回驗證，**md5 一致才重開機**：
   ```sh
   cp "$(which mtd_debug)" /tmp/mtd_debug
   /tmp/mtd_debug erase /dev/mtd4 0 8060928
   /tmp/mtd_debug write /dev/mtd4 0 <檔案大小> /tmp/owrt.bin
   /tmp/mtd_debug read  /dev/mtd4 0 <檔案大小> /tmp/rb.bin && md5sum /tmp/rb.bin
   reboot
   ```
5. 電腦直連，開 `http://192.168.1.1`（root、無密碼）。

之後更新直接用 LuCI 或 `sysupgrade`。

### 設成有線 AP

```sh
uci set network.lan.proto='dhcp'
uci -q delete network.lan.ipaddr
uci -q delete network.lan.netmask
uci set dhcp.lan.ignore='1'
uci set wireless.radio0.country='TW'
uci set wireless.radio1.country='TW'
uci set wireless.radio1.channel='149'
uci set wireless.radio1.htmode='VHT80'
uci commit
reboot
```

## 刷回原廠韌體

OpenWrt 只寫了 Kernel 槽（`0x050000`，0x7b0000 bytes）。bootloader、`factory`、原廠設定分區
（`config` / `seccfg` / `pricfg` …）都沒動過，所以**把原廠的 Kernel 槽寫回去就能回到原廠**，原廠設定也還在。

> ⚠️ 這段流程尚未在實機上跑過。寫入前一定要核對檔案大小與 uImage 標頭。

### 1. 準備原廠 Kernel 映像（擇一）

**A. 從安裝前的整顆備份切出來（推薦，版本跟你原本的一樣）**

```sh
# mtd0_ALL.bin = 安裝前 dump 的整顆 16MB flash
dd if=mtd0_ALL.bin of=stock-kernel.bin bs=65536 skip=5 count=123   # 0x50000 起、0x7b0000 bytes
```

**B. 沒有備份：用機器上還留著的 Kernel2 槽**

OpenWrt 沒有動 Kernel2，那裡是一份較舊的原廠韌體（出廠版本），在 OpenWrt 上直接讀出來：

```sh
grep firmware2 /proc/mtd                         # 找到 firmware2 是哪個 mtdN
cat /dev/mtdN > /tmp/stock-kernel.bin            # N 換成上面看到的數字
```

### 2. 確認映像

```sh
ls -l stock-kernel.bin                 # 必須是 8060928 bytes
hexdump -C stock-kernel.bin | head -3  # 開頭必須是 27 05 19 56，名稱 "Linux Kernel Image"
```

### 3. 寫回 Kernel 槽

在 OpenWrt 上（方法 A 要先把檔案傳到 AP，例如 `scp -O stock-kernel.bin root@<AP IP>:/tmp/`）：

```sh
md5sum /tmp/stock-kernel.bin
mtd -r write /tmp/stock-kernel.bin firmware
```

`mtd -r` 寫完會自動重開機，大約 2 分鐘後回到原廠韌體（預設 IP 依原廠設定）。
開機後中華電信可能會透過 TR-069 自動更新到最新版原廠韌體。

### 救援

- **UART**：原廠 U-Boot（57600 baud）開機 1 秒內按鍵中斷，選「Load system code then write to Flash via TFTP」，用 TFTP 寫入 `stock-kernel.bin`。
- **CH341A**：用 SOIC8 夾子把安裝前的整顆備份寫回 flash（0x0 起，16 MB）。

## 已驗證

- [x] 開機、重開機、斷電冷開機，設定保留
- [x] 兩顆 MT7615、MAC 正確
- [x] jffs2 overlay
- [x] 按鍵（WPS / Reset）、三顆 LED
- [x] `sysupgrade -T`、LuCI 升級
- [x] Pixel @ 5G 149 / VHT80：tx bitrate 866.7（VHT-MCS 9 NSS 2），iperf3 下載約 450 Mbps（峰值 560）、上傳約 420 Mbps
- [x] 原廠 MTK 驅動的 `Replay Counter Different in pairwise msg 2 of 4-way handshake` 問題（Android 顯示「請檢查密碼」）在 OpenWrt（mt76 + hostapd）下沒有再出現

## 備註

- **160 MHz**：MT7615 支援，台灣法規（regdb `TW`）也允許 36–64 以 AUTO-BW 合併，但實測比 149 / 80 MHz 慢（23 dBm vs 30 dBm、36–48 干擾、52–64 需 DFS）。不建議。
- 原廠 Kernel2 槽保持不動；開機失敗時 bootloader 是否會自動切換到 Kernel2 **未驗證**。

## 參考

- OpenWrt 上游 WE410443（KPN/BT）支援：[ramips: mt7621: add support for Arcadyan WE410443](https://git.openwrt.org/?p=openwrt/openwrt.git;a=commit;h=b6a07dd0914e17d923f08c38fbfd4fa63fb2883b)
- 中華版分區配置參考：[pccr10001/padavan-4.4](https://github.com/pccr10001/padavan-4.4)（`WE410443-TC` board）

## License

Patches 與 DTS 依 OpenWrt 慣例為 `GPL-2.0-or-later OR MIT`。
