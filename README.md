# Gitea → роутер Keenetic/Netcraze: git-зеркало на Entware

Автоматическое зеркалирование всех репозиториев Gitea на роутер Keenetic/Netcraze с Entware.
Копия обновляется при каждом `git push` в Gitea, без копирования файлов по расписанию,
поэтому половинчатого состояния репозитория не бывает.

```
Вы ── git push ──► Gitea ── push-зеркало (HTTPS) ──► KeenDNS ──► роутер (lighttpd + git-http-backend)
```

Что умеет:

- **Работает через KeenDNS по HTTPS**, в том числе когда у роутера серый IP (облачный режим) или нестабильный белый. VPN не нужен.
- **Репозитории на роутере создаются сами** при первом push, вручную их создавать не надо.
- **Скрипт добавляет зеркала всем репозиториям** Gitea через API. Повторный запуск безопасен: репозитории, у которых зеркало уже есть, пропускаются.
- **Лёгкий:** на роутере только `lighttpd` и `git`, десяток МБ памяти. Подходит и для моделей с ~500 МБ RAM.

Что **не** зеркалируется: вики (отдельный репозиторий `<repo>.wiki.git`), issues, PR, пользователи, LFS-объекты и настройки Gitea. Для полной резервной копии добавьте `gitea dump`.

## Требования

