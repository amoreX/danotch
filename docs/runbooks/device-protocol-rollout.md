# Runbook: Device Protocol Rollout

**Scope:** Rolling out the authenticated device gateway (WSS), device enrollment, ticket issuance, fence advancement, and handling the one-release backward-compatibility window.

---

## Pre-flight

1. Confirm the durable runs and events schema (migration `006_devices_runs_events.sql`) is applied and verified on the target environment.
2. Confirm CI is green on all protocol schema tests (`protocol-schema` job in `ci.yml`).
3. Confirm the prior release of the backend is deployed and healthy.

---

## Rollout Phases

### Phase 1 — Deploy gateway alongside legacy bridge (shadow mode)

The gateway accepts WSS connections but the legacy localhost bridge (port 7778) is still present. Both process events in parallel so operators can compare behavior.

**Actions:**
1. Deploy the new backend with `GATEWAY_SHADOW_MODE=true` in the environment.
2. Verify `/health` shows `"gateway": "shadow"`.
3. Confirm existing app clients continue to connect via the legacy bridge without errors.
4. Monitor gateway connection attempts in logs for early adopter devices.

### Phase 2 — Internal app clients switch to WSS

Deploy a signed internal build of the app that connects outbound over WSS using HTTPS-issued one-use tickets. The legacy bridge remains as a fallback for un-updated clients.

**Actions:**
1. Verify device enrollment endpoint (`POST /api/devices/enroll`) responds for freshly authenticated users.
2. Test ticket issuance and atomic consumption on a test device.
3. Verify fence advancement rejects old sockets within the timeout window.
4. Confirm connection recovery (sleep/wake, network change) produces the correct reconnect sequence.

### Phase 3 — Remove legacy bridge

Remove port 7778 from the backend after the one-release backward-compatibility window. All enrolled production devices must be on the new protocol.

**Actions:**
1. Confirm no authenticated connections to the legacy bridge have appeared in logs for the documented monitoring period (minimum 7 days after new app is available).
2. Set `LEGACY_BRIDGE_DISABLED=true`. Restart the service.
3. Verify old app versions cannot connect (expected: TCP refused or HTTP 404 on `/ws`).
4. Verify new app versions reconnect successfully after the restart.

---

## Device Enrollment

A device key is enrolled after fresh authentication. Device limits per account are enforced by the backend.

**Operator actions:**
- View enrolled devices: query `devices` table filtered by `user_id`.
- Revoke a device: set `revoked_at` and `revoked_reason`; the gateway rejects new tickets for that device on next fence check.
- Reset device count: remove revoked rows; user re-enrolls on next fresh auth.

---

## Fence and Ticket Management

Each device has a monotonically increasing fence sequence. A ticket is single-use and bound to a specific device/fence pair.

**Symptoms and responses:**

| Symptom | Likely cause | Response |
|---------|-------------|----------|
| Client reconnects in a loop | Stale fence — ticket consumed but fence not advanced | Check `devices.fence_seq` vs the ticket's bound fence in logs |
| `403 ticket_reused` | Network retry on a successful upgrade | Client must request a new ticket; this is expected behavior |
| `403 device_limit` | Account has hit the enrollment cap | User must revoke an unused device via settings |
| `403 revoked` | Device was explicitly revoked | User must re-enroll with fresh authentication |

---

## Rollback

The device protocol rollback must not restore the localhost bridge or plaintext credentials.

1. Deploy the prior backend version. If it did not include the gateway, the shadow-mode environment variable keeps the bridge dormant.
2. Pre-hardening credentials (cleartext tokens, port 7778 auth tokens) are **revoked** — do not restore them. Issue new tickets through the upgrade flow.
3. Enrolled device keys remain valid across a rollback (they are stored in Keychain, not in the backend).
4. New tickets cannot be issued by the rolled-back backend until it is re-deployed with gateway support.

---

## Monitoring

- Watch for `fence_mismatch` and `ticket_reused` log events — a spike indicates a client-server version skew.
- Alert on device enrollment failures exceeding 5% of attempts over a 5-minute window.
- Confirm `"gateway": "healthy"` in `/health` during the first 30 minutes after each deployment.
