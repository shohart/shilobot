#!/usr/bin/env bash
set -euo pipefail

echo "==> Creating custom rootfs overlay"
rm -rf files

mkdir -p "$(dirname 'files/etc/config/dhcp')"
cat > 'files/etc/config/dhcp' <<'__A5_FILE_1__'
config dnsmasq
	option domainneeded '1'
	option boguspriv '1'
	option localise_queries '1'
	option rebind_protection '0'
	option local '/lan/'
	option domain 'lan'
	option expandhosts '1'
	option authoritative '1'
	option readethers '1'
	option leasefile '/tmp/dhcp.leases'
	option resolvfile '/tmp/resolv.conf.auto'
	option nonwildcard '0'

config dhcp 'setup'
	option interface 'setup'
	option start '20'
	option limit '80'
	option leasetime '1h'
	option force '1'
__A5_FILE_1__

mkdir -p "$(dirname 'files/etc/config/network')"
cat > 'files/etc/config/network' <<'__A5_FILE_2__'
config interface 'wired'
	option ifname 'eth0'
	option proto 'dhcp'
	option metric '10'
	option hostname 'a5-printserver'

config interface 'wwan'
	option proto 'dhcp'
	option metric '20'
	option hostname 'a5-printserver'

config interface 'setup'
	option proto 'static'
	option ipaddr '192.168.4.1'
	option netmask '255.255.255.0'
__A5_FILE_2__

mkdir -p "$(dirname 'files/etc/config/p910nd')"
cat > 'files/etc/config/p910nd' <<'__A5_FILE_3__'
config p910nd
	option device '/dev/usb/lp0'
	option port '0'
	option bidirectional '1'
	option enabled '1'
__A5_FILE_3__

mkdir -p "$(dirname 'files/etc/config/uhttpd')"
cat > 'files/etc/config/uhttpd' <<'__A5_FILE_4__'
config uhttpd 'main'
	list listen_http '0.0.0.0:80'
	option home '/www'
	option rfc1918_filter '0'
	option max_requests '2'
	option max_connections '8'
	option cgi_prefix '/cgi-bin'
	option script_timeout '30'
	option network_timeout '30'
	option http_keepalive '10'
	option tcp_keepalive '1'
	option index_page 'index.html'
__A5_FILE_4__

mkdir -p "$(dirname 'files/etc/hotplug.d/usb/50-a5-printer')"
cat > 'files/etc/hotplug.d/usb/50-a5-printer' <<'__A5_FILE_5__'
#!/bin/sh

case "$ACTION" in
	add)
		(
			sleep 2
			[ -c /dev/usb/lp0 ] && /etc/init.d/p910nd restart >/dev/null 2>&1
		) &
		;;
	remove)
		[ -c /dev/usb/lp0 ] || /etc/init.d/p910nd stop >/dev/null 2>&1
		;;
esac
__A5_FILE_5__
chmod 0755 'files/etc/hotplug.d/usb/50-a5-printer'

mkdir -p "$(dirname 'files/etc/init.d/a5print')"
cat > 'files/etc/init.d/a5print' <<'__A5_FILE_6__'
#!/bin/sh /etc/rc.common

START=95
STOP=10
USE_PROCD=1

start_service() {
	procd_open_instance
	procd_set_param command /usr/sbin/a5printd
	procd_set_param respawn 3600 5 5
	procd_close_instance
}
__A5_FILE_6__
chmod 0755 'files/etc/init.d/a5print'

mkdir -p "$(dirname 'files/etc/uci-defaults/90-a5-printserver')"
cat > 'files/etc/uci-defaults/90-a5-printserver' <<'__A5_FILE_7__'
#!/bin/sh

# Generate the radio stanza using OpenWrt's own detector; this avoids hardcoding
# phy/path details across A5-V11 clones.
if [ ! -s /etc/config/wireless ]; then
	wifi detect >/etc/config/wireless 2>/dev/null
fi

# Remove the generic default AP, if generated.
uci -q delete wireless.default_radio0

uci -q set wireless.radio0.disabled='0'
uci -q set wireless.radio0.channel='6'
uci -q set wireless.radio0.htmode='HT20'

uci -q delete wireless.uplink
uci set wireless.uplink='wifi-iface'
uci set wireless.uplink.device='radio0'
uci set wireless.uplink.mode='sta'
uci set wireless.uplink.network='wwan'
uci set wireless.uplink.encryption='psk2'
uci set wireless.uplink.disabled='1'

