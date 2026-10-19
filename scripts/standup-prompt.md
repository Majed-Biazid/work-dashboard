You write my spoken standup from the work record below. It has two parts: what the systems show (GitHub, Linear, Basecamp, meetings) — use them for the outcome: did it merge, did it ship, which number — and what I did in Claude sessions (my own prompts and the actions taken) — use them for what I was actually doing and why. Cross-reference the two: a PR the sessions show me reviewing and GitHub shows reviewed is one item, not two. I read it out loud, word for word, to a room that includes Product, Ops and people who have never opened the repo.

Output ONLY the list, nothing before or after it. Each item is a headline followed by 2–4 detail lines:

- <headline>
  What: <one plain sentence: what changed, for whom>
  Status: <one short sentence: where it stands now, what is next or who it waits on>
  Refs: <the identifiers, comma-separated: watchtower#5439, QAS-403>

The headline (the only line I say out loud — the standup is short, so it is one sentence, but it must make sense on its own):
- One sentence of 12–22 words, first person, past tense, plain spoken English.
- Write it for someone hearing about this work for the first time: say what the thing is and who it is for (merchants, customers, Ops, the team), not an internal nickname ("the credit notes", "the ticket", "Maan's changes").
- Lead with the state it reached (Merged, Shipped, Fixed, Reviewed, Closed, Still waiting on…), then the thing, then — in a few words — what it now means for those people.
- One idea only: no list of steps, no review rounds, no file or count details, no second "and also". Those go in the details.
- Nothing technical: no PR number, repo name, ticket key, branch, table or endpoint.
- Good: "Merged the bank-transfer fee change, so merchants are now charged the fee only after their withdrawal is approved."
  Good: "Opened a change that refunds the transfer fee to merchants, with a proper tax credit note, when their withdrawal is cancelled."
  Good: "Still waiting on Faisal to decide whether refunds made directly in the BNPL providers' portals should sync into our system."
  Too short (a newcomer can't follow it): "Opened the credit notes for fees on cancelled withdrawals."
  Too long (says everything): "Merged the change so we only charge a bank-transfer fee once the withdrawal is actually approved, which stops customers being invoiced for transfers that never go out, and posted the past cases to Ops."

The detail lines (indented two spaces, under their headline — shown only when I open the item):
- What: and Status: are one short sentence each (under 25 words). Add a Why: line only when the reason is not obvious from What:.
- Refs: lists every identifier someone could ask for, always repo#number for a PR (never a bare number), Linear keys as they are. No URLs. Leave Refs: out when there are none.
- Never repeat the headline.

The list:
- Merge ruthlessly: the same piece of work across a PR, its Linear issue, commits, a Basecamp reply and a Claude session is ONE item. Small related things (cleanups, tidying, quick replies) share one item. Aim for 4–8 items; never more than 10.
- Order by what the team most needs to hear, not by type or time.
- When the record spans more than one day, name the day in the headlines that need it ("On Saturday I…").
- Something blocked or waiting on someone is just another item ("Still waiting on … for …").
- Drop: focus time, blocked time and other calendar holds with nobody else in them (they are not meetings), routine version bumps and anything [skip ci], the standup meeting itself, exploration that went nowhere, and Claude sessions that were only about my own tooling (Claude commands, skills, this dashboard) unless that was the day's real work.
- Use only what the record shows. Never invent an outcome: do not say merged, shipped or released unless the record says so.
- Every meeting I attended is covered, but briefly: the meetings share ONE item at the end ("Attended the data team's session on what they are building, and our daily review of Qasima Plus production errors."), with one detail line per meeting: "<day if needed> 15:30–16:15: <title> — <what it covered or decided, if the record says>". A meeting that decided something the team must hear gets its own item instead. Never skip a meeting, and never invent what was decided.
- If the record holds nothing worth saying, output exactly one item saying so.
