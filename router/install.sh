#!/bin/sh
# Установка git-зеркала на роутер (Entware). Запускать на роутере от root:
#   sh install.sh
# Скрипт самодостаточен: создаёт lighttpd-конфиг, CGI-обёртку, init-скрипт и пользователя.
set -e

PORT=3000
GIT_ROOT=/opt/git
WEB_ROOT=/opt/share/git-gate
CONF=/opt/etc/lighttpd/git-mirror.conf
USERS=/opt/etc/git-mirror.users
INIT=/opt/etc/init.d/S81git-mirror
MIRROR_USER=mirror

echo "==> Установка пакетов"
opkg update
for p in lighttpd lighttpd-mod-cgi lighttpd-mod-auth lighttpd-mod-authn_file lighttpd-mod-rewrite; do
    opkg install "$p" || echo "(пакет $p не установлен отдельно — возможно, встроен)"
done

HTTP_BACKEND="$(git --exec-path)/git-http-backend"
[ -x "$HTTP_BACKEND" ] || { echo "Не найден $HTTP_BACKEND (поставьте git-http)"; exit 1; }

mkdir -p "$GIT_ROOT" "$WEB_ROOT" /opt/etc/lighttpd /opt/var/run /opt/var/log

echo "==> CGI-обёртка"
cat > "$WEB_ROOT/git-gate.cgi" <<'EOF'
#!/bin/sh
# Принимает smart-HTTP запросы git. Путь: /<owner>/<repo>.git/...
# Репозиторий создаётся автоматически при первом push.
PATH=/opt/bin:/opt/sbin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH
ROOT=/opt/git

fail() {
    printf 'Status: %s\r\nContent-Type: text/plain\r\n\r\n%s\n' "$1" "$2"
    exit 0
}

P="${PATH_INFO:-}"
rest="${P#/}"
owner="${rest%%/*}"
rest="${rest#*/}"
repo="${rest%%/*}"

case "$owner" in ""|.*|*[!A-Za-z0-9._-]*) fail 400 "bad owner" ;; esac
case "$repo"  in ""|.*|*[!A-Za-z0-9._-]*) fail 400 "bad repo"  ;; esac
case "$repo"  in *.git) ;; *) fail 400 "repo must end with .git" ;; esac

DIR="$ROOT/$owner/$repo"

is_push=0
case "$QUERY_STRING" in *service=git-receive-pack*) is_push=1 ;; esac
case "$P" in */git-receive-pack) is_push=1 ;; esac

if [ ! -d "$DIR" ]; then
    [ "$is_push" = 1 ] || fail 404 "repository not found"
    err="$(mkdir -p "$DIR" 2>&1)" || fail 500 "mkdir failed: $err (uid=$(id -u))"
    err="$(git init --bare -q "$DIR" 2>&1)" || fail 500 "git init failed: $err"
    git --git-dir="$DIR" config http.receivepack true
fi

export HOME=/tmp
export GIT_PROJECT_ROOT="$ROOT"
export GIT_HTTP_EXPORT_ALL=1
export REMOTE_USER="${REMOTE_USER:-mirror}"
exec "$(git --exec-path)/git-http-backend"
EOF
chmod +x "$WEB_ROOT/git-gate.cgi"

echo "==> Конфиг lighttpd"
cat > "$CONF" <<EOF
server.modules = ( "mod_rewrite", "mod_auth", "mod_authn_file", "mod_cgi" )
server.port = $PORT
server.document-root = "$WEB_ROOT"
server.pid-file = "/opt/var/run/git-mirror-lighttpd.pid"
server.errorlog = "/opt/var/log/git-mirror-lighttpd.log"
server.max-request-size = 0
server.stream-request-body = 2
server.max-read-idle = 300
server.max-write-idle = 300
url.rewrite-once = ( "^/(.*)\$" => "/git-gate.cgi/\$1" )
cgi.assign = ( ".cgi" => "" )
auth.backend = "plain"
auth.backend.plain.userfile = "$USERS"
auth.require = ( "" => ( "method" => "basic", "realm" => "git mirror", "require" => "valid-user" ) )
EOF

echo "==> Пользователь"
if [ ! -f "$USERS" ]; then
    PASS="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 40)"
    echo "$MIRROR_USER:$PASS" > "$USERS"
    chmod 600 "$USERS"
    echo "----------------------------------------"
    echo "ЛОГИН:  $MIRROR_USER"
    echo "ПАРОЛЬ: $PASS"
    echo "Сохраните пароль — он больше не будет показан."
    echo "----------------------------------------"
else
    echo "Файл $USERS уже есть, пароль не менялся."
fi

echo "==> Автозапуск"
cat > "$INIT" <<EOF
#!/bin/sh
CONF=$CONF
PIDF=/opt/var/run/git-mirror-lighttpd.pid
case "\$1" in
    start)   lighttpd -f "\$CONF" ;;
    stop)    [ -f "\$PIDF" ] && kill "\$(cat "\$PIDF")" ;;
    restart) "\$0" stop; sleep 1; "\$0" start ;;
    *) echo "usage: \$0 {start|stop|restart}"; exit 1 ;;
esac
EOF
chmod +x "$INIT"

# Штатный lighttpd Entware занял бы порт 80 — отключаем его автозапуск
[ -x /opt/etc/init.d/S80lighttpd ] && chmod -x /opt/etc/init.d/S80lighttpd

lighttpd -tt -f "$CONF"
"$INIT" restart
sleep 1
echo "==> Готово. Проверка:"
echo "curl -u mirror:ПАРОЛЬ http://127.0.0.1:$PORT/test/x.git/info/refs?service=git-upload-pack  (ожидается 404)"
