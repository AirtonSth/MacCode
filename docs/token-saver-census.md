# Token Saver census export (task-03)

Shadow-only opportunity measurement keyed by full `TokenSaverBindingID`.

## Rules

- **No payload mutation.** Provider-visible bytes are unchanged by census.
- **Content-free.** Export contains digests, counts, rates, controls — never tool output text.
- **No savings fields.** Export must not include tokens-saved / confirmed / estimated headline keys.
- **Cross-user:** observations with `isSameUser == false` are dropped (raw-only Token Saver).
- **Gate -1:** aggregates with `absolute_eligible_tokens == 0` have `valid_for_gate: false` and `rank_by_absolute_volume: null` (top-ranked without absolute volume does not pass).

## Controls

| Value | Meaning |
|-------|---------|
| `no_change` | Baseline without wrappers/native reduction |
| `wrappers` | Local wrapper path eligible |
| `provider_native` | Provider-native capability eligible when proven |

## JSON schema (v1)

```json
{
  "schema": "token-saver-census-v1",
  "observation_count": 0,
  "aggregates": [
    {
      "binding_digest": "64-char hex",
      "absolute_eligible_tokens": 0,
      "observation_count": 0,
      "parser_match_rate": 0.0,
      "controls": ["no_change"],
      "rank_by_absolute_volume": null,
      "valid_for_gate": false
    }
  ]
}
```

## API

- `TokenSaverCensusStore.record(_:)` — same-user + complete BindingID only
- `TokenSaverCensusStore.aggregates()`
- `TokenSaverCensusStore.exportJSON()`
- `TokenSaverCensusStore.providerVisiblePayloadUnchanged(_:)` — identity for mutation proofs

See `plan/tasks/task-03.html`.
