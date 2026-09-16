# Mixture-of-Experts Life Coach — Implementation Plan

**Goal:** a single voice-first "Life Coach" on the hub page that routes user intent to
domain experts (Tasks, Workout, Budget) and speaks the result back. The user should be
able to run the whole app by talking.

**Current state (done):**
- Tasks expert — `backend/routers/agent.py`, modes `planning` / `todo`.
- Workout expert — `backend/routers/workout_agent.py`, mode `workout_coach`.
- Voice already exists inside `shared/widgets/agent_chat_panel.dart` (`speech_to_text`
  push-to-talk + `flutter_tts` read-back), but it is per-panel and turn-based.

---

## Phase 0 — Consolidate the shared agent runtime

The LLM plumbing (runtime resolution, BYO-key, spend cap, retry, `/responses` vs
`/chat/completions`, attachments, conversation compression) currently lives as private
helpers inside `routers/agent.py`, and `workout_agent.py` imports them. That is fine for
two experts and will not scale to four.

- [ ] Extract into `backend/llm_core.py`: `call_llm_message`, `resolve_runtime_for_user`,
      `spend_cap_usd`, `total_spend_usd`, `estimate_cost_usd`, `summarize_history`,
      attachment processing, encryption helpers.
- [ ] Define an `Expert` protocol: `name`, `description`, `system_prompt()`,
      `context(session, user_id)`, `tools_schema()`, `execute(name, args, ...)`,
      `read_only_tools`, `destructive_tools`.
- [ ] Re-express the tasks and workout agents as `Expert` implementations. Existing
      endpoints keep working — they become thin wrappers over a generic
      `run_expert_turn(expert, messages, ...)`.

**Why first:** every later phase depends on being able to invoke an expert
programmatically rather than over HTTP.

---

## Phase 1 — Budget expert

- [ ] `backend/routers/budget_agent.py` with tools over `Account` / `BudgetGoal`:
      `list_accounts`, `get_safe_to_spend`, `set_balance`, `create_goal`, `update_goal`,
      `project_goal_completion`.
- [ ] Same approval gate pattern as the workout coach (money = always confirm writes).

This gives three experts, which is the minimum for the router to be worth building.

---

## Phase 2 — The orchestrator (mixture of experts)

**Architecture: LLM-as-router with experts exposed as tools.** Each expert becomes a
single tool on the orchestrator (`ask_tasks_expert`, `ask_workout_expert`,
`ask_budget_expert`), taking a natural-language instruction plus optional structured
hints. The orchestrator does *not* get the experts' individual tools — that would blow
the context window and lose each expert's specialised prompt.

```
user speech ──▶ STT ──▶ Life Coach (orchestrator LLM)
                          │  ask_workout_expert("build a 3x/week push-pull-legs routine")
                          │  ask_tasks_expert("what's due today?")
                          │  ask_budget_expert("can I afford a gym membership?")
                          ▼
                 expert turn (own prompt + own tools + own memory)
                          ▼
                  structured result + short summary
                          ▼
             Life Coach composes one spoken reply ──▶ TTS
```

- [ ] `backend/routers/life_coach.py`, `POST /life-coach/chat`.
- [ ] Orchestrator system prompt: decide which expert(s) to consult, may consult several
      in parallel, may re-ask an expert with clarification, never invents domain facts,
      always answers in one short spoken-friendly paragraph.
- [ ] Expert-tool arguments carry a `require_approval` flag that the orchestrator
      propagates. Destructive proposals bubble all the way up to one combined approval
      sheet in the UI.
- [ ] Conversation memory: one `LLMConversation` row with `mode="life_coach"` for the
      orchestrator, plus each expert keeps its own thread. Pass a short shared
      "user profile" summary (goals, constraints, preferences) into every expert so the
      coach doesn't have to repeat context on each hand-off.
- [ ] Budget guard: cap total expert hops per user turn (e.g. 4) and total tool
      iterations per expert (already 8) so one sentence can't cost a fortune.

