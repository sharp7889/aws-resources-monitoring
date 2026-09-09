# AWS Resource Lifecycle Change Notification

## Description

This SAM-based solution deploys an EventBridge-driven monitoring system that captures AWS resource lifecycle events (Create, Update, Delete operations) and sends structured HTML alert emails directly via Amazon SES through a Lambda function. It helps detect unauthorized or unexpected resource changes in real time across all defined regions.

## Architecture

Event flow:

  [AWS CloudTrail]
       |
       v
  [EventBridge default bus]  <-- IAM events (global, us-east-1 only)
       |                     <-- Regional events forwarded from all regions
       |
  [Central Event Bus]  (resource-change-central-bus, us-east-1)
       |
       v
  [EventBridge Rules]  (one per service: Lambda, EC2, S3, RDS, DynamoDB, KMS)
       |
       v
  [Lambda]  (resource-change-notifier, us-east-1)
       |
       v
  [SES]  --> Formatted HTML email to recipient

Cross-Region Setup:
  1. us-east-1 (Primary)
     - Runs CloudTrail, central event bus, all matching rules, Lambda, SES delivery
     - IAM events are captured here directly (IAM is a global service, us-east-1 only)

  2. All other regions (Regional Stack)
     - Deploys 6 EventBridge rules (Lambda, EC2, S3, RDS, DynamoDB, KMS)
     - Each rule forwards events to the us-east-1 central event bus
     - An IAM role grants cross-region PutEvents permission

## Email Format

Emails are HTML with a colour-coded header per service, a clean detail table, a "Changed by" section with the IAM identity ARN, and a footer.

- **Subject:** AWS IAM — PutRolePolicy (production-account)
- **Header:** Red bar | "AWS IAM · Change Alert" | "PutRolePolicy"
- **Details:** Service, Action, Resource name, Region, Account ID, Time
- **Identity:** IAM ARN of the actor (in monospace)

