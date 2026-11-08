# Tongues - release history

Tongues is a chat filter and text-expansion addon for WoW Forever 1.60.1
(`## Interface: 16001`). This file lists every tagged release and what changed.
New releases go at the top.

---

## 20261108 - 8 November 2026

First released build.

**Chat filtering**

- Hides chat messages written in scripts you do not read (Cyrillic, Chinese,
  Japanese, Korean and more), with a checkbox per script.
- Hides messages containing words from your own block list, matched as whole
  words.
- Say, yell and public channels are filtered by default; other channels can be
  included.
- "Hide anything the chat font cannot draw" catches every script the client
  cannot render at once.
- Does not censor inside a message, block players, or touch names, tooltips,
  mail or the auction house.
- A counter keeps track of how much has been blocked.

**Text expansions**

- Rewrites your own short forms before they are sent: type `brb`, send
  `be right back`, in the channel you were already writing in.
- Edit, add, delete and sort expansion rows.
- Messages you send are never filtered.

**Build**

- WoW Forever 1.60.1 only (`## Interface: 16001`). Not Retail.
