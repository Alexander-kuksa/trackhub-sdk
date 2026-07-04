# TrackHub × Google Ads Offline Conversion API — план перепроектирования

Цель: превратить TrackHub из «SKAN + ASA-атрибуция» в конвейер user-level
конверсий для Google Ads, чтобы Smart Bidding оптимизировал кампании мобильных
приложений по реальной подписочной воронке (`install → trial_started →
trial_converted → renewal → refund`), а не только по агрегированным
SKAN-постбекам.

Предпосылки: Google Ads API уже подключён; доступ к загрузке оффлайн-конверсий
(`ConversionUploadService`, включая gbraid/wbraid) появится. Этот документ —
что переиспользовать из текущей кодовой базы, что дописать в SDK, и как должен
выглядеть новый бэкенд-контур.

---

## 1. Что уже есть и переиспользуется как есть

Самое важное: **половина работы уже сделана** — SDK 1.2.0 спроектирован с
заделом ровно под этот сценарий.

| Компонент | Где | Роль в новой схеме |
| --- | --- | --- |
| Захват `gbraid`/`wbraid` из deep link | `TrackHub.handleDeepLink` / `setGoogleClickId` / `parseGoogleClickIds` (`Sources/TrackHub/TrackHub.swift:86-111`) | Источник click id — ключа, по которому Google матчит загруженную конверсию с кликом |
| Click id в install-репорте | `reportInstallIfNeeded` (`TrackHub.swift:212-213`) | Бэкенд уже получает и хранит click id на уровне пользователя |
| События с выручкой | `trackEvent(name:revenueCents:currency:transactionId:)` (`TrackHub.swift:117-141`) | `transaction_id` → `order_id` конверсии (дедупликация на стороне Google) |
| Apphud-вебхуки (бэкенд) | `INTEGRATION.md` («Revenue … Apphud webhooks → TrackHub») | Авторитетный поток подписочных событий: trial started / converted / renewal / refund — основной источник конверсий для загрузки |
| Оффлайн-буфер + ретраи | `EventQueue.swift` | Без изменений — надёжная доставка событий с устройства |
| HMAC-подпись репортов | `postRaw` (`TrackHub.swift:280-297`) | Без изменений — защита от подделки «конверсий» |
| SKAN-канал | `ConversionSchema.swift`, `SKANUpdater.swift` | **Не выбрасывать.** Остаётся каналом для установок без click id (чистые App Store инсталлы из App-кампаний) — Google сам потребляет SKAN-постбеки |
| user_id-связка с биллингом | `configure(userId:)` / `setUserId` | Join click id ↔ подписочные события Apphud по одному user id |

Вывод: SDK-слой почти готов; перепроектирование — это в основном **новый
экспортный контур на бэкенде** плюс небольшой SDK 1.3.

---

## 2. Реальность iOS: какие клики вообще можно поймать

Это определяет, где оффлайн-конверсии дадут эффект, а где останется SKAN:

1. **App-кампании → App Store (новые установки, ACi).** App Store не передаёт
   URL-параметры в установленное приложение — click id до SDK не доходит.
   Эти установки остаются на SKAN-канале (уже реализован). Оффлайн-загрузка
   тут невозможна без статуса MMP.
2. **Web-to-app воронка (лендинг/квиз → universal link → приложение).**
   Клик по объявлению ведёт на веб — в URL приходит `wbraid` (iOS-трафик) или
   `gclid`; лендинг пробрасывает его в universal link, SDK ловит через
   `handleDeepLink`. **Главный сценарий для подписочных воронок.**
3. **App Engagement / deep-link клики в уже установленное приложение.**
   В URL приходит `gbraid` — SDK ловит его напрямую.
4. **Веб-подписка с логином в приложении.** Click id захвачен на вебе,
   конверсия джойнится по email/user id — грузится с веб-стороны TrackHub.
5. **Android (когда появится).** Play Install Referrer доносит `gclid` через
   установку — там user-level контур закрывает всю воронку целиком. Самый
   большой выигрыш от этой архитектуры; стоит закладывать в дизайн бэкенда
   сразу (поле `gclid` рядом с gbraid/wbraid).

---

## 3. Целевая архитектура

```
 iOS SDK                     TrackHub backend                        Google Ads API
┌───────────────┐   install/click   ┌──────────────┐
│ handleDeepLink ├──────────────────▶ click store  │
│ trackEvent     │   sdk/track      │ (user_id ↔   │
└───────────────┘                   │  click id,   │
                                    │  captured_at)│
 Apphud webhooks ──────────────────▶──────┬────────┘
 (trial/convert/renew/refund)             │ join по user_id,
                                          ▼ last click ≤ event time
                                   ┌──────────────────┐
                                   │ conversion export │  батчи ≤2000,
                                   │ queue (state      │  partial_failure
                                   │ machine + dedup   ├──▶ UploadClickConversions
                                   │ по order_id)      │
                                   └──────┬────────────┘
                                          │ refund / изменение суммы
                                          ▼
                                   adjustments worker ───▶ UploadConversionAdjustments
                                          │                (RETRACTION / RESTATEMENT,
                                          ▼                 по order_id)
                                   verifier (GAQL +
                                   upload diagnostics) ──▶ health-дашборд в UI
```

