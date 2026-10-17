# OpenCode notifier for Windows

Лёгкая система уведомлений для OpenCode в Windows 11. Плагин OpenCode отслеживает
события сессии, а отдельный PowerShell watchdog сообщает о сбое процесса и долгом
отсутствии активности. Уведомления различают завершение задачи, ошибку, запрос
разрешения/ответа и возможное зависание.

Система работает локально и не требует платных сервисов. По желанию можно настроить
Telegram-бота; тогда сообщения и текст запроса проходят через Telegram. Звук
повторяется до подтверждения или до истечения настроенного времени.

## Установка

1. Установите [OpenCode](https://opencode.ai/) и Node.js для Windows.
2. Откройте PowerShell и клонируйте репозиторий в папку профиля:

   ```powershell
   git clone https://github.com/zakiroc/opencode-notify.git "$env:USERPROFILE\opencode-notify"
   ```

3. Установите плагин и ярлык остановки сигнала:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\opencode-notify\manage.ps1" install
   ```

4. Полностью перезапустите OpenCode. Проверить установку можно командой:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\opencode-notify\manage.ps1" status
   ```

Конфигурация пользователя создаётся при первом запуске как
`%USERPROFILE%\opencode-notify\config.json`. Исходный `config.example.json`
остаётся неизменным, а пользовательская конфигурация, журналы и состояние исключены
из Git.

## Telegram (необязательно)

Запустите мастер настройки:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\opencode-notify\manage.ps1" telegram
```

Создайте бота через [@BotFather](https://t.me/BotFather), отправьте сообщение своему
боту и следуйте подсказкам мастера. Токен записывается локально в `config.json`,
который исключён из Git. Никогда не публикуйте этот файл или токен.

## Проверка и управление

```powershell
$script = "$env:USERPROFILE\opencode-notify\manage.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File $script test done
powershell -NoProfile -ExecutionPolicy Bypass -File $script test error
powershell -NoProfile -ExecutionPolicy Bypass -File $script test input
powershell -NoProfile -ExecutionPolicy Bypass -File $script test stalled
powershell -NoProfile -ExecutionPolicy Bypass -File $script test crashed
```

Тесты `done`, `error` и `input` проверяют сигнал и при включённом Telegram
отправляют тестовое сообщение. `stalled` и `crashed` временно создают тестовое
состояние для watchdog. Для управления используйте команды `status`, `pause`,
`resume`, `stop-alarm`, `stop`, `start` и `uninstall`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $script status
powershell -NoProfile -ExecutionPolicy Bypass -File $script stop-alarm
```

Ярлык **Stop OpenCode Alarm** на рабочем столе также останавливает повтор сигнала.
Настройки звуков, порогов зависания и Telegram находятся в пользовательском
`config.json`. Журналы записываются в `logs`.

## Ограничения

- Долгое молчание не позволяет точно отличить зависание от медленного ответа; такое
  событие помечается как возможное зависание.
- Сон или потеря питания компьютера, а также полная остановка сети не могут быть
  обнаружены самим компьютером.
- Уведомления OpenCode передают название проекта и краткий контекст события;
  Telegram-сообщения проходят через серверы Telegram.
