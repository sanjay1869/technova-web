#!/bin/bash
# =============================================================
# scripts/preflight-check.sh                     (version 2.0)
# -------------------------------------------------------------
# Checks the settings that make the pipeline's Build stage work.
# Run it in AWS CloudShell (Region: Mumbai) before Step 7, or any
# time a build fails. It only READS your account - it changes nothing.
#
# Usage:   bash preflight-check.sh
# =============================================================
set -uo pipefail

REGION="ap-south-1"
CONNECTION="technova-github"
REPO="technova-web"
PROJECT="technova-web-build"
PIPELINE="technova-web-pipeline"
EXEC_ROLE="ecsTaskExecutionRole"
LOG_GROUP="/ecs/technova-web"

PASS=0; FAIL=0
ok()   { printf '  [PASS] %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  [FAIL] %s\n         FIX: %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
aws_r() { aws --region "$REGION" "$@"; }
# First value that is not empty or "None" (paged CLI output can contain extra "None" lines)
first_value() { tr -s '\t ' '\n' | grep -v -x -e 'None' -e '' | head -n 1; }

ACCOUNT=$(aws_r sts get-caller-identity --query Account --output text 2>/dev/null)
if [ -z "$ACCOUNT" ]; then
  echo "Cannot call AWS. Open CloudShell from the AWS console and try again."; exit 1
fi
echo "Account $ACCOUNT - Region $REGION"
echo

echo "0. CodeBuild build quota (new accounts)"
# The CLI applies --query to each page of results, so keep the first real number only.
QUOTA=$(aws_r service-quotas list-service-quotas --service-code codebuild \
  --query "Quotas[?contains(QuotaName, 'Linux/Small')].Value" --output text 2>/dev/null | first_value)
case "$QUOTA" in
  "") printf '  [INFO] Could not read the CodeBuild quota. If a build says "Cannot have more than 0 builds",\n         ask for an increase (Service Quotas > AWS CodeBuild) or open a free Account and billing support case.\n' ;;
  0|0.0) bad "CodeBuild may run 0 Linux/Small builds in $REGION" "Service Quotas > AWS CodeBuild > Linux/Small concurrent builds > Request increase (or open a support case)." ;;
  *) ok "CodeBuild may run ${QUOTA%.0} Linux/Small build(s) at a time" ;;
esac

# If the pipeline already exists, check the connection and build project it REALLY uses.
CONN_ARN=$(aws_r codepipeline get-pipeline --name "$PIPELINE" \
  --query "pipeline.stages[].actions[] | [?actionTypeId.provider=='CodeStarSourceConnection'].configuration.ConnectionArn | [0]" \
  --output text 2>/dev/null | first_value)
PIPE_PROJECT=$(aws_r codepipeline get-pipeline --name "$PIPELINE" \
  --query "pipeline.stages[].actions[] | [?actionTypeId.provider=='CodeBuild'].configuration.ProjectName | [0]" \
  --output text 2>/dev/null | first_value)
if [ -n "$PIPE_PROJECT" ]; then PROJECT="$PIPE_PROJECT"; fi

echo "1. GitHub connection (Step 3)"
CONN_ERR=$(mktemp)
if [ -n "$CONN_ARN" ]; then
  # Older connections have codestar-connections ARNs; both APIs return the same fields.
  SVC=codeconnections; case "$CONN_ARN" in *:codestar-connections:*) SVC=codestar-connections ;; esac
  read -r CONN_NAME STATUS <<< "$(aws_r "$SVC" get-connection --connection-arn "$CONN_ARN" \
    --query 'Connection.[ConnectionName,ConnectionStatus]' --output text 2>"$CONN_ERR")"
  CONNECTION="${CONN_NAME:-$CONNECTION}"
else
  STATUS=$(aws_r codeconnections list-connections --provider-type-filter GitHub \
    --query "Connections[?ConnectionName=='${CONNECTION}'].ConnectionStatus" --output text 2>"$CONN_ERR" | first_value)
fi
if [ "$STATUS" = "AVAILABLE" ]; then ok "Connection $CONNECTION is AVAILABLE"
elif grep -q "AccessDenied" "$CONN_ERR"; then bad "Not allowed to read connections" "Run this script as a user with AdministratorAccess (or codeconnections:ListConnections)."
elif [ -z "$STATUS" ] || [ "$STATUS" = "None" ]; then bad "Connection $CONNECTION not found in $REGION" "Create it in CodePipeline > Settings > Connections (Step 3), in the Mumbai Region."
else bad "Connection $CONNECTION is $STATUS" "Settings > Connections > select it > Update pending connection."; fi
rm -f "$CONN_ERR"

echo "2. Amazon ECR repository (Step 4)"
MUT=$(aws_r ecr describe-repositories --repository-names "$REPO" \
  --query 'repositories[0].imageTagMutability' --output text 2>/dev/null)
if [ -n "$MUT" ] && [ "$MUT" != "None" ]; then ok "Repository $REPO exists (tag mutability: $MUT)"
else bad "Repository $REPO not found in $REGION" "Create it in Amazon ECR > Private repositories (Step 4), in the Mumbai Region."; fi