---

## 4. Изменения в SDK (v1.3) — минимальные

1. **Re-engagement клики.** Сейчас click id уезжает только в одноразовом
   install-репорте (`reportInstallIfNeeded`); id, пойманный после первого
   запуска, оседает в UserDefaults и никогда не достигает бэкенда. Добавить:
   если install уже отправлен, новый click id шлётся отдельным
   `POST /ingest/{token}/sdk/click` (`user_id`, `gbraid|wbraid`,
   `captured_at`). Переиспользует готовые `send(path:body:)` + `EventQueue`.
2. **Timestamp клика.** Хранить `captured_at` рядом с click id (сейчас только
   значение). Нужен бэкенду для выбора «последний клик до конверсии» и
   проверки окна атрибуции.
3. **Consent-сигнал (DMA/EEA).** `TrackHub.setConsent(adUserData:
   adPersonalization:)` → поле в телах install/click/track. Без
   `consent.ad_user_data = GRANTED` Google отбрасывает загрузки по
   EEA-пользователям. ATT здесь ни при чём — это согласие из вашего
   CMP/онбординга.
4. **(Опционально) StoreKit 2 обзервер покупок** — авто-захват
   `Transaction.id`, цены и валюты, чтобы `transaction_id` для `order_id`
   не зависел только от Apphud. Не блокирует запуск: Apphud-вебхуки уже дают
   всё нужное.

Паттерн тестов сохраняется: логика «последний клик побеждает», парсинг,
consent-энкодинг — в `Sources/EncoderTests` (parity-стиль, `swift run
encoder-tests`).

---

## 5. Новый бэкенд-контур (спека; код живёт в репо платформы)

### 5.1 Хранилище кликов

`google_clicks(app_id, user_id, click_type ∈ {gclid, gbraid, wbraid},
click_id, captured_at, source ∈ {install, reengagement, web})`

Пишется из install-репорта (уже приходит), нового `sdk/click` и веб-пикселя
(если есть веб-воронка).

### 5.2 Настройка интеграции (UI «Google Ads»)

- OAuth-связка аккаунта: developer token, refresh token, `customer_id`
  (+ `login_customer_id` для MCC).
- Bootstrap conversion actions через API (`type = UPLOAD_CLICKS`):

| Действие | Категория | Счёт | Значение | Роль в биддинге |
| --- | --- | --- | --- | --- |
| `th_trial_started` | `START_TRIAL` | ONE_PER_CLICK | без значения | primary на старте (быстрый, объёмный сигнал) |
| `th_subscription_started` | `SUBSCRIBE_PAID` | ONE_PER_CLICK | фактический первый платёж | primary после накопления объёма (tROAS) |
| `th_renewal` | `PURCHASE` | MANY_PER_CLICK | фактический платёж | secondary/observation (чтобы не двоить биддинг) |

- Click-through lookback window действий: **90 дней** (клик → установка →
  триал 3–7 дней → оплата → первые ренуалы месячной подписки).
- Маппинг «внутреннее событие → conversion action» — конфиг per app, в духе
  существующего Conversion Hub (та же идея remote-schema, что и
  `cv-schema`, только для Google-экспорта).

### 5.3 Экспортная очередь (state machine)

`conversion_uploads(id, app_id, source_event_id, order_id, click_ref,
conversion_action, value_cents, currency, conversion_at, state, attempts,
last_error, uploaded_at)`

- **Enqueue:** на каждое подписочное событие (Apphud-вебхук или `sdk/track` с
  `transaction_id`) — найти последний клик пользователя с
  `captured_at ≤ conversion_at` внутри lookback-окна; нет клика → событие
  остаётся только в SKAN/аналитике.
- **Дедуп:** уникальный индекс `(app_id, conversion_action, order_id)`;
  `order_id` = store transaction id (или Apphud event id как fallback).
- **Состояния:** `pending → eligible → uploaded | retry | dead`.
  - `eligible` не раньше чем через **~6 часов после клика** — клики становятся
    доступными для матчинга с задержкой; ранняя загрузка даёт `CLICK_NOT_FOUND`.
  - `CLICK_NOT_FOUND` → retry с бэкоффом до 72 ч, затем `dead`.
  - `EXPIRED_CLICK` / невалидный id → сразу `dead` (с причиной в UI).

