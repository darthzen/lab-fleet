---
name: daily-briefing
description: One Telegram message each morning with today's events, mail that needs Rick's reply, and tasks due.
---
What it is. One Telegram message, sent each morning to Rick. Short. Bullets. Three sections: Today, Needs you, Tasks. No greeting, no sign-off, nothing invented. An empty section says "nothing".

How it is scheduled. Create it with `schedule_create`:

- name: `daily-briefing`
- cron: Rick chooses. Default `0 7 * * 1-5` in America/Chicago (weekdays at 7:00).
- prompt: the exact text below. The fired turn sees only that text plus conversation history, so it must be complete.

The prompt to store:

> Load the daily-briefing skill and follow it.

Procedure when it fires:

1. Load the google-workspace skill.
2. **Today.** `get_events` for today on `rick@theashfords.org` in America/Chicago. List each event with its time and location. If there are none, the section says "nothing".
3. **Needs you.** Per the email-triage sort, find unread inbox mail from the last 24 hours that needs Rick's reply. At most five. One bullet each: sender — what they want — deadline if any.
4. **Tasks.** Tasks due today or overdue. Once a todoist skill exists, use it. Until then, this section says "Todoist not connected yet".

Format. Short. Bullets. Three sections in this order:

```
Today
- 9:00–10:00 Standup — Zoom link in invite

Needs you
- Dana K. — wants the Q4 numbers by Friday

Tasks
- Todoist not connected yet
```

If a tool fails, the briefing still goes out. Name what failed in the section it belongs to, e.g. "Calendar: get_events timed out".
