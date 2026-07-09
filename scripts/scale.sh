#!/usr/bin/env bash
###############################################################################
# scale.sh — Start or stop the DR cluster to save money when not in use
#
# Usage:
#   ./scripts/scale.sh up      # Scale EKS nodes back up (start working)
#   ./scripts/scale.sh down    # Scale EKS nodes to 0  (stop paying for compute)
#   ./scripts/scale.sh status  # Show current node count + RDS state
###############################################################################

set -euo pipefail

CLUSTER="mc-dr-eks"
NODEGROUP="mc-dr-eks-app"      # adjust if your node group name differs
REGION="us-east-1"
RDS_ID="mc-dr-primary-pg"
PROFILE="${AWS_PROFILE:-ves-admin}"

UP_COUNT=2    # nodes when working
DOWN_COUNT=0  # nodes when idle

cmd="${1:-status}"

aws_cmd() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

case "$cmd" in
  up)
    echo "▶ Scaling EKS nodes UP to $UP_COUNT..."
    aws_cmd eks update-nodegroup-config \
      --cluster-name "$CLUSTER" \
      --nodegroup-name "$NODEGROUP" \
      --scaling-config minSize=0,maxSize=4,desiredSize=$UP_COUNT
    echo "▶ Starting RDS instance (if stopped)..."
    aws_cmd rds start-db-instance --db-instance-identifier "$RDS_ID" 2>/dev/null \
      && echo "   RDS starting — takes ~5 min" \
      || echo "   RDS already running"
    echo "✅ Done. Allow ~3 min for nodes to become Ready."
    ;;

  down)
    echo "▶ Scaling EKS nodes DOWN to $DOWN_COUNT..."
    aws_cmd eks update-nodegroup-config \
      --cluster-name "$CLUSTER" \
      --nodegroup-name "$NODEGROUP" \
      --scaling-config minSize=0,maxSize=4,desiredSize=$DOWN_COUNT
    echo "▶ Stopping RDS instance (saves ~\$0.96/hr — auto-resumes after 7 days)..."
    aws_cmd rds stop-db-instance --db-instance-identifier "$RDS_ID" 2>/dev/null \
      && echo "   RDS stopping — takes ~3 min" \
      || echo "   RDS already stopped"
    echo "✅ Done. You're now paying only for NAT gateway + VPN (~\$5/day)."
    ;;

  status)
    echo "── EKS Node Group ──────────────────────────────"
    aws_cmd eks describe-nodegroup \
      --cluster-name "$CLUSTER" \
      --nodegroup-name "$NODEGROUP" \
      --query 'nodegroup.scalingConfig' --output table
    echo "── RDS Instance ────────────────────────────────"
    aws_cmd rds describe-db-instances \
      --db-instance-identifier "$RDS_ID" \
      --query 'DBInstances[0].{Status:DBInstanceStatus,Class:DBInstanceClass,MultiAZ:MultiAZ}' \
      --output table
    ;;

  *)
    echo "Usage: $0 [up|down|status]"
    exit 1
    ;;
esac
