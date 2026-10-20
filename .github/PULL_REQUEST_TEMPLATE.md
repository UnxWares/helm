## Description

<!-- What does this change and why? -->

## Related issues

<!-- Fixes #123 -->

## Checklist

- [ ] Chart `version` bumped following calendar versioning (`year.month.number`)
- [ ] `artifacthub.io/changes` annotation updated in `Chart.yaml`
- [ ] `artifacthub.io/images` annotation matches the images in `values.yaml`
- [ ] `values.schema.json` regenerated (`./generate-schemas.sh`) and README updated
- [ ] `helm lint --strict` and `ct lint --config ct.yaml` pass locally

## Breaking changes

<!-- List them with the migration steps, or write "None". -->
