# Tongues

Tongues is a WoW Forever addon that does 3 things.

1. It hides chat messages written in scripts you don't read

2. Hides chat messages that contain words you never want to see again. 

3. Rewrites your own short forms before they are sent, similar to "Text Replacement" on iPhone and "Text shortcuts" or "Personal dictionary" or Android devices.

Only the kinds of chat you tick are filtered: Say, Yell, General, Trade, Other
channels (all), Raid, Instance, Party, Guild and Whispers. 

Say, yell and the public channels start ticked, the personal ones
stay off until you ask for them. Your own messages are never hidden.

It does not censor words inside a message, does not block players, and cannot
take back a message that has already appeared. It filters chat text, not names,
tooltips, mail or the auction house. 

A script your client's font cannot draw will appear in chat as boxes, it is still classified and hidden by its own checkbox, and the "Hide anything the chat font cannot draw" box catches all of
them at once. 

Example of unreadable script (supposed to be arabic): <img width="296" height="30" alt="{C71B404D-BC07-4D3B-BC3C-B35B36FF37E0}" src="https://github.com/user-attachments/assets/897a1ccd-c332-4076-ade3-c9aae9c6e64c" />

Note hidden messags are still sent, everyone else can see them.

## Examples

**Options window**

<img width="593" height="2388" alt="tongiessettingsfull" src="https://github.com/user-attachments/assets/4023b332-8c37-4f6e-adfd-76b457d82418" />

**Blocked words window** 

<img width="469" height="541" alt="{C7D6B239-27FC-4A11-8343-39C39E3C6BAB}" src="https://github.com/user-attachments/assets/0f6a45a9-76b6-4971-ac28-72dc5942edc1" />

**Text expansions window** — edit a row, save it, or add a new one; sort the list
to taste.

<img width="558" height="253" alt="{5D0CF54C-1FB3-4BBD-98AD-EE1322776D1D}" src="https://github.com/user-attachments/assets/a557410e-b67d-4e37-943e-bfb5c3f89223" />

<img width="570" height="550" alt="{D00E0C47-3D08-459C-8062-88F8332CCE45}" src="https://github.com/user-attachments/assets/7b68c582-bc05-4065-887d-6f994b486fa8" />

<img width="81" height="52" alt="{7D703389-9E74-44DF-B732-E4F16D58E5D5}" src="https://github.com/user-attachments/assets/5510013e-2414-42a9-8e74-d96ba5472fcb" />

Note the test character is called Tongues

<img width="247" height="26" alt="{5162640D-D7E8-4165-9015-9C4A181A0376}" src="https://github.com/user-attachments/assets/021fb973-f7ad-433d-999a-2dd8bcc02c12" />

**Login line**

<img width="293" height="27" alt="{36AC479E-D3B3-4793-92B8-93EAF1C30EE6}" src="https://github.com/user-attachments/assets/911e65aa-bb9f-4caa-82b7-6fbe74caad87" />

## How it works

Tongues reads chat through the chat system's message-event filters: one small
function per chat event, called for every incoming message, returning true to
hide it. Messages are walked as UTF-8, one character at a time, so scripts can
be told apart and each counter can name the right one. The block list checks
whole words in the lowered message, with chat colour codes stripped and link
payloads masked so a numeric block entry cannot hide every item whose ID
contains it.

Expansions happen in the client's own "this line is about to be sent" callback.
By the time it runs the client has already worked out the channel and target, so
only the text is replaced and the line still goes exactly where it was headed.
If an expansion would push the line past 255 bytes, the text you typed is sent
unchanged. (Up to 255 characters)

Settings, counters and the block and expansion lists live in `TonguesDB` and
survive login and reload. There are no libraries and no dependencies.

### Available commands

```text
/tongues                     open the options
/tongues words               the blocked words window
/tongues expansions          the text expansions window
/tongues expand brb = be right back
/tongues unexpand brb
/tongues on | off | toggle
/tongues counters
/tongues resetcounters
/tongues test <text>         dry run: would this line be hidden, and why
/tongues reset               put the minimap icon back
/tongues help
```
