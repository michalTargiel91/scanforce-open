# Example record page

`SfdcDcx_Opportunity_Record_Page` is an Opportunity Lightning record page with
the **ScanForce Open Record Documents** component in the sidebar, configured to
process attached files as `invoice` documents. It pairs with the sample
[field mappings](../field-mappings/README.md).

```bash
sf project deploy start --target-org YOUR_ORG --source-dir examples/record-page
```

Deploying does not change any existing page. Activate it in Setup → Lightning
App Builder → *Opportunity with ScanForce Open* → **Activation** (org default,
app default or per profile), or simply add the component to your own record
pages: it works on any object.