echo "3. Task execution role and log group (Step 5)"
if aws iam get-role --role-name "$EXEC_ROLE" >/dev/null 2>&1; then
  if aws iam list-attached-role-policies --role-name "$EXEC_ROLE" --query 'AttachedPolicies[].PolicyName' --output text | grep -q AmazonECSTaskExecutionRolePolicy; then
    ok "Role $EXEC_ROLE has AmazonECSTaskExecutionRolePolicy"
  else bad "Role $EXEC_ROLE has no AmazonECSTaskExecutionRolePolicy" "IAM > Roles > $EXEC_ROLE > Add permissions > Attach policies."; fi
else bad "Role $EXEC_ROLE not found" "Create it (Step 5.1)."; fi
LG=$(aws_r logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].logGroupName | [0]" --output text 2>/dev/null)
if [ "$LG" = "$LOG_GROUP" ]; then ok "Log group $LOG_GROUP exists"
else bad "Log group $LOG_GROUP not found" "CloudWatch > Log groups > Create log group (Step 5.2)."; fi

echo "4. CodeBuild project used by the pipeline (Step 6): $PROJECT"
PROJ=$(aws_r codebuild batch-get-projects --names "$PROJECT" \
  --query 'projects[0].[environment.privilegedMode, environment.image, serviceRole, source.type]' --output text 2>/dev/null)
if [ -z "$PROJ" ] || [ "$PROJ" = "None" ]; then
  bad "Build project $PROJECT not found" "Create it from the pipeline wizard (Step 6.3)."
else
  read -r PRIV IMAGE ROLE_ARN SRC <<< "$PROJ"
  if [ "$PRIV" = "True" ]; then ok "Privileged mode is ON (Docker can run)"
  else bad "Privileged mode is OFF" "CodeBuild > $PROJECT > Edit > Environment > Additional configuration > tick Privileged."; fi
  case "$IMAGE" in
    aws/codebuild/amazonlinux-x86_64-standard:*) ok "Build image is $IMAGE" ;;
    *) bad "Build image is $IMAGE" "Edit > Environment > Override image: Amazon Linux, Standard, aws/codebuild/amazonlinux-x86_64-standard:5.0." ;;
  esac
  if [ "$SRC" = "CODEPIPELINE" ]; then ok "Project source is CODEPIPELINE"
  else bad "Project source is $SRC" "Create the project from the pipeline wizard so its source is CodePipeline (Step 6.3)."; fi

  echo "5. CodeBuild role can push to ECR (Step 6.4)"
  # Ask IAM what the role may do. The CLI can print extra empty/"None" lines (paged output),
  # so only lines that contain a decision are used.
  sim() { aws iam simulate-principal-policy --policy-source-arn "$ROLE_ARN" "$@" \
            --query 'EvaluationResults[].[EvalActionName,EvalDecision]' --output text 2>/dev/null \
          | grep -E -i 'allowed|deny' ; }
  RESULTS=$( { sim --action-names ecr:GetAuthorizationToken --resource-arns "*"
               sim --action-names ecr:DescribeRepositories ecr:BatchCheckLayerAvailability ecr:InitiateLayerUpload \
                                  ecr:UploadLayerPart ecr:CompleteLayerUpload ecr:PutImage \
                   --resource-arns "arn:aws:ecr:${REGION}:${ACCOUNT}:repository/${REPO}"; } )
  DENIED=$(printf '%s\n' "$RESULTS" | grep -i 'deny' | cut -f1 | tr '\n' ' ')
  ALLOWED=$(printf '%s\n' "$RESULTS" | grep -c -i 'allowed')
  if [ "$ALLOWED" -lt 7 ] && [ -z "$DENIED" ]; then
    printf '  [INFO] Could not test the role %s (only %s/7 answers; your user needs iam:SimulatePrincipalPolicy).\n         If the Build stage succeeded, the role can push.\n' "${ROLE_ARN##*/}" "$ALLOWED"
  elif [ -n "$DENIED" ]; then
    bad "Role ${ROLE_ARN##*/} is denied: $DENIED" "IAM > Roles > ${ROLE_ARN##*/} > Add permissions > Attach policies > AmazonEC2ContainerRegistryPowerUser."
  else ok "Role ${ROLE_ARN##*/} may log in and push to $REPO ($ALLOWED/7 actions allowed)"; fi
fi

echo "6. Pipeline (Steps 6-7)"
STATE=$(aws_r codepipeline get-pipeline-state --name "$PIPELINE" \
  --query 'stageStates[].[stageName,latestExecution.status]' --output text 2>/dev/null)
if [ -z "$STATE" ]; then echo "  [INFO] Pipeline $PIPELINE not created yet."
else
  while read -r STAGE ST; do
    case "$ST" in
      Succeeded) ok "Stage $STAGE: Succeeded" ;;
      InProgress|None|"") printf '  [INFO] Stage %s: %s\n' "$STAGE" "${ST:-not run yet}" ;;
      *) bad "Stage $STAGE: $ST" "Open the failed action > View details/Logs; the build log prints ERROR and FIX lines." ;;
    esac
  done <<< "$STATE"
fi

echo
echo "Result: $PASS passed, $FAIL failed."
[ "$FAIL" -eq 0 ] && echo "All checks passed. Choose Release change (or Retry) in CodePipeline." || echo "Fix the [FAIL] items, then run this script again."
exit "$FAIL"
