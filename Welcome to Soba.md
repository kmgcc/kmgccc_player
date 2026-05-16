# Welcome to Soba

Soba is a minimal notes app for writing, thinking, AI help, and meeting notes.

## Start here

**Your vault**

- Your vault is just a folder of markdown files.
- You can point Soba at any local folder, including one inside iCloud Drive.
- Morning pages live in `Morning Pages`.
- AI conversations live in `.soba/conversations`.

**Notes**

- Create a note and start typing.
- Use Quick Switcher or Search when you want to move fast.
- Use tags in frontmatter or in the body to group notes across folders.
- Resize the three columns by hovering between them at the height of the note tabs. A slim divider will appear; drag it left or right to change the sidebar, editor, or AI panel width.

## Sidebar hierarchy

**Top-level folders**

- Morning Pages, Tags, Meetings, Notes, and smart folders are top-level sidebar sections.
- You can reorder and hide top-level sections in Settings -> Navigation.
- Smart folders are virtual top-level folders built from tags. They do not move files on disk.

**Regular folders**

- Regular folders are physical folders in your vault.
- Regular folders nest under the top-level Notes section.
- Right-click Notes and choose New Folder to add one, or use File -> New Folder.
- Right-click a regular folder to sort it or move it to the Trash.

**Smart folders**

- Open Settings -> Navigation -> Create Smart Folder.
- Give the folder a name and one or more comma-separated tags.
- Soba shows notes matching any of those tags immediately.
- Smart folders appear as top-level sections, so they sit beside Notes instead of inside it.

## Settings map

**General**

- Choose your vault folder.
- Open the vault in Finder.
- Set the folders used for AI conversations and morning pages.

**Typography**

- Pick fonts, weights, sizes, line height, and spacing for the app UI, notes, and AI panel.
- Adjust note title sizing and editor text density.

**Appearance**

- Customize AI panel colors, tag chip colors, and chat message indicator colors.

**Navigation**

- Reorder sidebar sections.
- Show or hide built-in top-level sections.
- Create smart folders from tags.
- Change sidebar note counts and section icon styles.

**Editor**

- Set editor width.
- Turn markdown highlighting support on or off.

**AI**

- Add OpenAI and Anthropic keys.
- Pick separate models for chat, summaries, and utility tasks.
- Control whether the active note is included as context.
- Enable background summarization.
- Add a Brave Search API key for higher-quality web search.

**Voice**

- Add an ElevenLabs key and voice ID.
- Turn voice transcription, transcript cleanup, and text-to-speech on or off.

**Sound FX**

- Turn action sounds on or off.
- Pick sound files for dictation, chat send, playback start, and playback stop.

**Granola**

- Connect Granola.
- Sync meeting notes into `Meetings`.
- Configure sync behavior and connection checks.

## Optional setup

- AI features: open Settings -> AI and add your OpenAI or Anthropic API key.
- Voice features: open Settings -> Voice and add your ElevenLabs key if you want transcription or read aloud.
- Web search: add a Brave Search API key in Settings -> AI if you want better web search inside Soba.
- Granola: open Settings -> Granola, connect your account, and turn on sync if you want meeting notes in the `Meetings` folder.

## Mac shortcuts

| Shortcut | Action |
| --- | --- |
| Cmd-N | New note |
| Shift-Cmd-N | New folder |
| Shift-Cmd-M | Today's morning page |
| Cmd-W | Close tab |
| Shift-Cmd-H | Highlight selection |
| Ctrl-Cmd-S | Toggle sidebar |
| Cmd-J | Toggle AI companion |
| Cmd-O | Quick switcher |
| Shift-Cmd-F | Search |
| Shift-Cmd-[ | Previous tab |
| Shift-Cmd-] | Next tab |
| Option-Cmd-B | Show backlinks |
| Shift-Cmd-R | Read aloud |
