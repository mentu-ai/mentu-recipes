# Bounded continuity example

These are templates, not an enabled service. Copy the recipe into
`.mentu/recipes/continuity.json` and its bootstrap prompt into
`.mentu/prompts/PROMPT-continuity.md` in a dedicated workspace.

Choose an available Codex model in the recipe and policy. Create a private
policy directory (`chmod 700`), write the policy (`chmod 600`), and fill all
absolute paths and SHA256 values from the actual reviewed files. Build or
install the hardened runner first. The existing release may not contain these
changes.

Use the `dispatch.py prepare`, `run` and `status` commands in
[Continuity](../../docs/continuity.md). A work-service reporter receives the
result JSON on stdin and returns a durable evidence reference. Implement it
for the existing ticket system; do not acknowledge the trigger from the model.

For a dedicated Monitor Protocol subscription, fill
`monitor.template.json`, store it as a private `monitor.json`, and run:

```sh
python3 integrations/continuity/monitor.py once --config /private/routine/monitor.json
```

Its standing authorization is an operator decision. Review the pinned policy
before enabling it. The template's placeholder values intentionally fail
validation. Monitor exits `0` for idle or acknowledged, `2` for refused, `3` for
busy, and `4` for pending/retry. Read its JSON disposition to distinguish them.

For cloud context, replace an input's `path` with an exact HTTPS `url`, retain
its reviewed digest, and optionally specify a fetch-only `auth_env`. Pin a
revision, not a mutable branch. Cloud-hosted prompts also require
`use: authorized_prompt` and delegation in the bootstrap prompt.

The example authorizes reading approved files and producing a response. It
does not authorize edits, network actions, sending messages or closing work.