uci -q delete wireless.setup
uci set wireless.setup='wifi-iface'
uci set wireless.setup.device='radio0'
uci set wireless.setup.mode='ap'
uci set wireless.setup.network='setup'
uci set wireless.setup.ssid='A5-PrintServer'
uci set wireless.setup.encryption='psk2'
uci set wireless.setup.key='a5print4130'
uci set wireless.setup.disabled='0'

uci commit wireless

uci -q set system.@system[0].hostname='a5-printserver'
uci commit system

/etc/init.d/a5print enable
/etc/init.d/p910nd enable
/etc/init.d/uhttpd enable
# uci-defaults runs early during the first boot; start our supervisor now as
# well so the first boot does not require an extra reboot.
/etc/init.d/a5print start >/dev/null 2>&1

exit 0
__A5_FILE_7__
chmod 0755 'files/etc/uci-defaults/90-a5-printserver'

mkdir -p "$(dirname 'files/usr/sbin/a5printd')"
cat > 'files/usr/sbin/a5printd' <<'__A5_FILE_8__'
#!/bin/sh

MODE=""
FAIL_COUNT=0
RETRY_LIMIT=6      # 6 * 5s = ~30 seconds before fallback AP

log_msg() {
	logger -t a5print "$*"
}

eth_carrier() {
	[ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = "1" ]
}

wifi_configured() {
	[ -n "$(uci -q get wireless.uplink.ssid)" ]
}

wwan_up() {
	ifstatus wwan 2>/dev/null | grep -q '"up"[[:space:]]*:[[:space:]]*true'
}

set_mode_wired() {
	log_msg "Ethernet link detected; selecting wired print-server mode"
	uci -q set wireless.uplink.disabled='1'
	uci -q set wireless.setup.disabled='1'
	uci commit wireless
	wifi reload >/dev/null 2>&1
	ifdown setup >/dev/null 2>&1
	ifdown wwan >/dev/null 2>&1
	ifup wired >/dev/null 2>&1
	MODE="wired"
	FAIL_COUNT=0
}

set_mode_wifi() {
	log_msg "No Ethernet; trying configured Wi-Fi uplink"
	uci -q set wireless.radio0.channel='auto'
	uci -q set wireless.setup.disabled='1'
	uci -q set wireless.uplink.disabled='0'
	uci commit wireless
	ifdown setup >/dev/null 2>&1
	wifi reload >/dev/null 2>&1
	ifup wwan >/dev/null 2>&1
	MODE="wifi"
	FAIL_COUNT=0
}

set_mode_setup() {
	log_msg "Starting setup AP A5-PrintServer at 192.168.4.1"
	uci -q set wireless.radio0.channel='6'
	uci -q set wireless.uplink.disabled='1'
	uci -q set wireless.setup.disabled='0'
	uci commit wireless
	ifdown wwan >/dev/null 2>&1
	wifi reload >/dev/null 2>&1
	ifup setup >/dev/null 2>&1
	/etc/init.d/dnsmasq restart >/dev/null 2>&1
	MODE="setup"
	FAIL_COUNT=0
}

# Give kernel/netifd/USB a moment to settle after boot.
sleep 5
/etc/init.d/p910nd start >/dev/null 2>&1
/etc/init.d/uhttpd start >/dev/null 2>&1

while :; do
	if [ -e /tmp/a5print-reconfigure ]; then
		rm -f /tmp/a5print-reconfigure
		MODE=""
		FAIL_COUNT=0
	fi

	if eth_carrier; then
		[ "$MODE" = "wired" ] || set_mode_wired
	else
		if ! wifi_configured; then
			[ "$MODE" = "setup" ] || set_mode_setup
		else
			case "$MODE" in
				wifi)
					if wwan_up; then
						FAIL_COUNT=0
					else
						FAIL_COUNT=$((FAIL_COUNT + 1))
						if [ "$FAIL_COUNT" -ge "$RETRY_LIMIT" ]; then
							log_msg "Wi-Fi uplink failed; falling back to setup AP"
							set_mode_setup
						fi
					fi
				;;
				setup)
					# Stay in setup mode until credentials are saved, Ethernet appears,
					# or the device reboots. This keeps the configuration page stable.
				;;
				*)
					set_mode_wifi
				;;
			esac
		fi
	fi

	# If a printer is plugged in after boot, make sure p910nd is alive.
	if [ -c /dev/usb/lp0 ] && ! pidof p910nd >/dev/null 2>&1; then
		/etc/init.d/p910nd restart >/dev/null 2>&1
	fi

	sleep 5
done
__A5_FILE_8__
chmod 0755 'files/usr/sbin/a5printd'

mkdir -p "$(dirname 'files/www/cgi-bin/setup')"
cat > 'files/www/cgi-bin/setup' <<'__A5_FILE_9__'
#!/bin/sh

