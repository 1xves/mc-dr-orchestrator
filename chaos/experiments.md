# Chaos Experiments — MC-DR Orchestrator

These experiments validate the DR system end-to-end. Run them in order from lowest to highest blast radius. Always have both clusters at node_count >= 1 before starting.

**Prerequisites:**
```bash
./scripts/scale.sh up   # both clusters at 1+ nodes
kubectl get pods -n database   # GKE context — postgres running
kubectl get pods -n database   # AKS context — postgres running
```

---

## Experiment 1 — Health monitor false-positive guard

**Hypothesis:** A single failed health check does not trigger failover.

**Inject:**
```bash
# Block the health endpoint temporarily (port forward to GKE postgres, not app)
# Simulate by bouncing the app pod once:
kubectl rollout restart deployment/app -n default   # GKE context
```

**Observe:**
- `health_monitor.py` logs a single failure but does not alert
- `ConsecutiveFailures` metric goes to 1 then back to 0
- No Pub/Sub message published

**Pass criteria:** No alert fired for a single transient failure.

---

## Experiment 2 — Full primary node failure

**Hypothesis:** Three consecutive failures trigger a Pub/Sub alert.

**Inject:**
```bash
# Scale GKE to 0 nodes (hard kill)
gcloud container clusters resize mc-dr-gke \
  --zone us-central1-a \
  --num-nodes 0 \
  --node-pool default-pool
```

**Observe:**
- `health_monitor.py` logs 3 consecutive failures
- `ConsecutiveFailures` metric reaches 3
- Pub/Sub alert published within ~90 seconds (3 checks × 30s interval)
- `PrimaryHealthy` metric drops to 0

**Pass criteria:** Alert fires within 3 check intervals.

**Cleanup:**
```bash
gcloud container clusters resize mc-dr-gke \
  --zone us-central1-a \
  --num-nodes 1 \
  --node-pool default-pool
```

---

## Experiment 3 — Automated failover (dry run)

**Hypothesis:** `failover.py` correctly identifies primary as down and prints all steps.

**Setup:** GKE is down (from Experiment 2).

**Inject:**
```bash
python scripts/failover.py \
  --gcp-project YOUR_PROJECT_ID \
  --dns-zone mc-dr-zone \
  --dns-name api.yourdomain.com \
  --azure-rg mc-dr-standby-rg \
  --aks-cluster mc-dr-aks \
  --aks-ingress-ip AZURE_LB_IP \
  --dry-run
```

**Observe:**
- 3 consecutive failed checks logged
- `[DRY RUN] Would scale AKS node pool to 2`
- `[DRY RUN] Would update DNS record`
- `[DRY RUN] Would publish failover event`

**Pass criteria:** All 6 steps logged correctly without modifying any real resources.

---

## Experiment 4 — Live failover

**Hypothesis:** Full failover completes within 7 minutes with traffic serving from AKS.

**Preconditions:** GKE is down (from Experiment 2, not yet restored).

**Execute:**
```bash
python scripts/failover.py \
  --gcp-project YOUR_PROJECT_ID \
  --dns-zone mc-dr-zone \
  --dns-name api.yourdomain.com \
  --azure-rg mc-dr-standby-rg \
  --aks-cluster mc-dr-aks \
  --aks-ingress-ip AZURE_LB_IP
```

**Observe:**
- AKS node pool scales from 0 → 2
- `FailoverDurationSeconds` metric emitted
- Cloud DNS A record updated to AKS IP
- `dig api.yourdomain.com +short` returns AKS LB IP
- `curl https://api.yourdomain.com/healthz` returns 200 from AKS

**Pass criteria:** DNS updated and traffic serving within 7 minutes.

---

## Experiment 5 — Postgres data persistence through failover

**Hypothesis:** Data written to GKE Postgres before failure is available on AKS after failover.

**Note:** This validates PVC persistence, not cross-cluster replication. GKE and AKS have separate Postgres instances. This experiment tests that PVC data survives a node restart; it does not test cross-cloud synchronization (that is a future enhancement).

**Setup:** GKE nodes at 1. Postgres running.

**Inject:**
```bash
# Write test data to GKE Postgres
kubectl exec -it postgres-0 -n database -- \
  psql -U drapp -d drapp -c "INSERT INTO dr_test VALUES ('chaos-$(date +%s)', now());"

# Capture current row count
kubectl exec -it postgres-0 -n database -- \
  psql -U drapp -d drapp -c "SELECT count(*) FROM dr_test;"

# Scale GKE node to 0 and back to 1 (simulates node restart, PVC re-attaches)
gcloud container clusters resize mc-dr-gke --zone us-central1-a --num-nodes 0 --node-pool default-pool
sleep 60
gcloud container clusters resize mc-dr-gke --zone us-central1-a --num-nodes 1 --node-pool default-pool

# Wait for pod restart
kubectl rollout status statefulset/postgres -n database --timeout=300s

# Verify data survived
kubectl exec -it postgres-0 -n database -- \
  psql -U drapp -d drapp -c "SELECT count(*) FROM dr_test;"
```

**Pass criteria:** Row count matches pre-restart count.

---

## Experiment 6 — Failback after recovery

**Hypothesis:** After GKE is restored, `failback.py` returns traffic to primary and idles AKS.

**Preconditions:** Experiment 4 complete; traffic serving from AKS; GKE restored.

**Setup:**
```bash
# Restore GKE
gcloud container clusters resize mc-dr-gke --zone us-central1-a --num-nodes 1 --node-pool default-pool
kubectl rollout status statefulset/postgres -n database --timeout=300s
# Wait 15 minutes for stability confirmation before proceeding
```

**Execute:**
```bash
python scripts/failback.py \
  --gcp-project YOUR_PROJECT_ID \
  --dns-zone mc-dr-zone \
  --dns-name api.yourdomain.com \
  --gke-ingress-ip GKE_LB_IP \
  --azure-rg mc-dr-standby-rg \
  --aks-cluster mc-dr-aks
```

**Observe:**
- 5 consecutive GKE health checks pass
- Cloud DNS reverts to GKE IP
- Post-DNS checks confirm GKE serving
- AKS scales to 0
- `FailbackCompleted` metric = 1
- `dig api.yourdomain.com +short` returns GKE IP

**Pass criteria:** Full failback in < 10 minutes; AKS at 0 nodes.

---

## Results log template

| Date | Experiment | Pass/Fail | Failover time | Notes |
|---|---|---|---|---|
| | 1 | | n/a | |
| | 2 | | n/a | |
| | 3 | | n/a (dry run) | |
| | 4 | | min | |
| | 5 | | n/a | |
| | 6 | | min | |