- Роутер Keenetic/Netcraze с USB-накопителем и установленным [Entware](https://help.keenetic.com/hc/ru/articles/360021214160), доступ по SSH.
- На Entware пакеты `git` и `git-http` (остальное ставит `install.sh`).
- Настроенное доменное имя KeenDNS (Netcraze DNS) с HTTPS.
- Gitea 1.19 или новее (`push mirrors` с `sync_on_commit` в API). Проверено на Gitea 28.
- Windows с PowerShell 5.1 для скрипта `sync-mirrors`.

## Установка

### 1. Роутер

Скопируйте `router/install.sh` на роутер и запустите от root:

```sh
sh install.sh
```

Скрипт:
- ставит `lighttpd` и нужные модули;
- создаёт CGI-обёртку `/opt/share/git-gate/git-gate.cgi`: проверяет путь `/<владелец>/<репозиторий>.git`, создаёт bare-репозиторий при первом push и передаёт запрос в `git-http-backend`;
- настраивает `lighttpd` на порту `3000` (меняется переменной `PORT` в начале скрипта) с basic-авторизацией;
- создаёт пользователя `mirror` со случайным паролем и **печатает его один раз**, сохраните;
- добавляет автозапуск `/opt/etc/init.d/S81git-mirror` и отключает штатный `S80lighttpd` Entware, чтобы он не занял порт 80.

Проверка на роутере (ожидается ответ `repository not found`):

```sh
curl -u mirror:ПАРОЛЬ "http://127.0.0.1:3000/t/x.git/info/refs?service=git-upload-pack"
```

### 2. KeenDNS

В веб-интерфейсе роутера опубликуйте HTTPS-сервис вашего домена KeenDNS на порт `3000` роутера. Для KeenDNS подойдёт режим «Свободный доступ»: защиту обеспечивает авторизация `lighttpd`. Проверка снаружи:

```sh
curl -i https://ВАШ-ДОМЕН/            # без пароля должен быть 401 Unauthorized
curl -u mirror:ПАРОЛЬ https://ВАШ-ДОМЕН/t/x.git/info/refs?service=git-upload-pack   # repository not found
```

### 3. Gitea: настройки `app.ini`

Gitea 28 блокирует зеркалирование на неразрешённые хосты, а `http.postBuffer` нужен, чтобы git отправлял push с `Content-Length`, а не chunked (цепочка KeenDNS → lighttpd chunked не принимает). В `custom/conf/app.ini`:

```ini
[migrations]
EGRESS_MODE = lax
ALLOWED_HOST_LIST = ваш-домен.netcraze.pro

[git.config]
; обязательно: без этого большие push падают с "HTTP 411" (см. «Диагностика»)
http.postBuffer = 1073741824
```

Затем **перезапустите Gitea**. Если ошибка `You cannot import from disallowed hosts` остаётся, проверьте, в какие адреса домен разрешается у ПК с Gitea (`nslookup ваш-домен`). Локальный DNS (в том числе с «fake-ip») может подставлять зарезервированные адреса вроде `198.51.100.x` — тогда добавьте эти адреса или подсети в `ALLOWED_HOST_LIST`. Подробнее: [Config Cheat Sheet](https://docs.gitea.com/administration/config-cheat-sheet).

### 4. Gitea: токен и зеркала

1. В Gitea: **Settings → Applications** → создайте токен с правами `repository: Read and Write` и `user: Read` (при репозиториях в организациях ещё `organization: Read`).
2. Скопируйте `gitea/config.example.json` в `gitea/config.json` и заполните:

   | Поле | Значение |
   |---|---|
   | `giteaUrl` | например `http://localhost:3000` |
   | `giteaToken` | токен из шага 1 |
   | `remoteBase` | `https://ВАШ-ДОМЕН.netcraze.pro` (с портом, если он не 443) |
   | `remoteUser` / `remotePassword` | `mirror` и пароль из `install.sh` |
   | `interval` | интервал периодической синхронизации, по умолчанию `8h0m0s` |

3. Запустите:

   ```
   gitea\sync-mirrors.bat
   ```

   Для каждого репозитория создаётся push-зеркало с `sync_on_commit` и сразу запускается первая выгрузка. Новые репозитории подхватываются при повторном запуске. Удобно вызывать скрипт из `.bat`, которым вы стартуете Gitea.

`gitea/config.json` содержит секреты и добавлен в `.gitignore`. Не публикуйте его.

Для нескольких репозиториев зеркало можно добавить и вручную: **репозиторий → Settings → Repository → Mirror Settings → Push Mirrors**, URL вида `https://ВАШ-ДОМЕН/<владелец>/<репозиторий>.git`, логин `mirror`, включить «Sync when new commits are pushed».

## Безопасность

- Доступ к роутеру только по HTTPS с basic-авторизацией; пароль случайный, 40 символов. При смене пароля перезапись зеркал в Gitea потребуется заново.
- CGI принимает только пути вида `/<владелец>/<репозиторий>.git` из символов `A-Za-z0-9._-`, имена не могут начинаться с точки (защита от `..`). Создание репозитория происходит только на push.
- Пароль зеркала хранится в базе Gitea и в `config.json` открытым текстом: берегите носитель.

## Диагностика

| Симптом | Причина и решение |
|---|---|
| `mkdir failed` на push | В окружении CGI нет `PATH`. В актуальном `install.sh` он задаётся явно; обновите `/opt/share/git-gate/git-gate.cgi`. |
| `You cannot import from disallowed hosts` | См. шаг 3 выше: `ALLOWED_HOST_LIST`/`EGRESS_MODE`, перезапуск Gitea, проверка DNS. |
| `Permission denied` / `401` от API Gitea на создании зеркала | Чаще всего это тоже блокировка хоста (шаг 3), а не права. Проверьте, что токен от владельца репозиториев и у него есть `user: Read`. |
| `RPC failed; HTTP 411` при push | Git шлёт большой push с `Transfer-Encoding: chunked`, а цепочка KeenDNS → lighttpd его не принимает. Заставьте git отправлять тело с `Content-Length`: в `app.ini` Gitea добавьте `[git.config]` → `http.postBuffer = 1073741824` и перезапустите Gitea, затем повторите синхронизацию. |
| Ошибки в логе роутера | `/opt/var/log/git-mirror-lighttpd.log` |
| Тяжёлый репозиторий не выгружается | Через облачный прокси KeenDNS возможны таймауты. Повторите синхронизацию или отправьте первый push, когда у роутера белый IP. |

## Структура

```
router/install.sh          установка на роутер (lighttpd, CGI, пользователь, автозапуск)
gitea/sync-mirrors.ps1     добавление push-зеркал через API Gitea
gitea/sync-mirrors.bat     запуск скрипта в Windows
gitea/config.example.json  пример настроек (config.json в .gitignore)
```
