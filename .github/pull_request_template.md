### Summary

### Checklist

- [ ] `npm run lint`, `npm run format:check` and `npm test` pass locally
- [ ] Apex or metadata changes: `scripts/validate-scratch.sh` result and coverage reported below
- [ ] Every new query and DML states its access mode (`USER_MODE` / `SYSTEM_MODE`)
- [ ] No provider-specific logic in Salesforce code; protocol changes update docs, mock, conformance checker and tests
- [ ] Documentation and CHANGELOG updated
- [ ] Only synthetic data; no tokens, org IDs, usernames or customer documents

### Scratch org evidence (if applicable)
