# Readout

Point your phone camera at a question and hear the answer.

Live camera feed. Move to a question and hold still: Readout reads the question, then each part and its answer, out loud. Once per question.

- Reads in order: question, part a, answer, part b, answer. Repeats read just the part labels and answers
- Dictation-style voice: slow by default, one line at a time with pauses, math spoken the way a teacher reads it
- Optional Google HD voice (Chirp 3 HD) with your own Google API key; repeats replay saved audio, and a monthly cap keeps it in the free tier
- Waits until it's done reading before scanning the next page
- Replay line, pause, skip, stop, speed, mute, volume, sound cues, extra instructions, saved answers

## Use it

Open https://whereami-toaa.github.io/readout/ on your phone.

- iPhone: Safari > Share > Add to Home Screen
- Android: Chrome > menu > Install app

First run: tap the settings icon, paste an Anthropic API key from console.anthropic.com/settings/keys, pick a model, tap Done, allow camera access.

The key is stored only on your phone and sent only to api.anthropic.com. Set a monthly spend limit in the Anthropic Console.
