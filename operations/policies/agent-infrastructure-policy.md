# Agent Infrastructure Policy

## Overview

This policy defines what AI agents are permitted to do with the DhanMan
infra-verify check engine (`operations/infra-verify/`) and repair scripts
(`operations/repairs/`).

**KEY PRINCIPLE: Agents analyze and recommend only. They never execute
repairs, modify infrastructure, or bypass human approval gates.**

The human approval boundary is the typed confirmation inside each repair
script itself (`repair_confirm` in `operations/repairs/lib/repair-common.sh`)
— even if an agent suggests a repair, the human operator must type a
confirmation phrase (QA: `yes`; PROD: the exact phrase `PROD REPAIR <target>
<YYYYMMDD>`). An agent must never construct, script, or feed that phrase to
a repair script's stdin on a human's behalf — doing so defeats the entire
purpose of the gate, which exists specifically to require a human physically
present and reading the prompt.

## Allowed actions (agents may do these)

1. **Read reports and audit trails**
   - Parse JSON/HTML reports from `/opt/infra-verify/history/` (deployed
     hosts) or `operations/infra-verify/history/` (local dev, per
     `docs/operations/LOCAL-TEST-GUIDE.md`)
   - Read the JSONL audit trail from `/var/log/dhanman/infra-audit/`
     (both the check engine's audit log and, once repair scripts are
     deployed, `repairs.jsonl`)
   - Extract check results, service status, and layer verdicts
   - Understand which checks passed/failed and why

