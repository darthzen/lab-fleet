---
name: mail-census
description: Count every mailing list in Rick's mailbox over a date window and write the result to a Google Sheet with a Keep column for him to mark.
mcp: workspace http://workspace-mcp.buzz.svc.cluster.local:8000/mcp tools=search_gmail_messages,get_gmail_messages_content_batch,create_spreadsheet,read_sheet_values,modify_sheet_values
---
The census runs in Gwen's host code, not through the model: the two tools below start it and ask for progress, and the whole walk (Gmail search, header batches, aggregation, sheet writing) happens deterministically inside Gwen. No message data crosses into a model round.

When to use it. Rick asks what mailing lists he is on, how much list mail he gets, or wants to see the lists and unsubscribe links in a spreadsheet he can mark up. It is not for one-off mail searches (that is the google-workspace skill) and not for sorting his inbox (email-triage).

Tools.
- `start_mail_census` — arguments: `days` (1-730, default 30), optionally `since` and/or `until` as `YYYY-MM-DD` (a partial window replaces `days`). Returns immediately with a job id; the walk runs in the background.
- `mail_census_status` — no arguments. Reports progress of the running census, or the finished summary with the sheet link.

Behaviour.
- The window is walked newest-first: Gmail is searched by message id in pages of 500, then headers are fetched in batches of 100 with `format=metadata`. A message counts as mailing-list mail iff its headers carry `List-Unsubscribe`.
- The sheet has one row per sender, sorted by count: Keep, Name, Address, Count, First seen, Last seen, Unsubscribe, Sample. Rick marks Keep; a rerun re-reads the sheet first, so his marks survive the rewrite.
- State lives in one file under Gwen's data dir (`mail-census.json`): a restart continues where it stopped, and a rerun over the same window is de-duplicated, so nothing is double counted.
- A census takes a while for a wide window (minutes for a few months of mail). Tell Rick it is running rather than making him wait; check `mail_census_status` when he asks.

After it finishes. Send Rick the sheet link and the headline numbers (messages scanned, list messages, senders). Do not describe his mail in detail — the sheet is the deliverable, and he reads it himself.
