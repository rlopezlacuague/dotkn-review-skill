# Worked examples — classification precedents

Cases drawn from real reviews that misclassified something and were corrected; identifying details (providers, field names, system names) are generalized. When a rule in SKILL.md feels ambiguous for the situation in front of you, match against the nearest precedent here — precedents constrain interpretation better than prose.

**Growth rule:** an entry is added only when a real review got it wrong and the correction was validated on a re-run. This file is precedent, not padding.

---

## 1. Response-side contract activation → HIGH, fails the review

**Situation:** A change sends an opt-in header that makes a payment provider return a new response variant (a new nested node with detailed error information). The new mapping is null-safe, only reads diagnostic fields from the new node, and is covered by unit tests with hand-written JSON fixtures. The new node also carries `approvalCode` — duplicating a root-level field the system persists.

**Naive classification:** "The new code is null-safe and only adds optional diagnostics; worst case the diagnostics don't appear → non-blocking verify item." A review shipped exactly this reasoning and PASSED the branch.

**Correct classification:** HIGH → STATUS: FAILED. The activated response can change *anywhere* in the payload, not just in the fields the diff reads; the null-safety of the new code does not cap the blast radius. Root-level fields feeding persistence (`approvalCode`, `transactionId`, `referenceNumber`) all arrive from that same reshaped response.

**How it fails if missed:** the provider moves `approvalCode` from the root into the new node; the mapping keeps reading the root; every approved transaction persists a null approval code, and every downstream operation that needs it (capture, refund, reconciliation) is rejected until a rollback.

**Required check:** diff sanitized real payloads with the header off and on, for successful AND rejected outcomes, across every field the system reads or persists — not only the new node. Preserve the sanitized payloads as fixtures.

---

## 2. Request-side assumption through shared infrastructure → verify item, does not block

**Situation:** The same change sends the opt-in header through a shared routing proxy on the primary authorization path. Nothing in the repo proves the proxy forwards arbitrary custom headers; the unit test only asserts the header on the request *entering* the proxy.

**Naive classification:** "Unverified assumption on the payment path → HIGH, block the merge."

**Correct classification:** Verify-before-merge item, non-blocking. The outcome is binary: the header arrives (feature works) or it doesn't (feature silently no-ops and responses keep their old shape). Nothing persisted or acted-on can be corrupted by a stripped request header.

**Anti-recurrence:** this proxy is shared by every provider integration, so the same doubt would re-fire on every integration PR. Verify it once, record the dated fact and evidence in the project rules (`AGENTS.md`), and treat it as settled thereafter.

---

## 3. Regression claim without evidence the old code worked → state what you know

**Situation:** A branch deleted a worker that was the only writer of two metrics tables; new code on the same branch reads those tables. A finding claimed "on main, this worker upserted the tables — this branch breaks ingestion."

**Naive classification:** Regression ("you broke this"), asserted confidently because a write call existed on main.

**What was actually true:** main's writer had never worked — its payload didn't match the table schema; the tables had been empty since the initial commit. The defect (tables have no writer) was real; the regression story was false, and it pointed the author at a revert-shaped fix when the problem was design-shaped.

**Correct handling:** the finding stands, but the claim is scoped to the evidence: "this branch leaves these tables with no writer" — regression vs. already-broken changes what the author should do next. Only claim "this change broke X" after verifying X worked before.

---

## 4. Fix prescribed from interface names → read the implementations first

**Situation:** For the finding in example 3, the review prescribed "call `getMetrics()` and upsert the results" because a method with the right name existed and was dead code.

**What was actually true:** `getMetrics()` returned per-connector aggregates; the target table was keyed per post. The proposed fix could not have worked; the real fix lived inside `sync()`, where the per-post data was already fetched and discarded.

**Correct handling:** a proposed fix is a claim about code — include a concrete mechanism only after reading the implementations it touches and confirming the data shapes line up. Otherwise state the requirement ("these tables need a writer keyed per post") and leave the mechanism to the author.

---

## 5. Non-idempotent setter on an entity that rides serialized state → HIGH, fails the review

**Situation:** To encrypt a PII field, a change makes the entity's public setter encrypt whatever it receives; the business mapper calls it once with plaintext. The same entity also travels whole inside a params object that a workflow engine checkpoints as JSON and rehydrates with a standard `ObjectMapper` on every resume and poll. The params object and the engine are old code, absent from the diff. The branch's unit tests include `setValue_skipsEncryptionWhenAlreadyEncrypted` — asserting an invariant the setter does not have.

**Naive classification:** "Grep shows the only writer is the mapper, which passes plaintext; the ORM uses field access, so loads skip the setter; no call site passes ciphertext → double encryption cannot happen → no finding." A review shipped exactly this reasoning and PASSED the branch.

**Correct classification:** HIGH → STATUS: FAILED. Deserializers are callers. Every checkpoint rehydration invokes the public setter with the already-encrypted value; encryption is not idempotent; the field re-wraps on every cycle. The params object being out of the diff is irrelevant — the diff changed the semantics of data it carries, so the interaction is new.

**How it fails if missed:** the persisted checkpoint grows on every resume, a single decrypt no longer yields the original value, and the affected workflows slow down and stall — along with everything they were supposed to deliver — until a rollback.

**The dropped thread:** the review *saw* the confession test, asked "who would pass ciphertext into this setter?", answered with a grep of source-level call sites, found nothing, and closed the question. The absence of a source-level producer is not proof that no producer exists — reflective consumers don't grep.

**Required check:** round-trip the params object through the same serializer configuration the engine uses and assert the encrypted field is byte-identical. Durable project rules to suggest: `REJECT encrypt/hash/normalize inside public accessors of types that are serialized` and `REQUIRE workflow params to carry identifiers, not entities`.
