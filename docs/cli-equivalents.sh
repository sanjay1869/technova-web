#!/bin/bash
# shellcheck disable=SC2317,SC2016  # reference file: commands after "exit 0" are meant to be copied, not run
# =============================================================
# docs/cli-equivalents.sh - AWS CLI versions of the key console steps
# -------------------------------------------------------------
# REFERENCE ONLY. The lab uses the console. These commands show
# what each console step does behind the scenes. Run them one
# block at a time in AWS CloudShell (Region: ap-south-1) from the
# folder that contains this project (so file:// paths resolve).
# =============================================================
echo "Reference file - read it, then copy one block at a time."
exit 0

export AWS_REGION=ap-south-1
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
VPC_ID=$(aws ec2 describe-vpcs --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNETS=$(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true \
  Name=availability-zone,Values=ap-south-1a,ap-south-1b --query 'Subnets[].SubnetId' --output text)

# ---- Step 3: GitHub connection (finish the GitHub hand-shake in the console) ----
aws codeconnections create-connection --provider-type GitHub --connection-name technova-github

# ---- Step 4: ECR repository (immutable tags) + lifecycle policy ----
aws ecr create-repository --repository-name technova-web \
  --image-tag-mutability IMMUTABLE \
  --encryption-configuration encryptionType=AES256
aws ecr put-lifecycle-policy --repository-name technova-web \
  --lifecycle-policy-text file://ecr/lifecycle-policy.json

# ---- Step 5: task execution role + log group ----
aws iam create-role --role-name ecsTaskExecutionRole \
  --assume-role-policy-document file://iam/ecs-tasks-trust-policy.json
aws iam attach-role-policy --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
aws logs create-log-group --log-group-name /ecs/technova-web
aws logs put-retention-policy --log-group-name /ecs/technova-web --retention-in-days 7

# ---- Step 6.4: let CodeBuild push to ECR (AWS managed policy - nothing to edit) ----
aws iam attach-role-policy --role-name codebuild-technova-web-build-service-role \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser
# Production alternative (least privilege, scoped to one repository):
#   aws iam put-role-policy --role-name codebuild-technova-web-build-service-role \
#     --policy-name technova-ecr-push --policy-document file://iam/codebuild-ecr-push-policy.json

# ---- Step 8: security groups ----
ALB_SG=$(aws ec2 create-security-group --group-name technova-alb-sg \
  --description "TechNova ALB - HTTP from internet" --vpc-id "$VPC_ID" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 80 --cidr 0.0.0.0/0
ECS_SG=$(aws ec2 create-security-group --group-name technova-ecs-sg \
  --description "TechNova ECS tasks - 8080 from ALB only" --vpc-id "$VPC_ID" --query GroupId --output text)
aws ec2 authorize-security-group-ingress --group-id "$ECS_SG" --protocol tcp --port 8080 --source-group "$ALB_SG"

# ---- Step 9: target group + Application Load Balancer + listener ----
TG_BLUE=$(aws elbv2 create-target-group --name technova-tg-blue --protocol HTTP --port 8080 \
  --target-type ip --vpc-id "$VPC_ID" --health-check-path /health \
  --health-check-interval-seconds 10 --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 2 --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 modify-target-group-attributes --target-group-arn "$TG_BLUE" \
  --attributes Key=deregistration_delay.timeout_seconds,Value=30
# shellcheck disable=SC2086
ALB_ARN=$(aws elbv2 create-load-balancer --name technova-alb --type application --scheme internet-facing \
  --subnets $SUBNETS --security-groups "$ALB_SG" --query 'LoadBalancers[0].LoadBalancerArn' --output text)
aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
  --default-actions Type=forward,TargetGroupArn="$TG_BLUE"

# ---- Steps 10-12: cluster, task definition (paste the role ARN and image URI first), service ----
aws ecs create-cluster --cluster-name technova-cluster
aws ecs register-task-definition --cli-input-json file://ecs/taskdef-console.json
aws ecs create-service --cluster technova-cluster --service-name technova-web-svc \
  --task-definition technova-web --desired-count 2 --launch-type FARGATE \
  --deployment-configuration "deploymentCircuitBreaker={enable=true,rollback=true},maximumPercent=200,minimumHealthyPercent=100" \
  --health-check-grace-period-seconds 30 \
  --load-balancers "targetGroupArn=${TG_BLUE},containerName=technova-web,containerPort=8080" \
  --network-configuration "awsvpcConfiguration={subnets=[${SUBNETS// /,}],securityGroups=[${ECS_SG}],assignPublicIp=ENABLED}"

# ---- Step 13 / tests: run and watch the pipeline ----
aws iam put-role-policy --role-name AWSCodePipelineServiceRole-ap-south-1-technova-web-pipeline \
  --policy-name technova-ecs-deploy --policy-document file://iam/codepipeline-ecs-deploy-policy.json
aws codepipeline start-pipeline-execution --name technova-web-pipeline
aws codepipeline get-pipeline-state --name technova-web-pipeline \
  --query 'stageStates[].[stageName,latestExecution.status]' --output table

# ---- Part B: green target group, test listener, CodeDeploy ----
TG_GREEN=$(aws elbv2 create-target-group --name technova-tg-green --protocol HTTP --port 8080 \
  --target-type ip --vpc-id "$VPC_ID" --health-check-path /health \
  --health-check-interval-seconds 10 --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 --unhealthy-threshold-count 2 --matcher HttpCode=200 \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 8080 \
  --default-actions Type=forward,TargetGroupArn="$TG_GREEN"
MY_IP="203.0.113.10"   # replace with YOUR public IP (search "what is my IP" on your laptop)
aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" --protocol tcp --port 8080 --cidr "${MY_IP}/32"
L80=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`80`].ListenerArn' --output text)
L8080=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --query 'Listeners[?Port==`8080`].ListenerArn' --output text)
aws iam create-role --role-name technova-codedeploy-ecs-role \
  --assume-role-policy-document file://iam/codedeploy-trust-policy.json
aws iam attach-role-policy --role-name technova-codedeploy-ecs-role \
  --policy-arn arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS
aws deploy create-application --application-name technova-web-app --compute-platform ECS
aws deploy create-deployment-group --application-name technova-web-app \
  --deployment-group-name technova-web-dg \
  --service-role-arn "arn:aws:iam::${ACCOUNT}:role/technova-codedeploy-ecs-role" \
  --deployment-config-name CodeDeployDefault.ECSCanary10Percent5Minutes \
  --deployment-style deploymentType=BLUE_GREEN,deploymentOption=WITH_TRAFFIC_CONTROL \
  --blue-green-deployment-configuration "deploymentReadyOption={actionOnTimeout=STOP_DEPLOYMENT,waitTimeInMinutes=30},terminateBlueInstancesOnDeploymentSuccess={action=TERMINATE,terminationWaitTimeInMinutes=5}" \
  --ecs-services clusterName=technova-cluster,serviceName=technova-web-bg-svc \
  --load-balancer-info "targetGroupPairInfoList=[{targetGroups=[{name=technova-tg-blue},{name=technova-tg-green}],prodTrafficRoute={listenerArns=[${L80}]},testTrafficRoute={listenerArns=[${L8080}]}}]"
aws iam put-role-policy --role-name AWSCodePipelineServiceRole-ap-south-1-technova-web-pipeline \
  --policy-name technova-codedeploy-deploy --policy-document file://iam/codepipeline-codedeploy-policy.json

# Approve the traffic shift after testing on port 8080 (same as the console button "Reroute traffic"):
#   aws deploy continue-deployment --deployment-id d-XXXXXXXXX --deployment-wait-type READY_WAIT
# Roll back a running deployment (same as "Stop and roll back deployment"):
#   aws deploy stop-deployment --deployment-id d-XXXXXXXXX --auto-rollback-enabled
