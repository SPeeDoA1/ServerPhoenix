# ServerPhoenix - Troubleshooting Guide

## Issue: Workflow Stops After Webhook

### Problem
The n8n workflow is activated and receives the webhook, but stops at the SSH nodes without executing.

### Root Cause
**n8n's SSH node does not support dynamic credential selection.** The workflow was designed to accept credential names in the webhook payload like:
```json
{
  "source": {"host": "...", "user": "...", "credential": "my-ssh-cred"},
  "destination": {"host": "...", "user": "...", "credential": "another-cred"}
}
```

However, n8n requires SSH credentials to be **pre-configured** in each SSH node at design time. You cannot pass credential references dynamically through webhook data.

### Solution Options

#### Option 1: Use Pre-Configured SSH Credentials (Recommended for n8n)

**Steps:**
1. In n8n, go to **Settings → Credentials**
2. Create two SSH credentials:
   - Name: `source-server-ssh`
   - Name: `dest-server-ssh`
3. In the workflow, manually edit each SSH node:
   - Select the credential from the dropdown
   - Cannot be dynamic
4. This means you need **one workflow per server pair**

**Pros:** Works with n8n's native SSH nodes
**Cons:** Not flexible - need multiple workflows for different servers

---

#### Option 2: Pass Passwords Directly in Webhook (Simpler)

Use `sshpass` with Execute Command nodes instead of SSH nodes.

**Webhook payload:**
```json
{
  "source": {
    "host": "142.93.170.61",
    "user": "root",
    "password": "your-password-here"
  },
  "destination": {
    "host": "178.128.10.80",
    "user": "root",
    "password": "your-password-here"
  }
}
```

**Requirements on n8n server:**
```bash
sudo apt install sshpass
```

**Import:** Use `workflow-with-passwords.json` instead of `workflow.json`

**Pros:** Fully dynamic - one workflow for all servers
**Cons:** Passwords in webhook payload (use HTTPS)

---

#### Option 3: Manual Server-to-Server Approach (No n8n in the middle)

Instead of routing the backup through n8n, have source server SCP directly to destination.

**Modify Transfer node:**
```bash
# On source server:
sshpass -p '$DEST_PASSWORD' scp -o StrictHostKeyChecking=no \
  /tmp/full-server-backup.tar.gz \
  $DEST_USER@$DEST_HOST:/tmp/
```

---

## Current Workflow Status

Your current `workflow.json` uses SSH nodes with dynamic credentials that won't work.

### Quick Fix: Use Option 2

1. Install sshpass on n8n server:
```bash
sudo apt install sshpass -y
```

2. Import `workflow-with-passwords.json` (already created)

3. Test with:
```bash
curl -X POST https://n8n.athariq.co/webhook/migrate-server \
  -H "Content-Type: application/json" \
  -d '{
    "source": {
      "host": "142.93.170.61",
      "user": "root",
      "password": "qinzat-3Mabqo-sekzas"
    },
    "destination": {
      "host": "178.128.10.80",
      "user": "root",
      "password": "qinzat-3Mabqo-sekzas"
    }
  }'
```

---

## Debugging

To see actual n8n execution errors:
1. Go to n8n UI → Executions tab
2. Click on the failed execution
3. Check which node failed and see the error message

Or check logs:
```bash
pm2 logs n8n --lines 100
```
