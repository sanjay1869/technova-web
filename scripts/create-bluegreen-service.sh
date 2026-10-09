#!/bin/bash
# =============================================================
# scripts/create-bluegreen-service.sh            (Lab Part B)
# -------------------------------------------------------------
# Creates the ECS service "technova-web-bg-svc" that uses the
# CODE_DEPLOY deployment controller (blue/green with CodeDeploy).
#
# Why a script? The ECS console's service wizard now focuses on
# ECS-native deployments, so AWS documents creating a CodeDeploy-
# controlled service with the AWS CLI. Run this in AWS CloudShell.
#
# Usage:   bash create-bluegreen-service.sh
# =============================================================
set -euo pipefail

REGION="ap-south-1"
CLUSTER="technova-cluster"
SERVICE="technova-web-bg-svc"
TASK_FAMILY="technova-web"
CONTAINER="technova-web"
TARGET_GROUP="technova-tg-blue"
TASK_SG_NAME="technova-ecs-sg"

echo "1/5 Finding the default VPC ..."
VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" \
  --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
echo "    VPC: $VPC_ID"

echo "2/5 Finding the public subnets in ap-south-1a and ap-south-1b ..."
SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
            Name=availability-zone,Values=ap-south-1a,ap-south-1b \
  --query 'Subnets[].SubnetId' --output text | tr '\t' ',')
echo "    Subnets: $SUBNETS"

echo "3/5 Finding the task security group and the blue target group ..."
TASK_SG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters Name=vpc-id,Values="$VPC_ID" Name=group-name,Values="$TASK_SG_NAME" \
  --query 'SecurityGroups[0].GroupId' --output text)
TG_ARN=$(aws elbv2 describe-target-groups --region "$REGION" \
  --names "$TARGET_GROUP" --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "    Security group: $TASK_SG"
echo "    Target group:   $TG_ARN"

echo "4/5 Creating the service (deployment controller = CODE_DEPLOY) ..."
aws ecs create-service --region "$REGION" \
  --cluster "$CLUSTER" \
  --service-name "$SERVICE" \
  --task-definition "$TASK_FAMILY" \
  --desired-count 2 \
  --launch-type FARGATE \
  --deployment-controller type=CODE_DEPLOY \
  --health-check-grace-period-seconds 30 \
  --load-balancers "targetGroupArn=${TG_ARN},containerName=${CONTAINER},containerPort=8080" \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS}],securityGroups=[${TASK_SG}],assignPublicIp=ENABLED}" \
  --query 'service.[serviceName,status,deploymentController.type]' --output text

echo "5/5 Waiting until 2 tasks are running and healthy (2-4 minutes) ..."
# A CODE_DEPLOY service tracks task sets, so the standard "services-stable" waiter
# does not apply. Poll the running count and the target health instead (max 10 min).
for i in $(seq 1 40); do
  RUNNING=$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "$SERVICE" \
    --query 'services[0].runningCount' --output text)
  HEALTHY=$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$TG_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
  echo "    check $i: running tasks = $RUNNING, healthy targets = $HEALTHY"
  if [ "$RUNNING" = "2" ] && [ "$HEALTHY" = "2" ]; then
    echo "Done. Service $SERVICE has 2 healthy tasks in $TARGET_GROUP."
    exit 0
  fi
  sleep 15
done
echo "Still not healthy after 10 minutes. Open ECS > $CLUSTER > $SERVICE > Events, and the"
echo "stopped tasks' 'Stopped reason', then fix the cause (see the troubleshooting table)."
exit 1
