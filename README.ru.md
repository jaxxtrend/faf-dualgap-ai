# faf-dualgap-ai

[English](README.md) · **Русский**

Мод ИИ для **Supreme Commander: Forged Alliance Forever (FAF)** под карту **Dual Gap Adaptive v14** (6 на 6).
Каждый бот определяет роль по своему спавну и играет её: **GROUND** (мид по земле), **NAVAL** (вода), **AIR** (авиация) или **ECO** (экономика и гейм-эндеры).

Что умеет: строгий дебют по билд-ордеру, «свои» мексы с разделом мексов погибшего союзника, разведка с общей памятью команды,
волны строем и патрули вдоль фронта, прокси-база на миде, T4 по условиям роли, общая ПРО на трёх игроков и ответ на замеченные гейм-эндеры.

## Видео
Тестовый матч с ботами DualGap AI: https://youtu.be/36RrrPkwhb8

[![Тестовый матч DualGap AI](https://img.youtube.com/vi/36RrrPkwhb8/hqdefault.jpg)](https://youtu.be/36RrrPkwhb8)

## Установка
1. Скопировать папку [`mods/DualGapAI`](mods/DualGapAI) в
   `%USERPROFILE%\Documents\My Games\Gas Powered Games\Supreme Commander Forged Alliance\mods\`.
   Папка должна называться именно `DualGapAI`.
2. В лобби FAF включить мод **DualGap AI** и поставить ботов **AI: DualGap** или **AIx: DualGap** на карте Dual Gap Adaptive v14.

Подробно про роли, билд-ордер и настройки — в [mods/DualGapAI/README.md](mods/DualGapAI/README.ru.md).
Билд-ордеры и таблицы производства правятся в [DualGapBuildOrders.lua](mods/DualGapAI/lua/AI/DualGapBuildOrders.lua),
координаты и пороги — в [DualGapConfig.lua](mods/DualGapAI/lua/AI/DualGapConfig.lua).

## Тесты
Офлайн, без игры (нужен Python 3 и `pip install lupa`):

```bash
python tests/run_tests.py
```

Тесты проверяют синтаксис и совместимость с Lua 5.0, пути импорта и ссылки между модулями, роли и владение мексами на реальных маркерах карты,
решения командира, правила производства и прогоняют весь дебют на мини-симуляции.

`tools/map_markers.py` выводит маркеры карты из `*_save.lua`, он пригодится для калибровки координат.
