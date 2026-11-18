# brewman

Интерактивный менеджер Homebrew в терминале: просмотр, поиск, установка, удаление и обновление пакетов, сервисы, репозитории (tap) и доверие к ним, закрепление версий (pin), резервная копия Brewfile, очистка и диагностика. Совместим с bash 3.2 (macOS) и bash 4/5 (Linux).

## Установка на новый компьютер

Репозиторий приватный, поэтому нужна утилита gh с входом в GitHub:

```
brew install gh
```

```
gh auth login
```

Скачать и установить brewman как команду:

```
gh api -H "Accept: application/vnd.github.raw" "repos/aa9010x-prog/brewman/contents/brewman.sh?ref=main" > /tmp/brewman.sh && bash /tmp/brewman.sh --install
```

## Обновление

brewman раз в сутки при запуске сам проверяет новую версию и предлагает обновиться. Вручную:

```
brewman --update
```

Вернуть предыдущую версию:

```
brewman --rollback
```

## Выпуск новой версии

1. Увеличить `VERSION="…"` в `brewman.sh`.
2. Записать тот же номер в файл `VERSION`.
3. Добавить раздел в `CHANGELOG.md` в формате `## X.Y.Z – ДД.ММ.ГГГГ`.
4. Закоммитить и отправить в ветку `main`.
