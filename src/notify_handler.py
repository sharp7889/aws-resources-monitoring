import os
from datetime import datetime

import boto3

ses = boto3.client("ses", region_name="us-east-1")

# ── Per-service display metadata ───────────────────────────────────────────────
SERVICE_META = {
    "lambda.amazonaws.com":   {"name": "Lambda",   "color": "#B84500", "bg": "#FFF3E0"},
    "ec2.amazonaws.com":      {"name": "EC2",       "color": "#0D47A1", "bg": "#E3F2FD"},
    "iam.amazonaws.com":      {"name": "IAM",       "color": "#B71C1C", "bg": "#FFEBEE"},
    "s3.amazonaws.com":       {"name": "S3",        "color": "#004D40", "bg": "#E0F2F1"},
    "rds.amazonaws.com":      {"name": "RDS",       "color": "#4A148C", "bg": "#F3E5F5"},
    "dynamodb.amazonaws.com": {"name": "DynamoDB",  "color": "#1A237E", "bg": "#E8EAF6"},
    "kms.amazonaws.com":      {"name": "KMS",       "color": "#E65100", "bg": "#FBE9E7"},
}


# ── Resource name extractors ───────────────────────────────────────────────────

def _ec2_resource(params):
    if "instancesSet" in params:
        items = params["instancesSet"].get("items", [])
        if items:
            return items[0].get("instanceId")
    return params.get("groupId") or params.get("volumeId")


def _extract_resource(service, params):
    if not params:
        return None
    extractors = {
        "lambda.amazonaws.com":   lambda p: p.get("functionName"),
        "s3.amazonaws.com":       lambda p: p.get("bucketName"),
        "dynamodb.amazonaws.com": lambda p: p.get("tableName"),
        "iam.amazonaws.com":      lambda p: (
            p.get("roleName") or p.get("userName")
            or p.get("policyName") or p.get("groupName")
        ),
        "rds.amazonaws.com":      lambda p: (
            p.get("dBInstanceIdentifier")
            or p.get("dBClusterIdentifier")
            or p.get("dBSnapshotIdentifier")
        ),
        "kms.amazonaws.com":      lambda p: p.get("keyId") or p.get("aliasName"),
        "ec2.amazonaws.com":      _ec2_resource,
    }
    fn = extractors.get(service)
    return fn(params) if fn else None


# ── HTML email builder ─────────────────────────────────────────────────────────

def _row(label, value, color="#37474F", mono=False):
    """Render a single detail row. Returns empty string if value is falsy."""
    if not value:
        return ""
    mono_style = "font-family:'Courier New',Courier,monospace;font-size:12px;" if mono else ""
    return (
        "<tr>"
        f'<td style="padding:11px 20px 11px 32px;font-size:12px;font-weight:600;color:#90A4AE;'
        f'white-space:nowrap;width:120px;border-bottom:1px solid #F5F7FA;vertical-align:top;">{label}</td>'
        f'<td style="padding:11px 32px 11px 0;font-size:13px;color:{color};'
        f'border-bottom:1px solid #F5F7FA;word-break:break-all;{mono_style}">{value}</td>'
        "</tr>"
    )


def _build_html(meta, action, account_alias, account_id, region, time_fmt,
                who, user_type, resource):
    color = meta["color"]
    bg    = meta["bg"]
    name  = meta["name"]

    resource_row  = _row("Resource", resource, "#212121") if resource else ""
    user_type_tag = (
        f'<div style="margin-top:6px;font-size:11px;color:#90A4AE;">'
        f'Identity type: <strong style="color:#607D8B;">{user_type}</strong></div>'
    ) if user_type else ""

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>AWS {name} Alert</title>
</head>
<body style="margin:0;padding:0;background:#EEF2F7;
             font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;">
