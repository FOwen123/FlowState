# English native control acceptance

Pending live acceptance for the intent-recognition implementation. Use disposable TextEdit documents and a synthetic public page in Brave; never operate private messages, passwords or purchasing flows as a test.

Record commit, Mac/OS, configured models/policy version, grants, transcription, inferred intent, actual effect, latency and required physical interventions. A correct classification alone is not successful execution.

| Control | Positive case | Failure/recovery case |
|---|---|---|
| Open/switch app | Open a closed permitted app; switch back | Missing app; app opening not granted; duplicate names |
| Scroll | Up/down in an approved scrollable window | At boundary; no scrollbar; focus changed; horizontal unsupported if not implemented |
| Focus | Focus a uniquely labeled permitted editor | Duplicate label; stale target; protected field |
| Select | Select a uniquely identified selectable control | Non-selectable target; target disappeared |
| Press/key navigation | Tab, Shift-Tab, arrows, Home/End/Page keys where supported | Unsupported key/modifier; permission denied; stale focus |
| Dictation | Insert ordinary prose and literal “open Brave” | No editor; secure field; focus changes during inference |
| Edit/correction | Explicit replacement with reviewed current selection | Content changed; quoted command remains literal text |
| Undo | Restore the last verified text edit | Intervening edit; different target; irreversible effect |
| Stop/cancel | Stop during capture, inference, capture upload and execution | Late response and duplicate transcript cause no further action |
| Resume | Explicitly resume after rechecking target | Expired/revoked grant; no implicit resume on a network reply |
| Visual target | Approved synthetic window with current target evidence | Screenshot denied; upload not allowed; moved/closed window; ambiguous button |
| Compound request | Permitted bounded steps, verified in order | Failed middle step stops continuation; unsupported step explains limitation |
| Service effects | Dry-run send/upload/delete approval and exact argument binding | Real sending/deletion/purchasing is not authorized by this test |

1. Exercise fresh English settings and upgrade from legacy language preferences; existing Unicode drafts/history remain intact.
2. Activate Auto mode. Say a command and pause; no Finish click should be necessary. Verify multiple utterances within toggle/wake sessions without duplicate execution.
3. Try fillers, partial hypotheses, corrections and pauses inside quoted commands. Record false endpoints rather than excluding them from results.
4. Repeat relevant cases offline, signed out, after physical takeover and after permission revocation. Local Stop remains available.
5. Verify visible Listening/Understanding/Acting/Completed or clarification/error states. Capture only the synthetic app window for evidence.
