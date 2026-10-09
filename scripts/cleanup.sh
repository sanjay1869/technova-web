#!/bin/bash
# =============================================================
# scripts/cleanup.sh - find (and optionally delete) lab resources
# -------------------------------------------------------------
# The lab guide shows how to delete everything in the console.
# This script is a safety net you can run in AWS CloudShell.
#
#   bash cleanup.sh            -> REPORT only (deletes nothing)
#   bash cleanup.sh --delete   -> delete, after you type the account ID
#
# It does NOT delete: the CodePipeline S3 artifact bucket (it can be
# shared by other pipelines), the GitHub connection, the shared
# ecsTaskExecutionRole, or your GitHub repository. The lab guide
# explains how to remove those by hand if you want to.
# =============================================================
set -uo pipefail

REGION="ap-south-1"
MODE="report"
[ "${1:-}" = "--delete" ] && MODE="delete"

PIPELINE="technova-web-pipeline"
CODEDEPLOY_APP="technova-web-app"
CLUSTER="technova-cluster"
SERVICES=("technova-web-svc" "technova-web-bg-svc")
TASK_FAMILY="technova-web"
ALB="technova-alb"
TARGET_GROUPS=("technova-tg-blue" "technova-tg-green")
SECURITY_GROUPS=("technova-ecs-sg" "technova-alb-sg")
ECR_REPO="technova-web"
BUILD_PROJECT="technova-web-build"
LOG_GROUPS=("/ecs/technova-web" "/aws/codebuild/technova-web-build")
ROLES=("codebuild-technova-web-build-service-role" "AWSCodePipelineServiceRole-ap-south-1-technova-web-pipeline" "technova-codedeploy-ecs-role")

aws_r() { aws --region "$REGION" "$@"; }
found() { printf '  [FOUND]   %s\n' "$1"; }
missing() { printf '  [absent]  %s\n' "$1"; }
deleting() { printf '  [DELETE]  %s\n' "$1"; }

ACCOUNT=$(aws sts get-caller-identity --region "$REGION" --query Account --output text)
echo "Account: $ACCOUNT   Region: $REGION   Mode: $MODE"
if [ "$MODE" = "delete" ]; then
  read -r -p "Type the 12-digit account ID to confirm deletion: " CONFIRM
  [ "$CONFIRM" = "$ACCOUNT" ] || { echo "Account ID did not match. Nothing deleted."; exit 1; }
fi

act() { # act "<label>" <command...>   -> runs the command only in delete mode
  local label="$1"; shift
  if [ "$MODE" = "delete" ]; then deleting "$label"; "$@" >/dev/null 2>&1 || echo "            (could not delete - check the console)"; else found "$label"; fi
}

echo "1. CodePipeline"
if aws_r codepipeline get-pipeline --name "$PIPELINE" >/dev/null 2>&1; then
  act "pipeline $PIPELINE" aws_r codepipeline delete-pipeline --name "$PIPELINE"
else missing "pipeline $PIPELINE"; fi

echo "2. CodeDeploy"
if aws_r deploy get-application --application-name "$CODEDEPLOY_APP" >/dev/null 2>&1; then
  act "application $CODEDEPLOY_APP (and its deployment group)" aws_r deploy delete-application --application-name "$CODEDEPLOY_APP"
else missing "application $CODEDEPLOY_APP"; fi

echo "3. ECS services, task definitions and cluster"
for svc in "${SERVICES[@]}"; do
  status=$(aws_r ecs describe-services --cluster "$CLUSTER" --services "$svc" --query 'services[0].status' --output text 2>/dev/null)
  if [ "$status" = "ACTIVE" ]; then
    act "service $svc" aws_r ecs delete-service --cluster "$CLUSTER" --service "$svc" --force
  else missing "service $svc"; fi
done
for td in $(aws_r ecs list-task-definitions --family-prefix "$TASK_FAMILY" --query 'taskDefinitionArns[]' --output text 2>/dev/null); do
  act "task definition ${td##*/}" aws_r ecs deregister-task-definition --task-definition "$td"
done
if [ "$MODE" = "delete" ]; then
  echo "  Waiting for services to finish deleting ..."
  for svc in "${SERVICES[@]}"; do aws_r ecs wait services-inactive --cluster "$CLUSTER" --services "$svc" >/dev/null 2>&1; done
  inactive=$(aws_r ecs list-task-definitions --family-prefix "$TASK_FAMILY" --status INACTIVE --query 'taskDefinitionArns[]' --output text 2>/dev/null)
  # DeleteTaskDefinitions accepts at most 10 ARNs per call
  # shellcheck disable=SC2086
  [ -n "$inactive" ] && printf '%s\n' $inactive | xargs -n 10 aws --region "$REGION" ecs delete-task-definitions --task-definitions >/dev/null 2>&1