<table width="100%" cellpadding="0" cellspacing="0"
       style="background:#EEF2F7;padding:36px 16px;">
  <tr><td align="center">
  <table width="600" cellpadding="0" cellspacing="0"
         style="max-width:600px;width:100%;">

    <!-- ── Header ── -->
    <tr><td style="background:{color};border-radius:10px 10px 0 0;padding:26px 32px;">
      <table width="100%" cellpadding="0" cellspacing="0"><tr>
        <td>
          <div style="font-size:10px;font-weight:700;color:rgba(255,255,255,0.6);
                      letter-spacing:2px;text-transform:uppercase;margin-bottom:8px;">
            AWS {name} &nbsp;&middot;&nbsp; Change Alert
          </div>
          <div style="font-size:22px;font-weight:700;color:#fff;line-height:1.2;">
            {action}
          </div>
        </td>
        <td align="right" style="vertical-align:top;padding-left:16px;">
          <div style="background:rgba(255,255,255,0.15);border-radius:8px;
                      padding:9px 16px;text-align:center;">
            <div style="font-size:10px;font-weight:700;color:rgba(255,255,255,0.65);
                        letter-spacing:1.5px;text-transform:uppercase;margin-bottom:3px;">
              Account
            </div>
            <div style="font-size:13px;font-weight:700;color:#fff;">{account_alias}</div>
          </div>
        </td>
      </tr></table>
    </td></tr>

    <!-- ── Detail rows ── -->
    <tr><td style="background:#fff;padding:0;">
      <table width="100%" cellpadding="0" cellspacing="0">
        {_row("Service",    f"AWS {name}", color)}
        {_row("Action",     action, color)}
        {resource_row}
        {_row("Region",     region)}
        {_row("Account ID", account_id)}
        {_row("Time",       time_fmt)}
      </table>
    </td></tr>

    <!-- ── Changed by ── -->
    <tr><td style="background:{bg};padding:18px 32px;border-top:2px solid {color};">
      <div style="font-size:10px;font-weight:700;color:{color};
                  letter-spacing:2px;text-transform:uppercase;margin-bottom:10px;">
        Changed by
      </div>
      <div style="background:#fff;border:1px solid #E0E0E0;border-radius:6px;
                  padding:11px 14px;font-size:12px;
                  font-family:'Courier New',Courier,monospace;
                  color:#37474F;word-break:break-all;line-height:1.7;">
        {who}
      </div>
      {user_type_tag}
    </td></tr>

    <!-- ── Footer ── -->
    <tr><td style="background:#ECEFF1;border-radius:0 0 10px 10px;padding:14px 32px;">
      <p style="margin:0;font-size:11px;color:#90A4AE;line-height:1.6;">
        Automated alert &nbsp;&middot;&nbsp;
        <strong style="color:#607D8B;">resource-change-alerts</strong>
        &nbsp;&middot;&nbsp; {region} &nbsp;&middot;&nbsp; {time_fmt}
      </p>
    </td></tr>

  </table>
  </td></tr>
</table>
</body>
</html>"""


def _build_text(name, action, account_alias, account_id, region, time_fmt,
                who, resource):
    lines = [
        f"AWS {name} Change Alert  |  {account_alias}",
        "--------------------------------------------",
        f"Service    : AWS {name}",
        f"Action     : {action}",
    ]
    if resource:
        lines.append(f"Resource   : {resource}")
    lines += [
        f"Region     : {region}",
        f"Account ID : {account_id}",
        f"Time       : {time_fmt}",
        "--------------------------------------------",
        f"Changed by : {who}",
        "--------------------------------------------",
    ]
    return "\n".join(lines)


# ── Lambda entry point ─────────────────────────────────────────────────────────

def lambda_handler(event, context):
    detail        = event.get("detail", {})
    source        = event.get("source", "")
    event_source  = detail.get("eventSource", source)
    action        = detail.get("eventName", "Unknown")
    region        = detail.get("awsRegion", event.get("region", ""))
    account_id    = detail.get("recipientAccountId", event.get("account", ""))
    user_identity = detail.get("userIdentity", {})
    who           = user_identity.get("arn", "Unknown")
    user_type     = user_identity.get("type", "")
    req_params    = detail.get("requestParameters") or {}
    time_raw      = event.get("time", "")

    account_alias   = os.environ.get("ACCOUNT_ALIAS", account_id)
    sender_email    = os.environ["SENDER_EMAIL"]
    recipient_email = os.environ["RECIPIENT_EMAIL"]

    meta = SERVICE_META.get(event_source, {
        "name":  event_source.split(".")[0].upper() if event_source else "AWS",
        "color": "#37474F",
        "bg":    "#ECEFF1",
    })

    try:
        dt       = datetime.fromisoformat(time_raw.replace("Z", "+00:00"))
        time_fmt = dt.strftime("%d %b %Y, %H:%M:%S UTC")
    except Exception:
        time_fmt = time_raw or "Unknown"

    resource = _extract_resource(event_source, req_params)
    subject  = f"AWS {meta['name']} — {action} ({account_alias})"

    html_body = _build_html(
        meta, action, account_alias, account_id,
        region, time_fmt, who, user_type, resource,
    )
    text_body = _build_text(
        meta["name"], action, account_alias, account_id,
        region, time_fmt, who, resource,
    )

    ses.send_email(
        Source=sender_email,
        Destination={"ToAddresses": [recipient_email]},
        Message={
            "Subject": {"Data": subject,   "Charset": "UTF-8"},
            "Body": {
                "Text": {"Data": text_body, "Charset": "UTF-8"},
                "Html": {"Data": html_body, "Charset": "UTF-8"},
            },
        },
    )
    return {"statusCode": 200}
