# DualGap AI (FAF, Dual Gap Adaptive v14)

ИИ с ролями по точке спавна: `GROUND`, `NAVAL`, `AIR`, `ECO`.

## Установка
1. Скопировать папку `DualGapAI` в `%USERPROFILE%\Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\mods\`.
   Папка должна называться именно `DualGapAI`: FAF монтирует мод как `/mods/DualGapAI/`, и все импорты внутри мода используют этот путь.
2. В лобби FAF включить мод **DualGap AI** и поставить в слоты ИИ **AI: DualGap** (или **AIx: DualGap**, читерская версия).

## Роли на Dual Gap Adaptive v14 (по маркерам карты)
| Слот | Роль | Слот | Роль |
|---|---|---|---|
| ARMY_1 | AIR | ARMY_2 | AIR |
| ARMY_9 | GROUND | ARMY_10 | GROUND |
| ARMY_3 | GROUND | ARMY_4 | GROUND |
| ARMY_5 | NAVAL | ARMY_6 | NAVAL |
| ARMY_11 | ECO | ARMY_12 | ECO |
| ARMY_7 | AIR | ARMY_8 | AIR |

Координаты считаются от прямоугольника `AREA_1` (0, 200.5 → 1024, 830.5), в нём карта стартует.
Он не меняется, когда адаптивная карта расширяет игровую область.

## Как назначаются роли
Берутся все стартовые маркеры `ARMY_N`. Они делятся на левую и правую команду и сортируются сверху вниз.
Если в команде 6 спавнов, роль берётся по порядку: AIR, GROUND, GROUND, NAVAL, ECO, AIR (как на схеме карты).
Иначе берётся ближайшая опорная точка из `DualGapConfig.SpawnSlots`.
В `game.log` для каждого слота пишется строка `DualGap: ARMY_n side=... role=...`. По ней удобно проверить и откалибровать координаты.
Принудительно задать роль: `RoleOverrides = { ARMY_3 = 'ECO' }` в `lua/AI/DualGapConfig.lua`.

## Структура
| Файл | Что делает |
|---|---|
| `lua/AI/DualGapConfig.lua` | все числа, спавны, маршруты (нормализованные 0..1, зеркалятся для правой команды) |
| `lua/AI/DualGapRoleManager.lua` | определение роли и стороны |
| `lua/AI/DualGapRoutes.lua` | маршруты по дугам и морской вектор, `ExecuteQueuedMovement` |
| `lua/AI/DualGapACUBehaviors.lua` | Overcharge, GROUND: марш → укрепление → удержание прохода, NAVAL: верфь → циклы фабрик и торпедные установки, уход под воду |
| `lua/AI/DualGapArmy.lua` | волны танков по двум дугам, арта/MML за стеной, флот, патрули истребителей над GROUND, рейды бомбардировщиков |
| `lua/AI/DualGapEconomy.lua` | апгрейды мексов и фабрик, RAS для ECO, стратегическая фаза ECO (80% инженеров) |
| `lua/AI/DualGapInit.lua` | точка входа (вызывается из `FirstBaseFunction`) |
| `lua/AI/AIBuilders/DualGap*Builders.lua` | BuilderGroup-ы ролей |
| `lua/AI/AIBaseTemplates/DualGapTemplates.lua` | 4 базовых шаблона, по одному на роль |
| `lua/AI/PlatoonTemplates/DualGapPlatoonTemplates.lua` | шаблоны взводов с явными ID юнитов |
| `hook/lua/aibrains/index.lua` | привязка ключа `dualgap` к стандартному мозгу ИИ (новые сборки FAF) |

## Отличия от исходного ТЗ
- **Координаты ролей из ТЗ не совпадают со схемой карты.** По ТЗ ECO стоит в глубоком тылу по центру, но на схеме спавны идут колонками по краям.
  Поэтому роль определяется по порядку спавна внутри команды, а не по жёстким прямоугольникам в координатах 1024×1024.
- В ТЗ были ошибки, они исправлены: `platoon:GetGetCommander()` не существует; `GetNumUnitsAroundPoint` без `'Enemy'` считал и свою арту;
  `ExecuteQueuedMovement` портил общую таблицу маршрута; цикл безопасности завершался после первого отступления.
- Условие погружения по времени (18:00) действует только для GROUND и NAVAL. ECO и AIR по ТЗ базу не покидают и при низком HP отходят к старту.
- Файлы билдеров переименованы с префиксом `DualGap`, чтобы мод не перекрыл одноимённые стандартные файлы FAF.

## Что нужно проверить в игре
Офлайн-тесты (`python tests/run_tests.py`) проверяют синтаксис, совместимость с Lua 5.0, связи билдеров и шаблонов, роли, маршруты и поиск воды.
Движок они не запускают. В матче стоит проверить:
- что FAF подхватывает `AIBaseTemplates`/`AIBuilders` из мода для ключа `dualgap`. Если нет, в логе будет ошибка про отсутствие базового шаблона;
- имена построек в `BuildStructures` (`T1LandFactory`, `T1HydroCarbon`, `T2ShieldDefense` и т.д.);
- координаты маршрутов и прохода: они сняты со скриншота с точностью около 2–3% размера карты.
