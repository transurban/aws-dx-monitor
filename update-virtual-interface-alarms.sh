#!/bin/bash

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

template="$(mktemp)"

echo 'Querying virtual interfaces'
ifaces="$(aws directconnect describe-virtual-interfaces --query 'virtualInterfaces[].[virtualInterfaceId]' --output text)"

echo 'Generating CloudFormation Template'
make_cw_alarm_template $ifaces > "$template"

cat "$template"
exit 0
echo 'Updating Cloudformation Stack virtual-interface-alarms'
aws cloudformation deploy \
    --stack-name virtual-interface-alarms \
    --template-file $template \
    --capabilities CAPABILITY_IAM \
    --parameter-overrides ParameterKey="AlarmName",UsePreviousValue=true \
    ParameterKey="ComparisonOperator",UsePreviousValue=true \
    ParameterKey="Dimension",UsePreviousValue=true \
    ParameterKey="MetricName",UsePreviousValue=true \
    ParameterKey="Namespace",UsePreviousValue=true \
    ParameterKey="Period",UsePreviousValue=true \
    ParameterKey="SNSTopic",UsePreviousValue=true \
    ParameterKey="Statistic",UsePreviousValue=true \
    ParameterKey="Threshold",UsePreviousValue=true

echo "To check the status of the CloudFormation Stack please navigate to the AWS Console."