### Service Colours
- IAM → deep red (#B71C1C)
- Lambda → deep orange (#B84500)
- EC2 → dark blue (#0D47A1)
- S3 → teal (#004D40)
- RDS → deep purple (#4A148C)
- DynamoDB → indigo (#1A237E)
- KMS → orange (#E65100)

## Monitored Actions

### IAM (Global — us-east-1 captures all regions via CloudTrail)
- CreateRole, DeleteRole, UpdateRole
- PutRolePolicy, DeleteRolePolicy, AttachRolePolicy, DetachRolePolicy
- CreateUser, DeleteUser, PutUserPolicy, DeleteUserPolicy
- AttachUserPolicy, DetachUserPolicy
- CreatePolicy, DeletePolicy
- CreateAccessKey, DeleteAccessKey

### Lambda (Regional — each region where regional stack is deployed)
- CreateFunction*, DeleteFunction*, UpdateFunctionConfiguration*

### EC2 (Regional)
- RunInstances, TerminateInstances, StopInstances, StartInstances, RebootInstances
- CreateSecurityGroup, DeleteSecurityGroup
- AuthorizeSecurityGroupIngress, RevokeSecurityGroupIngress
- CreateVolume, DeleteVolume, AttachVolume, DetachVolume

### S3 (Regional)
- CreateBucket, DeleteBucket
- PutBucketPolicy, DeleteBucketPolicy
- PutBucketEncryption, DeleteBucketEncryption
- PutBucketVersioning, PutBucketLogging

### RDS (Regional)
- CreateDBInstance, DeleteDBInstance, ModifyDBInstance, RebootDBInstance
- CreateDBCluster, DeleteDBCluster, ModifyDBCluster
- CreateDBSnapshot, DeleteDBSnapshot

### DynamoDB (Regional)
- CreateTable, DeleteTable, UpdateTable
- CreateGlobalSecondaryIndex, DeleteGlobalSecondaryIndex
- CreateBackup, DeleteBackup

### KMS (Regional)
- CreateKey, ScheduleKeyDeletion, CancelKeyDeletion
- DisableKey, EnableKey, UpdateKeyDescription
- CreateAlias, DeleteAlias

> **Note:** S3 data events (PutObject, DeleteObject, GetObject) are NOT captured. Only management events are monitored. To capture data events, enable them separately in CloudTrail.

## File Structure

- `template.yaml` — Primary stack (us-east-1): CloudTrail, central bus, Lambda function, SES delivery, IAM rules
- `regional-rules.yaml` — Regional stack: EventBridge rules forwarding to central bus
- `src/notify_handler.py` — Lambda function: parses events, builds HTML, sends via SES
- `deploy.sh` — Automated deployment script
- `samconfig.toml` — SAM configuration defaults

### Primary Stack (template.yaml — us-east-1 only)

| Resource | Name | Description |
|----------|------|-------------|
| S3 Bucket | `cloudtrail-resources-alerts-<AccountId>` | Stores CloudTrail logs, 90-day expiry, retained on delete |
| CloudTrail Trail | `iam-management-events-trail` | Multi-region, all management events, streams to EventBridge |
| EventBridge Event Bus | `resource-change-central-bus` | Receives forwarded events from all regional stacks |
| IAM Role | `resource-change-notifier-role` | Grants Lambda permission to call ses:SendEmail |
| Lambda Function | `resource-change-notifier` | Parses event, builds HTML email, sends via SES |
| Lambda Permissions | — | Allows EventBridge (default + central bus) to invoke Lambda |
| EventBridge Rules | `Notify-IAM-Changes` (default bus) | — |
| | `Notify-Lambda/EC2/S3/RDS/DynamoDB/KMS-Changes` (central bus) | — |

### Regional Stack (regional-rules.yaml — deployed to each monitored region)

| Resource | Name | Description |
|----------|------|-------------|
| IAM Role | `EventBridge-Central-Bus-Route-<region>` | Allows EventBridge in this region to PutEvents to central bus |
| EventBridge Rules | `Route-*-to-Central-Bus` | Lambda, EC2, S3, RDS, DynamoDB, KMS rules |

All resources are tagged with: `Delete: Locked`

## Prerequisites

- AWS CLI configured with credentials that have permissions for: IAM, CloudFormation, CloudTrail, EventBridge, Lambda, SES, S3
- AWS SAM CLI installed ([install guide](https://docs.aws.amazon.com/serverless-application-model/latest/developerguide/install-sam-cli.html))
- Sender email address verified in Amazon SES
- If SES account is in sandbox mode: recipient email must also be verified

## SES Email Verification

Before the first deployment, verify your sender email in SES (us-east-1):

```bash
aws ses verify-email-identity \
  --email-address your-sender@example.com \
  --region us-east-1 \
  --profile YOUR_PROFILE
```

If your SES account is still in sandbox mode, also verify the recipient:

```bash
aws ses verify-email-identity \
  --email-address your-recipient@example.com \
  --region us-east-1 \
  --profile YOUR_PROFILE
```

To check sandbox status or request production access:
- AWS Console → SES → Account dashboard → "Request production access"

## Deployment (Automated — Recommended)

Use the provided `deploy.sh` script to deploy all stacks in one command:

```bash
chmod +x deploy.sh
./deploy.sh \
  --profile       YOUR_AWS_PROFILE \
  --account-alias production-account \
  --sender-email  alerts@yourdomain.com \
  --email         you@yourdomain.com
```

### Arguments

| Argument | Description | Required |
|----------|-------------|----------|
| `--profile` | AWS CLI profile name | Yes |
| `--account-alias` | Label shown in email alerts (e.g., prod, dev, staging) | Yes |
| `--sender-email` | SES-verified From address | Yes |
| `--email` | Recipient email address | Yes |

### What the Script Does

1. Deploy primary stack to us-east-1 (SAM packages and uploads Lambda)
2. Fetch Central Event Bus ARN from CloudFormation outputs
3. Deploy regional stack to each of the 10 configured regions
4. Print SES verification reminder commands

### Default Regions

Edit the `REGIONS` array in `deploy.sh` to change:

```
us-east-1, us-east-2, us-west-1, us-west-2,
ap-south-1, ap-northeast-3, ap-northeast-2,
ap-southeast-1, ap-southeast-2, ap-northeast-1
```

## Deployment (Manual)

### Step 1: Deploy Primary Stack in us-east-1

```bash
sam deploy \
  --stack-name resource-change-alerts \
  --template-file template.yaml \
  --parameter-overrides \
      AccountAlias=production-account \
      SenderEmail=alerts@yourdomain.com \
      RecipientEmail=you@yourdomain.com \
  --capabilities CAPABILITY_NAMED_IAM \
  --resolve-s3 \
  --no-confirm-changeset \
  --no-fail-on-empty-changeset \
  --region us-east-1 \
  --profile YOUR_PROFILE
```

**Parameters:**
- `AccountAlias` — Label shown in email subject and body
- `SenderEmail` — Verified SES sender (From address)
- `RecipientEmail` — Alert destination address

### Step 2: Get Central Event Bus ARN

```bash
CENTRAL_BUS_ARN=$(aws cloudformation describe-stacks \
  --stack-name resource-change-alerts \
  --region us-east-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`CentralEventBusArn`].OutputValue' \
  --output text \
  --profile YOUR_PROFILE)

echo "Central Bus ARN: $CENTRAL_BUS_ARN"
```

### Step 3: Deploy Regional Stack to Each Monitored Region

Repeat for every region you want to monitor:

```bash
sam deploy \
  --stack-name resource-change-alerts-regional \
  --template-file regional-rules.yaml \
  --parameter-overrides CentralEventBusArn=$CENTRAL_BUS_ARN \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-confirm-changeset \
  --no-fail-on-empty-changeset \
  --region us-west-2 \
  --profile YOUR_PROFILE
```

## Redeploying / Updating

Both stacks are idempotent. Re-run `deploy.sh` (or the manual commands) to apply any template changes. SAM uses CloudFormation changesets, so only changed resources are updated. The `--no-fail-on-empty-changeset` flag means the script succeeds even if nothing changed.

The `deploy.sh` script handles these pre-existing stack states automatically:

| State | Action |
|-------|--------|
| `DOES_NOT_EXIST` | Fresh deploy |
| `CREATE_COMPLETE` or `UPDATE_COMPLETE` | Update deploy (applies template changes) |
| `CREATE_FAILED`, `ROLLBACK_COMPLETE`, `REVIEW_IN_PROGRESS` | Blocked; script prints manual delete command and skips |
| `ROLLBACK_FAILED`, `DELETE_FAILED`, `UPDATE_ROLLBACK_FAILED` | Blocked; manual intervention required |

## Deletion

Delete regional stacks first, then the primary stack.

### Delete a Regional Stack

```bash
aws cloudformation delete-stack \
  --stack-name resource-change-alerts-regional \
  --region REGION \
  --profile YOUR_PROFILE
```

### Delete Primary Stack (us-east-1)

```bash
aws cloudformation delete-stack \
  --stack-name resource-change-alerts \
  --region us-east-1 \
  --profile YOUR_PROFILE
```

> **Note:** The S3 bucket (`cloudtrail-resources-alerts-<AccountId>`) has `DeletionPolicy: Retain`. It is NOT deleted with the stack. To remove it manually:
>
> ```bash
> aws s3 rb s3://cloudtrail-resources-alerts-ACCOUNT_ID --force --profile YOUR_PROFILE
> ```

## Troubleshooting

### No Emails Received?

1. **Check SES verification**
   - Sender email must be verified in SES (us-east-1)
   - In sandbox mode, recipient must also be verified
   ```bash
   aws ses list-identities --region us-east-1 --profile YOUR_PROFILE
   ```

2. **Check Lambda function logs**
   ```bash
   aws logs tail /aws/lambda/resource-change-notifier \
     --region us-east-1 --profile YOUR_PROFILE --follow
   ```

3. **Check CloudTrail is active**
   - Console: CloudTrail → Trails → iam-management-events-trail → verify IsLogging: true

4. **Check EventBridge rules are ENABLED**
   - Console: EventBridge → Rules → select event bus → confirm all rules are enabled

5. **Check regional stack is deployed**
   - Lambda/EC2/S3/RDS/DynamoDB/KMS events require the regional stack in that region
   ```bash
   aws cloudformation describe-stacks \
     --stack-name resource-change-alerts-regional \
     --region REGION --profile YOUR_PROFILE
   ```

6. **Check Lambda has SES permission**
   - Lambda role must have `ses:SendEmail` on `*`
   - Verify in IAM Console → Roles → resource-change-notifier-role

### Lambda Function Deployed but Emails Not Sending?

- Check Lambda environment variables: `ACCOUNT_ALIAS`, `SENDER_EMAIL`, `RECIPIENT_EMAIL`
```bash
aws lambda get-function-configuration \
  --function-name resource-change-notifier \
  --region us-east-1 --profile YOUR_PROFILE
```

### Lambda Function Errors?

```bash
aws logs tail /aws/lambda/resource-change-notifier \
  --region us-east-1 --profile YOUR_PROFILE
```

## Alert Volume

Expected daily alert volume depends on account activity:

- **IAM only** (primary stack, no regional stacks): 10–50 alerts/day
- **All services** (primary + all 10 regional stacks): 50–500+ alerts/day

To reduce volume:

- Deploy regional stacks only to high-traffic regions
- Remove low-priority actions from EventBridge event patterns in the templates
- Add an SES filter or Lambda condition to suppress known-safe events

## Tamper Protection

All deployed resources are tagged with `Delete: Locked`. This includes:
- S3 bucket for CloudTrail logs
- CloudTrail trail
- EventBridge central event bus
- Lambda function (resource-change-notifier)
- Lambda execution role
- EventBridge rules (7 central + up to 7 regional routing rules)
- Regional EventBridge roles

To prevent users from disabling this monitoring, attach the following deny policy to IAM users or roles that should not be able to modify monitoring resources:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DenyDeletionOfLockedResources",
            "Effect": "Deny",
            "Action": [
                "iam:DeleteRole",
                "iam:DeleteRolePolicy",
                "lambda:DeleteFunction",
                "lambda:DeleteEventSourceMapping",
                "cloudtrail:DeleteTrail",
                "events:DeleteRule",
                "events:DeleteEventBus",
                "s3:DeleteBucket",
                "s3:DeleteBucketPolicy"
            ],
            "Resource": "*",
            "Condition": {
                "StringEquals": {
                    "aws:ResourceTag/Delete": "Locked"
                }
            }
        },
        {
            "Sid": "DenyRemovingOrAddingProtectionTag",
            "Effect": "Deny",
            "Action": [
                "iam:UntagRole",
                "iam:TagRole",
                "events:UntagResource",
                "events:TagResource",
                "lambda:UntagResource",
                "lambda:TagResource",
                "cloudtrail:RemoveTags",
                "cloudtrail:AddTags",
                "s3:PutBucketTagging",
                "s3:TagResource",
                "s3:UntagResource"
            ],
            "Resource": "*",
            "Condition": {
                "ForAnyValue:StringEquals": {
                    "aws:TagKeys": [
                        "Delete"
                    ]
                }
            }
        }
    ]
}
```

## Author

- **Created by:** Harpreet
- **Updated:** 2026-09-09 (Switched from SNS to Lambda + SES with HTML email)
