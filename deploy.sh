#!/bin/bash

  log() { printf '\x1b[32m%s\x1b[0m\n' "$*"; }
error() { printf '\x1b[31m%s\x1b[0m\n' "$*"; }

set -eu -o pipefail
cd "$(dirname "$0")"

BUCKET_NAME=cf-templates-awslabs-$(aws configure get region)
S3_PREFIX=aws-dx-monitor
TEMPLATE=template.yaml
PACKAGED_TEMPLATE="packaged-$TEMPLATE"
STACK_NAME=aws-dx-monitor
ALARM_NAMESPACE=AWSx/DirectConnect

deploy_stack() {
    local stack_name="$1"
    shift

    if ! aws cloudformation deploy --stack-name "$stack_name" --no-fail-on-empty-changeset "$@" ; then
        # dump the failure events
        aws cloudformation describe-stack-events \
            --stack-name "$stack_name" \
            --query 'StackEvents[].[Timestamp,EventId,ResourceStatusReason]' \
            --output text 2>/dev/null \
        | grep -i -B999 -m1 'user initiated' \
        | tac | grep -i fail >&2
        return 1
    fi

    aws cloudformation describe-stacks --stack-name "$stack_name" --query 'Stacks[].Outputs' --output table
}

log 'Creating S3 bucket'
aws s3api head-bucket --bucket "${BUCKET_NAME}" >/dev/null || aws s3 mb "s3://${BUCKET_NAME}"

log 'SAM Build'
sam build

log 'SAM Validate'
sam validate

log 'Deploying SAM template stack'
sam deploy --stack-name aws-dx-monitor  \
           --s3-bucket ${BUCKET_NAME} \
           --no-fail-on-empty-changeset \
           --capabilities CAPABILITY_IAM

#
#log 'Uploading lambda assets'
#aws cloudformation package \
#    --template-file "$TEMPLATE" \
#    --s3-bucket "${BUCKET_NAME}" \
#    --s3-prefix "${S3_PREFIX}" \
#    --output-template-file "${PACKAGED_TEMPLATE}"
#
#log 'Deploying stack'
#deploy_stack "$STACK_NAME" --template-file "${PACKAGED_TEMPLATE}" --capabilities CAPABILITY_IAM

make_cw_alarm_template() {
    cat <<EOF
---
AWSTemplateFormatVersion: "2010-09-09"

Parameters:
  Statistic: {Type: String}
  MetricName: {Type: String}
  ComparisonOperator: {Type: String}
  Threshold: {Type: Number}
  Period: {Type: Number}
  Namespace: {Type: String}
  Dimension: {Type: String}
  SNSTopic: {Type: String}
  AlarmName: {Type: String}

Resources:
EOF

    for resource in "$@"; do
        name="$(<<<"$resource" tr -dc '[:alnum:][:space:]')"
        cat <<EOF
  ${name}Alarm:
    Type: AWS::CloudWatch::Alarm
    Properties:
      AlarmName: !Sub "${resource}-\${AlarmName}"
      AlarmDescription: !Sub "${resource}-\${AlarmName}"
      Statistic: !Ref Statistic
      MetricName: !Ref MetricName
      ComparisonOperator: !Ref ComparisonOperator
      Threshold: !Ref Threshold
      Period: !Ref Period
      EvaluationPeriods: 1
      Namespace: !Ref Namespace
      Dimensions:
        - Name: !Ref Dimension
          Value: $resource
      AlarmActions:
        - !Ref SNSTopic

EOF
    done
}

log 'Generate temp Alarm CFN template'
template="$(mktemp)"
trap 'rm -rf $template' EXIT
log 'Fetching SNS Topic for Alarms'
sns_topic="$(aws sns list-topics --query 'Topics[].[TopicArn]' --output text | grep -m1 managedservices)" || error "No 'managedservices' SNS topic configured in this environment!" && exit 1

log 'Creating alarms for virtual interfaces'
ifaces="$(aws directconnect describe-virtual-interfaces --query 'virtualInterfaces[].[virtualInterfaceId]' --output text)"
make_cw_alarm_template $ifaces > "$template"
deploy_stack "virtual-interface-alarms" \
    --template-file "$template" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        Statistic=Maximum \
        MetricName=VirtualInterfaceState \
        ComparisonOperator=GreaterThanOrEqualToThreshold \
        Threshold=5 \
        Period=3600 \
        Namespace="$ALARM_NAMESPACE" \
        Dimension=VirtualInterfaceId \
        SNSTopic="$sns_topic" \
        AlarmName=virtual-interface-down \

log 'Creating alarms for connections'
conns="$(aws directconnect describe-connections --query 'connections[].[connectionId]' --output text)"
make_cw_alarm_template $conns > "$template"
deploy_stack "direct-connection-alarms" \
    --template-file "$template" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        Statistic=Maximum \
        MetricName=ConnectionState \
        ComparisonOperator=GreaterThanOrEqualToThreshold \
        Threshold=5 \
        Period=3600 \
        Namespace="$ALARM_NAMESPACE" \
        Dimension=ConnectionId \
        SNSTopic="$sns_topic" \
        AlarmName=direct-connection-alarms \

log 'Creating alarms for virtual gateway'
gateways="$(aws directconnect describe-virtual-gateways --query 'virtualGateways[].[virtualGatewayId]' --output text)"
make_cw_alarm_template $gateways > "$template"
deploy_stack "virtual-gateway-alarms" \
    --template-file "$template" \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides \
        Statistic=Maximum \
        MetricName=VirtualGatewayState \
        ComparisonOperator=GreaterThanOrEqualToThreshold \
        Threshold=3 \
        Period=3600 \
        Namespace="$ALARM_NAMESPACE" \
        Dimension=VirtualGatewayId \
        SNSTopic="$sns_topic" \
        AlarmName=virtual-gateway-alarms \
