# Pacing

How long each word stays on screen, and why. Labels: **study** means the number or direction comes
from the cited source (opened during the 2026-10-19 research pass); **choice** means a value we
picked, informed by the sources but not measured by them.

## The rule

```
seconds(token) = base × word slots + pause scale × max(base × pause slots, pause floor)
```

**Real speed (default).** `base` is solved so that reading the whole text, from the first flash to
the last, pauses and ease-in included, takes exactly words / wpm minutes: 500 wpm means 500 words
read per minute. The words therefore run faster than the setting to make room for the pauses (at
most 2.5 times faster); on text so dense with sentence and line ends that this is not enough, the
pauses shrink instead (pause scale below 1). The solve runs from wherever reading starts or
resumes, flash by flash, and honours the display's minimum flash of 2 frames; where a text cannot
reach the speed even then (long identifiers split into pieces on a 60 Hz screen), the reader shows
the real maximum instead of the setting. A unit test reads four kinds of text at speeds 100 to
1500, pause settings 0 to 2, adaptive pacing on and off, every grouping mode, from the start and
from half way, with exact timing and through the frame stepping of 60 Hz and 120 Hz displays, and
requires the measured rate to be within 1% (exact) or 2% (frames) of what the reader shows; a live
test on the display does the same at 1000 wpm.

**Word-only speed** (Settings, "Speed is real reading speed" off): `base = 60 / wpm` and pauses
add time on top, so the real rate is lower than the setting (on one 321-word list-heavy text,
377 wpm at a setting of 500).

Then × an ease-in over the first 5 flashes after starting or resuming: 1.8, 1.64, 1.48, 1.32,
1.16, then 1. After a jump while playing (← →) only the last two steps (1.32, 1.16) apply.

### Word slots (adaptive pacing, the default)

Per source word, before normalising:

| Term | Value | Basis |
|---|---|---|
| frequency | 0.08 × (5 − Zipf), clamped to −0.2 … +0.28; unknown words count as Zipf 1.5 | **study**: gaze duration falls about 20 ms per tenfold rise in frequency, 292 → 214 ms across Schilling's (1998) bands, as tabled in Reichle et al. (2009, the E-Z Reader 10 paper). The 8%-per-unit scaling to RSVP and the clamp are a **choice**. |
| repetition | a rare word's frequency extra is halved after its first occurrence in the text | **study** (direction): rereading speeds fixations, additively with frequency (Raney & Rayner 1995). Halving is a **choice**. |
| length | +0.04 per letter past 6, at most +0.40, per displayed piece | **study**: 2 to 5 ms per letter when a word is fixated, 9 to 11 ms with skipping counted, frequency held equal (Rayner, Slattery, Drieghe & Liversedge 2011). 0.04 is a **choice** in that range. |
| numbers | 0.15 per significant digit, at most 1.2; trailing zeros dropped; a four-digit year (1000 to 2099) counts as two | **study** (direction): more digits cost more, round numbers less (de Chambrier et al. 2023; 2025). Magnitudes are a **choice**. |
| connectives | +0.3 for if, because, although, though, unless, therefore, however, whereas, since | **study**: Castelhano & Muter (2001) doubled the time on "if", "because", "after" and "although" in their preferred "modified RSVP" (its parts were not tested separately). We leave out "after" (mostly a plain preposition); the rest of the list and 0.3 are a **choice**. |
| links | +0.4 | **choice** |
| spillover | +30% of the previous token's extra slots (frequency and length together; only when positive; for a split word, its last piece's share) | **study** (direction): predictability effects spill onto the next word (Smith & Levy 2013). 30% is a **choice**. |

The word slots are then divided by their mean over the document, so adaptive pacing only moves
time between words and never changes the total: hard stretches slow down, easy ones speed up, in the spirit of Öquist &
Goldstein's (2003) adaptive RSVP, which normalised to an average chunk the same way. On a test
paragraph (38 words mixing a year, a four-digit count and biology terms, in the 2026-10-19 probe)
the slots ranged 0.71 to 1.44. In Öquist's most variable mode readers still reported
more time pressure than on the page, which he put down to exposure times varying too much.

### Pauses (not normalised: they add time)

| After | Slots | Floor |
|---|---|---|
| comma, semicolon, colon, dash | 0.5 | none |
| a line the writer broke on purpose | 0.7 | none |
| sentence end | 1.2 | 200 ms |
| paragraph end | 2.0 | 400 ms |

Pauses at punctuation were the one change readers liked in Castelhano & Muter (2001, Exp. 1).
Floors: 200 to 1000 ms between sentences helped in the RSVP studies those authors and Öquist
review (Masson 1983); the time to wrap up a sentence does not shrink with speed. All pause slots
scale with the "Pause at punctuation" slider (0 to 2). The floors scale with it up to 1 and stay
at 200 / 400 ms above that (at 0.5 they are 100 / 200 ms; at 0 they are off).

With adaptive pacing off, words get 1 slot, plus, when "Extra time for long words, numbers and
links" is on: +0.08 a letter past 6 (at most +0.6), +0.25 for a token of 3 or more characters
containing a digit, +0.4 for links.

## What the studies say about RSVP itself

- Comprehension: literal comprehension was 60% with Spritz against 72% on the page (Benedetto et
  al. 2015, 60 readers, 250 wpm nominal); static text beat RSVP at 700 and 1,000 wpm (Acklin &
  Papesh 2017); a review concludes readers are unlikely to double or triple their speed "while
  still being able to understand the text as well" (Rayner et al. 2016).
- The main cost is that the eyes cannot go back: blocking regressions hurt comprehension
  (Schotter, Tran & Rayner 2014). That is what ← (back to the sentence start) and the paused
  context view are for.
- Fewer blinks with Spritz (4.7 vs 8.5 a minute, Benedetto et al. 2015): close it and look away on
  long texts.

## Sources

- Öquist & Goldstein 2003, *Interacting with Computers*: https://academic.oup.com/iwc/article-lookup/doi/10.1016/S0953-5438(03)00039-0
- Öquist 2006, dissertation (algorithm details): https://smartlib.umri.ac.id/assets/uploads/files/8572d-relev-res.pdf
- Castelhano & Muter 2001: https://web.archive.org/web/2015id_/http://cogprints.org/1934/3/castelhano_muter2001.pdf
- Benedetto et al. 2015 (Spritz): https://tsw.r.worldssl.net/wp-content/uploads/Rapid-serial-visual-presentation-in-reading-The-case-of-Spritz-1.pdf
- Rayner, Schotter, Masson, Potter & Treiman 2016: https://doi.org/10.1177/1529100615623267
- Schotter, Tran & Rayner 2014: https://doi.org/10.1177/0956797614531148
- Acklin & Papesh 2017: https://doi.org/10.5406/amerjpsyc.130.2.0183
- Reichle et al. 2009 (E-Z Reader 10): https://pmc.ncbi.nlm.nih.gov/articles/PMC2629133/
- Rayner, Slattery, Drieghe & Liversedge 2011: https://pmc.ncbi.nlm.nih.gov/articles/PMC3543826/
- Smith & Levy 2013: https://pmc.ncbi.nlm.nih.gov/articles/PMC3709001/
- de Chambrier et al. 2023: https://doi.org/10.1016/j.actpsy.2023.103942 ; 2025: https://doi.org/10.1016/j.actpsy.2025.106062
- Raney & Rayner 1995: https://doi.org/10.1037/1196-1961.49.2.151
- Word frequencies: hermitdave/FrequencyWords, OpenSubtitles 2018, `en_50k.txt` (CC BY-SA 4.0): https://github.com/hermitdave/FrequencyWords
