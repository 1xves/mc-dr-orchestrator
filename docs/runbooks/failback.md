# Runbook — Failback (AKS Standby → GKE Primary)

**Trigger:** GKE primary has been restored and is stable. Traffic is currently routing to AKS standby. Goal is to return traffic to GKE and idle AKS back to zero nodes.

---

## Decision criteria before starting

Do NOT initiate failback until GKE has been stable for at least 15 minutes. A premature failback that fails will require re-running failover, adding unnecessary RTO.

Checklist:
- [ ] GKE node pool is scaled up (`./scripts/scale.sh up` or manual)
- [ ] GKE Postgres pod is running: `kubectl get pod -n database` (GKE context)
- [ ] Application pods are running and passing readiness probes
- [ ] Primary URL is returning 200 consistently for 15+ minutes
- [ ] Root cause of original outage is resolved

---

## Pre-checks (5 min)

```bash
# 1. Confirm GKE endpoint is healthy
for i in $(seq 5); do
  curl -s -o /dev/null -w "%{http_code}\n" https://api.yourdomain.com/healthz
  sleep 5
done
# All should be 200

# 2. Confirm current DNS points at AKS (expected before failback)
dig api.yourdomain.com +short
# Should show Azure LB IP

# 3. Retrieve GKE ingress IP
kubectl get svc -n default   # GKE context
# Note EXTERNAL-IP
```

---

## Execution

Dry run first:

```bash
python scripts/failback.py \
  --gcp-project YOUR_GCP_PROJECT_ID \
  --dns-zone mc-dr-zone \
  --dns-name api.yourdomain.com \
  --gke-ingress-ip GKE_LB_IP \
  --azure-rg mc-dr-standby-rg \
  --aks-cluster mc-dr-aks \
  --dry-run
```

If output looks correct, execute without `--dry-run`.

**Expected sequence:**
1. 5 consecutive health checks against GKE primary — all must pass
2. Cloud DNS A record updated: `api.yourdomain.com → GKE_LB_IP` (TTL 60s)
3. 30s propagation wait + 3 post-flip verification checks
4. AKS node pool scaled to 0 (PVC retained, data preserved)
5. Pub/Sub event published to `mc-dr-dr-alerts`

---

## Post-failback verification

```bash
# DNS now shows GKE IP
dig api.yourdomain.com +short

# GKE serving traffic
curl -s https://api.yourdomain.com/healthz

# AKS at 0 nodes (may take a few min to drain)
az aks show --name mc-dr-aks --resource-group mc-dr-standby-rg \
  --query "agentPoolProfiles[0].count"
```

---

## If failback fails mid-sequence

The most dangerous partial failure is DNS flipped to GKE but GKE not serving:

1. Check `failback.py` output — it logs the exact failure point
2. If post-DNS check failed: immediately re-run `failover.py` to restore AKS as active
3. Once back on AKS, investigate GKE before retrying failback

---

## Post-incident

After a successful failback:
- Scale AKS to 0 is handled by `failback.py` automatically
- Scale GKE nodes down when traffic is confirmed stable to resume idle cost:
  ```bash
  ./scripts/scale.sh down
  ```
  (This idles both clusters; GKE PVC retains data for next scale-up)
- File incident report documenting RTO, root cause, and action items