fi
if [ "$(aws_r ecs describe-clusters --clusters "$CLUSTER" --query 'clusters[0].status' --output text 2>/dev/null)" = "ACTIVE" ]; then
  act "cluster $CLUSTER" aws_r ecs delete-cluster --cluster "$CLUSTER"
else missing "cluster $CLUSTER"; fi

echo "4. Load balancer and target groups"
ALB_ARN=$(aws_r elbv2 describe-load-balancers --names "$ALB" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  act "load balancer $ALB" aws_r elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
  [ "$MODE" = "delete" ] && aws_r elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" >/dev/null 2>&1
else missing "load balancer $ALB"; fi
for tg in "${TARGET_GROUPS[@]}"; do
  TG_ARN=$(aws_r elbv2 describe-target-groups --names "$tg" --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
  if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then act "target group $tg" aws_r elbv2 delete-target-group --target-group-arn "$TG_ARN"
  else missing "target group $tg"; fi
done

echo "5. Security groups (wait 2-3 minutes after the load balancer is gone)"
[ "$MODE" = "delete" ] && sleep 60
for sg in "${SECURITY_GROUPS[@]}"; do
  SG_ID=$(aws_r ec2 describe-security-groups --filters Name=group-name,Values="$sg" --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null)
  if [ -n "$SG_ID" ] && [ "$SG_ID" != "None" ]; then act "security group $sg ($SG_ID)" aws_r ec2 delete-security-group --group-id "$SG_ID"
  else missing "security group $sg"; fi
done

echo "6. Amazon ECR repository (and all images in it)"
if aws_r ecr describe-repositories --repository-names "$ECR_REPO" >/dev/null 2>&1; then
  act "repository $ECR_REPO" aws_r ecr delete-repository --repository-name "$ECR_REPO" --force
else missing "repository $ECR_REPO"; fi

echo "7. CodeBuild project and test report group"
if [ "$(aws_r codebuild batch-get-projects --names "$BUILD_PROJECT" --query 'length(projects)' --output text 2>/dev/null)" = "1" ]; then
  act "build project $BUILD_PROJECT" aws_r codebuild delete-project --name "$BUILD_PROJECT"
else missing "build project $BUILD_PROJECT"; fi
RG_ARN="arn:aws:codebuild:${REGION}:${ACCOUNT}:report-group/${BUILD_PROJECT}-technova-unit-tests"
if [ "$(aws_r codebuild batch-get-report-groups --report-group-arns "$RG_ARN" --query 'length(reportGroups)' --output text 2>/dev/null)" = "1" ]; then
  act "report group ${BUILD_PROJECT}-technova-unit-tests" aws_r codebuild delete-report-group --arn "$RG_ARN" --delete-reports
else missing "report group ${BUILD_PROJECT}-technova-unit-tests"; fi

echo "8. CloudWatch log groups"
for lg in "${LOG_GROUPS[@]}"; do
  if [ "$(aws_r logs describe-log-groups --log-group-name-prefix "$lg" --query "length(logGroups[?logGroupName=='$lg'])" --output text 2>/dev/null)" = "1" ]; then
    act "log group $lg" aws_r logs delete-log-group --log-group-name "$lg"
  else missing "log group $lg"; fi
done

echo "9. IAM roles created for this lab"
delete_role() {
  local role="$1" p
  for p in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$p"
    # Policies the console created for this role (customer managed) are deleted too,
    # so the next class can create the same role names again. AWS managed ones are kept.
    case "$p" in
      arn:aws:iam::aws:*) ;;
      *) if [ "$(aws iam get-policy --policy-arn "$p" --query 'Policy.AttachmentCount' --output text)" = "0" ]; then
           # shellcheck disable=SC2016  # backticks are JMESPath literals, not shell
           for v in $(aws iam list-policy-versions --policy-arn "$p" --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text); do
             aws iam delete-policy-version --policy-arn "$p" --version-id "$v"
           done
           aws iam delete-policy --policy-arn "$p"
         fi ;;
    esac
  done
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  aws iam delete-role --role-name "$role"
}
for role in "${ROLES[@]}"; do
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then act "role $role" delete_role "$role"
  else missing "role $role"; fi
done

echo
if [ "$MODE" = "report" ]; then
  echo "Report only. Run 'bash cleanup.sh --delete' to remove the resources marked [FOUND]."
else
  echo "Clean-up finished. Check the console tomorrow under Billing > Bills to confirm no charges."
fi
