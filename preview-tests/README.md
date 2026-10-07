# Preview release lane

Production metadata stays at API 67.0 in `force-app/`. This directory only holds
the scratch definition for the next Salesforce preview release so the same
source can be deployed and tested there early:

```bash
DEV_HUB_ALIAS=my-hub KEEP_SCRATCH=1 bash scripts/validate-preview.sh
```

Preview results never become a production dependency and do not replace the
API 67 release gate.
