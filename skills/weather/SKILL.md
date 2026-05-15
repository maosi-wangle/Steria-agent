---
name: weather
description: Get current weather and forecasts (no API key required). 含节假日与调休查询。触发词：天气, 查天气, 天气预报, 节假日, 调休, 今天放假吗, 查假期
homepage: https://wttr.in/:help
metadata: {"akashic":{"emoji":"🌤️","requires":{"bins":["curl"]}}}
---

# Weather

Two free services, no API keys needed.

## wttr.in (primary)

Quick one-liner:
```bash
curl -s "wttr.in/London?format=3"
# Output: London: ⛅️ +8°C
```

Compact format:
```bash
curl -s "wttr.in/London?format=%l:+%c+%t+%h+%w"
# Output: London: ⛅️ +8°C 71% ↙5km/h
```

Full forecast:
```bash
curl -s "wttr.in/London?T"
```

Format codes: `%c` condition · `%t` temp · `%h` humidity · `%w` wind · `%l` location · `%m` moon

Tips:
- URL-encode spaces: `wttr.in/New+York`
- Airport codes: `wttr.in/JFK`
- Units: `?m` (metric) `?u` (USCS)
- Today only: `?1` · Current only: `?0`
- PNG: `curl -s "wttr.in/Berlin.png" -o /tmp/weather.png`

## Open-Meteo (fallback, JSON)

Free, no key, good for programmatic use:
```bash
curl -s "https://api.open-meteo.com/v1/forecast?latitude=51.5&longitude=-0.12&current_weather=true"
```

Find coordinates for a city, then query. Returns JSON with temp, windspeed, weathercode.

Docs: https://open-meteo.com/en/docs

## 节假日与调休查询 (xiaoai.me)

Free API, no key, 支持查询中国法定节假日、调休补班。

查询某一天：
```bash
curl -s "https://publicapi.xiaoai.me/holiday/day?date=2026-05-01"
```

查询某个月：
```bash
curl -s "https://publicapi.xiaoai.me/holiday/month?date=2026-05"
```

查询全年：
```bash
curl -s "https://publicapi.xiaoai.me/holiday/year?date=2026"
```

返回关键字段：
- `daytype`: 0=工作日, 1=节假日, 2=双休日, 3=调休日
- `holiday`: 节假日名称（如"国庆节"、"工作日"）
- `rest`: 0=不休息, 1=休息
- `week_desc_cn`: 星期（中文）
- `date`: 日期

示例 - 查今天（2026-05-11 周一）：
```json
{"daytype":0, "holiday":"工作日", "rest":0, "date":"2026-05-11", "week":1}
```

注意：小假期（如清明、中秋）期间 daytype=1 和 rest=1，调休补班的周六日 daytype=3 且 rest=0。
