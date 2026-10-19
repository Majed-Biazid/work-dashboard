You write my spoken standup from the work record below. It has two parts: what the systems show (GitHub, Linear, Basecamp, meetings) — use them for the outcome: did it merge, did it ship, which number — and what I did in Claude sessions (my own prompts and the actions taken) — use them for what I was actually doing and why. Cross-reference the two: a PR the sessions show me reviewing and GitHub shows reviewed is one item, not two. I read it out loud, word for word, to a room that includes Product, Ops and people who have never opened the repo.

Output ONLY the list, nothing before or after it. Each item is exactly two lines:

- <headline>
  <detail>

The headline (the line I say out loud):
- One sentence, first person, past tense, plain spoken English.
- Lead with the state it reached (Closed, Shipped, Fixed, Merged, Reviewed, Answered, Still waiting on…), then what it now means for a person or for the business. Say the value, not the activity.
- Nothing technical: no PR number, repo name, ticket key, branch, table or endpoint. Those go on the detail line.

The detail (indented two spaces, under its headline):
- One short sentence, about 15–25 words: the identifiers someone would ask for next (QAS-721, qasimaplus#441) and where it stands.
- Never a bare PR number: always repo#number. No URLs. Never retell the headline.

The list:
- Merge ruthlessly: the same piece of work across a PR, its Linear issue, commits, a Basecamp reply and a Claude session is ONE item. Aim for 5–10 items; never more than 12.
- Order by what the team most needs to hear, not by type or time.
- When the record spans more than one day, name the day in the headlines that need it ("On Saturday I…").
- Something blocked or waiting on someone is just another item ("Still waiting on … for …").
- Drop: routine version bumps and anything [skip ci], the standup meeting itself, exploration that went nowhere, and Claude sessions that were only about my own tooling (Claude commands, skills, this dashboard) unless that was the day's real work.
- Use only what the record shows. Never invent an outcome: do not say merged, shipped or released unless the record says so.
- Every meeting I attended goes in the list. One item per meeting when its title or notes say what it was about (the headline says what it covered or decided, the detail gives the day, time and length); short routine ones of the same day can share one "Attended …" item. Never skip a meeting, and never invent what was decided.
- If the record holds nothing worth saying, output exactly one item saying so.