**Cost note:** nested agents multiply tokens. Use a cheap/fast model for the
orchestrator and the stronger model inside experts; make this configurable via
`LLM_ORCHESTRATOR_MODEL`.

**Alternative considered:** an embedding/keyword classifier to pick one expert. Cheaper
and lower latency, but cannot handle multi-domain requests ("move my gym session because
I have a deadline"), which is the whole point. Keep the classifier as an optional
fast-path optimisation later.

---

## Phase 3 — Shared user profile

Cross-cutting facts (goals, injuries, schedule constraints, working hours, risk
tolerance) should not live in three separate conversation summaries.

- [ ] `UserProfile` table: JSON of coach-maintained facts, plus `updated_at`.
- [ ] Orchestrator tools `read_profile` / `update_profile`.
- [ ] Injected read-only into every expert's context block.

---

## Phase 4 — Voice

Voice already works turn-by-turn in `AgentChatPanel`. To make it feel like *talking*:

- [ ] **Extract** the STT/TTS logic out of `AgentChatPanel` into
      `shared/services/voice_service.dart` so both the panel and the life-coach screen
      share one implementation and one set of permissions.
- [ ] **Hands-free mode:** continuous listening with silence detection (end-of-utterance
      after ~1.2s of quiet) instead of push-to-talk, auto-send, auto-speak the reply,
      then resume listening. Add a visible listening/thinking/speaking state indicator.
- [ ] **Barge-in:** stop TTS as soon as the mic picks up speech.
- [ ] **Wake word** (optional, later): "Hey Coach" via `porcupine_flutter`. On-device
      device-side STT (`speech_to_text`) is free but mediocre; if quality is a problem,
      add a server-side Whisper endpoint (`POST /voice/transcribe`) as a fallback.
- [ ] **Better TTS** (optional): server-side neural TTS endpoint returning audio, with
      `flutter_tts` as the offline fallback.
- [ ] **Prompt for speech:** all expert and orchestrator prompts must forbid markdown,
      tables, and lists in spoken replies, and keep replies under ~3 sentences unless
      asked to elaborate. The workout coach prompt already does this.

**Latency is the make-or-break factor.** Target <2s from end-of-speech to first audio.
That means streaming the orchestrator's reply and starting TTS on the first sentence,
rather than waiting for the full tool loop. Plan to add SSE streaming to
`/life-coach/chat` in this phase.

---

## Phase 5 — Hub UI

- [ ] Replace the hub tile grid with a large mic button + transcript view; keep the three
      app tiles below as manual navigation.
- [ ] `LifeCoachScreen` reusing `AgentChatPanel(fillHeight: true)` in hands-free mode.
- [ ] Show which expert is being consulted ("asking your workout coach…") so the wait
      feels intentional.
- [ ] One approval sheet listing every proposed change across all domains, grouped by
      expert, with destructive items flagged.
- [ ] Deep-link: tapping an action result jumps to the relevant screen.

---

## Risks / open questions

| Risk | Mitigation |
|---|---|
| Token cost of nested agents | Cheap orchestrator model; hop cap; aggressive context trimming |
| Latency kills the voice UX | Stream replies; start TTS on first sentence; parallel expert calls |
| Orchestrator picks the wrong expert | Rich tool descriptions; let it consult two and reconcile; log routing decisions |
| Experts contradict each other | Shared `UserProfile` is the single source of truth for cross-cutting facts |
| Accidental destructive changes by voice | Approval on by default for voice; destructive tools always require explicit spoken confirmation |
| Mic permissions / browser support | Feature-detect; fall back to text input silently |

---

## Suggested order

1. Phase 0 (refactor) — unblocks everything, no user-visible change.
2. Phase 4 voice-service extraction + hands-free mode on the **existing** workout coach.
   Ships a usable "talk to your trainer" feature before the orchestrator exists.
3. Phase 1 budget expert.
4. Phase 2 orchestrator + Phase 3 profile.
5. Phase 5 hub UI + streaming.