### 5.4 Uploader worker (каждые 2–4 часа)

- Батчи **≤ 2000 конверсий** на `UploadClickConversionsRequest`,
  `partial_failure = true` (обязателен), per-row разбор
  `partial_failure_error`.
- Поля `ClickConversion`:
  - ровно один из `gclid` / `gbraid` / `wbraid`;
  - `conversion_action` — resource name из маппинга;
  - `conversion_date_time` — `yyyy-MM-dd HH:mm:ss±HH:mm` (обязателен часовой
    сдвиг; время ≥ времени клика);
  - `conversion_value` = `value_cents / 100` + `currency_code` (ISO-4217,
    Google сам конвертирует в валюту аккаунта);
  - `order_id` — всегда: дедуп у Google + **единственный ключ для будущих
    adjustments по gbraid/wbraid-конверсиям**;
  - `conversion_environment = APP` для ин-апп событий;
  - `consent.ad_user_data` / `ad_personalization` из SDK/CMP;
  - custom variables с gbraid/wbraid **не поддерживаются** — не закладывать.
- `validate_only = true` — режим интеграционного теста без записи.

### 5.5 Refunds / изменения суммы

Worker поверх Apphud-событий `refund` / `billing_issue`:
`UploadConversionAdjustments` — `RETRACTION` (возврат) или `RESTATEMENT`
(смена суммы), матчинг **только по `order_id`** для gbraid/wbraid-конверсий.
Слать оперативно — окно корректировок ограничено.

### 5.6 Verifier / health

- GAQL-джоб: `metrics.all_conversions` по `segments.conversion_action_name` —
  сверка «загружено vs принято».
- Диагностика загрузок (`offline_conversion_upload_client_summary`) →
  дашборд в UI приложения: uploaded / matched / duplicate / errors по типам.
  Это то, что отличает рабочий контур от «молча теряем 30% конверсий».

---

## 6. Стратегия оптимизации подписочной воронки

1. **Фаза A — объём сигнала.** Primary-действие `th_trial_started`,
   биддинг tCPA / Maximize Conversions. Триалы происходят в первые часы-дни
   после клика → быстрая обратная связь для обучения.
2. **Фаза B — ценность.** Когда `th_subscription_started` стабильно даёт
   ≥ 30–50 конверсий/мес на кампанию — переключить primary на него и перейти
   на tROAS с фактической выручкой первого платежа.
3. **Фаза C — pLTV.** Значение конверсии триала = предсказанная LTV
   (по продукту, гео, cohort trial→paid). Загружать при триале с
   `value = E[LTV]`, уточнять `RESTATEMENT`-ами по факту. Даёт tROAS-сигнал
   на 1–2 недели раньше, чем ждать реальный платёж.
4. SKAN-схема (Conversion Hub) продолжает кодировать те же события
   (`trial_started`, `trial_converted` + revenue-бакеты) — Google совмещает
   агрегированный SKAN-сигнал и user-level загрузки; они дополняют, а не
   конфликтуют.

---

## 7. Порядок внедрения

| Фаза | Объём | Результат |
| --- | --- | --- |
| 0 | Allowlist на gbraid/wbraid-загрузки; OAuth-связка; создание conversion actions; `validate_only`-тест | Доступ подтверждён end-to-end |
| 1 | SDK 1.3: `sdk/click`, `captured_at`, consent API + parity-тесты | Клики доезжают до бэкенда всегда, не только при установке |
| 2 | Бэкенд: click store, enqueuer, uploader, retry/dead-логика | Первые конверсии видны в Google Ads (столбец Conversions по `th_*` действиям) |
| 3 | Adjustments (refunds) + verifier/health-дашборд | Чистые данные, наблюдаемость |
| 4 | pLTV + переход на tROAS | Собственно цель — оптимизация под LTV подписки |

---

## 8. Риски и открытые вопросы

- **Доля трафика с click id.** Если почти весь трафик — чистые ACi-установки,
  user-level контур почти пуст: сначала оценить долю install-репортов с
  gbraid/wbraid в существующих данных; при малой доле — смещать медиаплан в
  web-to-app воронку (стандартная практика подписочных приложений) и/или
  приоритизировать Android.
- **Allowlist.** Требования Google к доступу на gbraid/wbraid-загрузки
  меняются — сверить актуальные условия при получении доступа.
- **Двойной счёт с SKAN.** На стороне Google App-кампании считают SKAN,
  загрузки идут по кликовым конверсионным действиям; следить, чтобы primary
  goal кампании не суммировал оба источника за одно и то же событие.
- **EEA-консент.** Без прокинутого consent загрузки по EEA молча
  деградируют — консент-поле обязательно с первой версии, не «потом».