2. **Analyze findings**
   - Correlate results across check families (`SVC`, `HLT`, `LOG`, `PT`,
     `LK`, `PM`, `GF`) using each result's `likely_layer` field
   - Explain the causal chain (e.g. "Promtail down → Loki discarding
     samples → Grafana panels empty")
   - Surface the `overall_status` rollup and per-check `status`

3. **Recommend approved repair scripts — only when one actually exists**
   - Look up the finding's `check_id` in the command catalogue
     (`operations/policies/agent-command-catalog.yaml`)
   - **Before naming a script, confirm it exists on disk.** Several
     check families set a `repair` field in their result that points to a
     script that was never built (see "Known gap" below) — an agent must
     never recommend a path it hasn't verified exists.
   - When a real script exists: state its exact path, describe its
     `SCOPE_ONE_TARGET` (what it will touch, and nothing else), and walk
     the operator through the confirmation step they'll be asked for.
   - When no real script exists for a finding: say so explicitly and
     follow the escalation path below — do not invent a plausible-sounding
     command.

4. **Explain the system to humans**
   - Answer questions about how infra-verify and the repair scripts work
   - Explain why a check failed or why a particular repair is recommended
   - Explain the confirmation process for a repair (and why it exists)
   - Suggest read-only diagnostic steps (e.g. "SSH to QA and run
     `systemctl status dhanman-purchase-qa`")

5. **Run catalogued read-only commands**
   - Issue commands from the `read_only_commands` section of the catalogue
   - Never invent commands; only use catalogued ones, or well-understood
     read-only inspection commands (`systemctl status`, `journalctl`,
     `docker inspect`, `cat`/`jq` on a report file) when nothing in the
     catalogue covers the question

## Prohibited actions (agents must NOT do these)

**Execution:**
- Execute any repair script (mutating or diagnostic) without a human
  present and typing the confirmation themselves
- Run any `systemctl`/`docker` restart, start, or stop command directly
- Modify any file under `/etc`, `/opt/monitoring`, `/opt/infra-verify`,
  `/var/www`, or any Ansible-managed path
- Change permissions (`chmod`, `chown`) on any managed path
- Run Ansible playbooks or any deployment tool
- Access the database directly
- Push to git or otherwise modify version control on `dhanman-infra`
  without the human explicitly asking for that specific change

**Information leakage:**
- Output unredacted audit JSONL — redact anything that looks like a
  credential before showing it (this mirrors what
  `operations/infra-verify/lib/report.sh`'s own secret-scanning already
  does for the report itself)
- Copy/paste raw log lines containing credentials
- Construct shell commands by directly interpolating unsanitized
  user-supplied input (injection vector) — this is the same discipline
  the repair scripts themselves follow (e.g.
  `restart-one-specific-service.sh` validates the unit name against a
  strict regex before it ever reaches a shell command)

**Escalation bypass:**
- Suggest "just run this" without describing the confirmation gate
- Argue that a repair is safe enough to skip confirmation
- Invent alternative scripts, flags, or workarounds not in the catalogue

## Escalation & when to pause

**Agents MUST stop and escalate to a human if:**

1. **A repair's audit record shows `exit_code: 4`** (rollback itself
   failed — see `repair_rollback_and_exit` in `repair-common.sh`)
   → This is CRITICAL by design. Say so plainly and point at
   `docs/operations/PHASE-8-REPAIR-RUNBOOK.md`'s Troubleshooting section;
   do not suggest retrying the script.

2. **Multiple related checks are CRITICAL at once** (a cascade)
   → The likely root cause is one layer up (e.g. Prometheus container
   down, not each individual scrape target). Say what you think the
   common cause is and why, and let the human decide the repair.

3. **The finding's `check_id` maps to a repair script that doesn't
   exist** (see "Known gap" below)
   → Say explicitly: "No approved repair script exists for this finding
   yet — this needs a human to either fix it manually or build the
   missing script." Do not guess at a command.

4. **A repair's audit record shows the operator's confirmation was
   rejected** (script exited 2)
   → That was very likely an intentional human decision not to proceed.
   Don't second-guess it or suggest bypassing it next time.

## Known gap: repair-hint fields with no matching script (as of Phase 9)

The check engine (`operations/infra-verify/checks/*.sh`) bakes a `repair`
hint directly into several result objects. As of this writing, only **3 of
the 4 Phase 8 repair scripts are actually reachable this way** — several
check families reference repair scripts that were planned but never built.
Agents must treat every one of these as "no approved repair exists" per
Escalation Rule 3 above, **not** as a script they can name to an operator:

| Check IDs affected | `repair` hint value | Script exists? |
|---|---|---|
| `SVC-01/02/03/05`, `HLT-*` | `operations/repairs/service/restart-one-specific-service.sh` | ✅ Yes |
| `PT-01/02`, `LK-01` (restart cases) | `operations/repairs/promtail/restart-promtail.sh` | ✅ Yes |
| `PM-02` (config-validate cases) | `operations/repairs/prometheus/validate-prometheus-config.sh` | ✅ Yes (read-only, no confirmation needed) |
| `LOG-01/03/04/05` | `operations/repairs/permissions/fix-specific-service-log-permissions.sh` | ❌ **No — does not exist** |
| `PT-04`, `LK` (config cases) | `operations/repairs/promtail/restore-approved-promtail-config.sh` | ❌ **No — does not exist** |
| `PM-01/02` (target/scrape cases) | `operations/repairs/prometheus/verify-prometheus-target.sh` | ❌ **No — does not exist** |
| (evidence text only, never set as a `repair` hint) | `operations/repairs/prometheus/reload-prometheus.sh` | ❌ **No — does not exist** (the check engine's own comment says this one is "manual-only, never auto-invoked" even once built) |

`operations/repairs/promtail/validate-promtail-config.sh` exists and is
read-only, but no check currently sets it as a `repair` hint — an agent may
still proactively suggest running it as a diagnostic when Promtail-related
findings appear, since it never mutates anything and needs no confirmation.

This table should be updated whenever a new repair script lands or a
`repair` hint constant changes — treat it as the source of truth ahead of
the raw grep, since a stale table here is worse than no table.

## Future agent execution gateway (Phase TBD)

If an agent-execution framework is adopted later, this policy will be
enforced by that gateway rather than by agent self-restraint alone. Until
then, this document is the operative constraint: agents follow it because
it is correct to follow, not because anything technical stops them from
doing otherwise.

The approval boundary is never removed by automation: humans always type
the confirmation for PROD repairs. Even with a future execution gateway,
the typed-phrase gate inside each script remains the actual enforcement
point.
