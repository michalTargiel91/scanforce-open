# Moving from the original ScanForce

ScanForce Open is the open-source successor to the original ScanForce project.
**The original ScanForce implementation has been retired.** Its managed
packages (`ScanForcePackage`, `ScanForcePackageV2`, `ScanForcePackageV3`,
namespace `scanforce`), its OCR backend and its OAuth-based org registration are
no longer developed, supported or operated.

ScanForce Open was rebuilt from scratch around a provider-neutral protocol and
the current Salesforce security model. It shares the name and the purpose, not
the code.

| | Original ScanForce | ScanForce Open |
|---|---|---|
| Distribution | Managed package, `scanforce` namespace | Source (Apache-2.0), no namespace |
| Backend | One proprietary OCR backend | Any `/connect/v1` provider; DocSolved.ai optional |
| Authentication | Org registration with OAuth client credentials stored in custom metadata | Salesforce Named + External Credential, secrets only in the credential store |
| Data model | `Document__c`, `Invoice__c`, `Invoice_Line_Item__c`, mapping objects | One private `Document Processing Job` per File version; results as compact JSON; optional field-mapping metadata |
| File handling | Package-specific processing | Standard Salesforce Files, raw upload from Salesforce, no public links |
| Package dependencies | Required | None. **Legacy packages are not required and must not be installed for ScanForce Open.** |

## Migrating

There is no in-place upgrade and no data dependency between the two.

1. **Install ScanForce Open** in a sandbox first ([install](install.md)). It does
   not read or modify any `scanforce__` component.
2. **Choose a provider**: [DocSolved.ai](provider-docsolved.md) or
   [your own](provider-custom.md). The retired ScanForce backend is not a
   ScanForce Open provider.
3. **Recreate field mappings**: if you mapped extracted invoice data into your
   own objects or fields, define equivalent
   [field mappings](developer.md#field-mappings) or a Flow using **Get
   Extracted Value**. Result keys come from your provider, not from the old
   `Invoice__c` fields.
4. **Recreate automation** that reacted to the old objects so that it reacts to
   Document Processing Job status changes instead.
5. **Keep historical data** where it is, or export `scanforce__` records with
   Data Export or Data Loader for archival before uninstalling the old package.
   Documents themselves are standard Salesforce Files and remain available.
6. **Retire the old integration**: uninstall the managed package after
   archiving, delete its Remote Site Settings, and revoke any credentials it
   used. Never reuse old ScanForce credentials or copy them into ScanForce Open.

## Users who did not use the original ScanForce

Nothing here applies. Start with the [README](../README.md).