html_escape() {
	printf '%s' "$1" | sed 's/&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g;s/"/\&quot;/g'
}

url_decode() {
	local data
	data="$(printf '%s' "$1" | sed 's/+/ /g;s/%/\\x/g')"
	printf '%b' "$data"
}

reply() {
	printf 'Content-Type: text/html; charset=utf-8\r\n\r\n'
	printf '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
	printf '<title>A5 PrintServer</title><body style="font-family:system-ui;max-width:520px;margin:40px auto;padding:0 18px">%s</body>' "$1"
	exit 0
}

case "$REMOTE_ADDR" in
	192.168.4.*) ;;
	*)
		printf 'Status: 403 Forbidden\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nНастройка Wi-Fi разрешена только из локальной точки A5-PrintServer.\n'
		exit 0
		;;
esac

[ "$REQUEST_METHOD" = "POST" ] || reply '<h3>Используйте форму на главной странице.</h3><p><a href="/">Назад</a></p>'

LEN="${CONTENT_LENGTH:-0}"
case "$LEN" in *[!0-9]*|'') LEN=0;; esac
[ "$LEN" -le 512 ] || reply '<h3>Слишком длинный запрос.</h3>'

POST="$(dd bs=1 count="$LEN" 2>/dev/null)"
SSID=""
PASS=""
OLDIFS="$IFS"
IFS='&'
for item in $POST; do
	name="${item%%=*}"
	value="${item#*=}"
	case "$name" in
		ssid) SSID="$(url_decode "$value")" ;;
		pass) PASS="$(url_decode "$value")" ;;
	esac
done
IFS="$OLDIFS"

[ -n "$SSID" ] || reply '<h3>SSID не указан.</h3><p><a href="/">Назад</a></p>'

if [ -n "$PASS" ] && [ "${#PASS}" -lt 8 ]; then
	reply '<h3>Пароль WPA2 должен быть не короче 8 символов.</h3><p><a href="/">Назад</a></p>'
fi

uci set wireless.uplink.ssid="$SSID"
if [ -n "$PASS" ]; then
	uci set wireless.uplink.encryption='psk2'
	uci set wireless.uplink.key="$PASS"
else
	uci set wireless.uplink.encryption='none'
	uci -q delete wireless.uplink.key
fi
uci set wireless.uplink.disabled='0'
uci commit wireless

SSID_HTML="$(html_escape "$SSID")"
(
	sleep 2
	touch /tmp/a5print-reconfigure
) >/dev/null 2>&1 &

reply "<h3>Сохранено.</h3><p>Пробую подключиться к <b>${SSID_HTML}</b>.</p><p>Точка A5-PrintServer сейчас исчезнет. Если соединение не установится примерно за 30 секунд, она появится снова.</p>"
__A5_FILE_9__
chmod 0755 'files/www/cgi-bin/setup'

mkdir -p "$(dirname 'files/www/index.html')"
cat > 'files/www/index.html' <<'__A5_FILE_10__'
<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>A5 PrintServer</title>
<style>
body{font-family:system-ui,-apple-system,sans-serif;max-width:520px;margin:40px auto;padding:0 18px;line-height:1.45}
input{box-sizing:border-box;width:100%;padding:10px;margin:5px 0 14px;border:1px solid #aaa;border-radius:6px}
button{padding:10px 14px;border:0;border-radius:6px;font-weight:600}code{background:#eee;padding:2px 5px;border-radius:4px}.note{font-size:.92em;color:#444}
</style>
</head>
<body>
<h2>A5 PrintServer</h2>
<p>USB-принтер доступен по RAW TCP на <code>192.168.4.1:9100</code>, пока вы подключены к этой точке доступа.</p>
<form method="post" action="/cgi-bin/setup">
<label>Имя домашней Wi-Fi сети (SSID)</label>
<input name="ssid" maxlength="32" required autocomplete="off">
<label>Пароль WPA2</label>
<input name="pass" type="password" maxlength="63" autocomplete="off">
<button type="submit">Сохранить и подключиться</button>
</form>
<p class="note">После сохранения точка A5-PrintServer отключится, а устройство попытается подключиться к указанной сети. Если подключение не получится примерно за 30 секунд, точка A5-PrintServer появится снова.</p>
<p class="note">Порт печати: RAW / TCP 9100. Для Triumph-Adler LP 4130 / UTAX LP 3130 драйвер устанавливается на компьютере, а эта плата только передаёт поток в USB.</p>
</body>
</html>
__A5_FILE_10__

VER=18.06.9
TARGET=ramips/rt305x
ARCHIVE="openwrt-imagebuilder-${VER}-ramips-rt305x.Linux-x86_64.tar.xz"
SHA256="ce9d5b412ff8fc240fa0a41061d7bbc7aaf91b93356ccd63c08d5b15b5f552a9"
DIR="${ARCHIVE%.tar.xz}"

URLS=(
  "https://downloads.openwrt.org/releases/${VER}/targets/${TARGET}/${ARCHIVE}"
  "https://archive.openwrt.org/releases/${VER}/targets/${TARGET}/${ARCHIVE}"
  "https://mirror.sjtu.edu.cn/openwrt/releases/${VER}/targets/${TARGET}/${ARCHIVE}"
)

download() {
  local u
  rm -f "${ARCHIVE}.part"
  for u in "${URLS[@]}"; do
    echo "==> Downloading: $u"
    if curl -fL --retry 5 --retry-delay 2 --connect-timeout 30 \
      -o "${ARCHIVE}.part" "$u"; then
      mv "${ARCHIVE}.part" "$ARCHIVE"
      return 0
    fi
    rm -f "${ARCHIVE}.part"
  done
  return 1
}

if [ ! -f "$ARCHIVE" ]; then
  download || { echo "ERROR: all ImageBuilder mirrors failed" >&2; exit 2; }
fi

echo "$SHA256  $ARCHIVE" | sha256sum -c -

if [ ! -d "$DIR" ]; then
  tar -xJf "$ARCHIVE"
fi

pushd "$DIR" >/dev/null

# ImageBuilder profile naming changed across OpenWrt generations. Detect it
# instead of assuming case/spelling.
make info > ../imagebuilder-info.txt
PROFILE="$(awk '
  /^[[:space:]]*A5-V11:/ {gsub(":", "", $1); print $1; exit}
  /^[[:space:]]*a5-v11:/ {gsub(":", "", $1); print $1; exit}
' ../imagebuilder-info.txt)"
if [ -z "$PROFILE" ]; then
  echo "ERROR: A5-V11 profile not present in this ImageBuilder" >&2
  grep -i -C2 'a5' ../imagebuilder-info.txt || true
  exit 3
fi

echo "==> Using ImageBuilder profile: $PROFILE"

# Dedicated print appliance. Remove routing/PPP/IPv6/package-management and
# SSH components; keep dnsmasq for the provisioning AP and add the raw USB
# print server plus USB printer class driver.
PACKAGES="-firewall -iptables -ip6tables -kmod-ipt-core -kmod-ipt-conntrack -kmod-ipt-nat -kmod-ip6tables -odhcp6c -odhcpd-ipv6only -ppp -ppp-mod-pppoe -opkg -dropbear p910nd kmod-usb-core kmod-usb2 kmod-usb-ohci kmod-usb-printer uhttpd"

make image \
  PROFILE="$PROFILE" \
  PACKAGES="$PACKAGES" \
  FILES="$(cd .. && pwd)/files"

popd >/dev/null

mkdir -p out
cp -v "$DIR"/bin/targets/ramips/rt305x/*a5-v11*factory.bin out/ 2>/dev/null || true
cp -v "$DIR"/bin/targets/ramips/rt305x/*a5-v11*sysupgrade.bin out/ 2>/dev/null || true

if ! compgen -G 'out/*a5-v11*.bin' >/dev/null; then
  echo "ERROR: ImageBuilder did not produce an A5-V11 image." >&2
  find "$DIR/bin/targets/ramips/rt305x" -maxdepth 1 -type f -printf '%f\n' 2>/dev/null || true
  exit 4
fi

MAX=$((0x3b0000))
{
  echo "OpenWrt: $VER"
  echo "Target: $TARGET"
  echo "Profile: $PROFILE"
  echo "A5-V11 firmware partition limit: $MAX bytes (0x3b0000)"
  echo "Packages: $PACKAGES"
} > out/build-info.txt

: > out/SHA256SUMS
for f in out/*a5-v11*.bin; do
  size=$(stat -c%s "$f")
  printf '%s: %d bytes (partition limit %d)\n' "$f" "$size" "$MAX" | tee -a out/build-info.txt
  # factory.bin has a small Poray wrapper; the actual sysupgrade payload is
  # checked by OpenWrt's image recipe before that wrapper is added. This
  # conservative external check should still pass for our deliberately small
  # image and protects against accidental bloat.
  if [ "$size" -gt "$MAX" ]; then
    echo "ERROR: image exceeds A5-V11 firmware partition" >&2
    exit 5
  fi
  sha256sum "$f" | tee -a out/SHA256SUMS
  sha256sum "$f" > "$f.sha256"
done
