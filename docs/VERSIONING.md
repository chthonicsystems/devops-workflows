# Versioning

`chthonicsystems/devops-workflows` follows the same SemVer + git-tag
versioning model as other Chthonic shared libraries (per
[RFC 0002](https://github.com/chthonicsystems/architecture/blob/main/rfcs/0002-shared-library-strategy.md)),
adapted for git-tag-based GitHub Actions reusable workflows.

## Tag scheme

Two tags are pushed for every release:

| Tag | Form | Auto-updates? | Caller use |
|---|---|---|---|
| **Floating major** | `v0`, `v1`, `v2`, … | Yes — moves on every minor + patch release within that major | `@v0` |
| **Exact version** | `v0.1.0`, `v0.1.1`, `v0.2.0`, `v1.0.0`, … | No | `@v0.1.0` |

(Both annotated tags pointing at the same commit.)

## Recommended caller pinning

```yaml
# RECOMMENDED — picks up minor/patch fixes automatically
uses: chthonicsystems/devops-workflows/.github/workflows/deploy-beta.yml@v0

# RIGOROUS — exact version pin; opt out of fix forwards
uses: chthonicsystems/devops-workflows/.github/workflows/deploy-beta.yml@v0.1.0

# DISCOURAGED — moving target without semver ceiling
uses: chthonicsystems/devops-workflows/.github/workflows/deploy-beta.yml@main
```

## SemVer policy

- **`0.x.y`** while no sister-product (MarineDeck, FlowLift, PetCare
  OS) has GAed in production using this repo. We may break the
  workflow / composite API freely; bump minor for additions, patch
  for fixes. Callers pin `@v0`.
- **`1.0.0`** when the first sister-product GAs in production
  consuming this repo. From `1.0.0` onwards, breaking changes to the
  workflow / composite-action API surface require a major-version bump.
- Workflow / composite **inputs** are part of the API surface.
  Adding optional inputs with defaults is a minor bump. Removing or
  renaming inputs, or making an existing input required when it
  wasn't, is a breaking change.
- **Secrets** consumed via `secrets: inherit` are also part of the
  contract. Adding a new required secret is a breaking change (callers
  must define it before consuming the new version).
- **Outputs** are part of the API surface. Removing or renaming
  outputs is breaking.

## Bump checklist

When cutting a new release:

1. Land all changes on `main`. Verify the smoke `Test composites`
   workflow runs green.
2. Decide the bump (major / minor / patch). For pre-1.0 additions,
   bump the minor (`0.1.0` → `0.2.0`).
3. Tag both the floating major and the exact version on the same SHA:
   ```bash
   git checkout main
   git pull
   git tag -a v0.2.0 -m "Release 0.2.0"
   git tag -a v0 -m "Floating v0 → 0.2.0" --force
   git push origin v0.2.0
   git push origin v0 --force
   ```
4. Update [`docs/REUSABLE-WORKFLOWS.md`](REUSABLE-WORKFLOWS.md) +
   [`docs/COMPOSITE-ACTIONS.md`](COMPOSITE-ACTIONS.md) with any new
   inputs / outputs / secrets.
5. Open a GitHub release pointing to the tag with a changelog summary.

## When to bump to `1.0.0`

The threshold is **first sister-product GA on this repo**. Concretely,
when MarineDeck (or whichever Phase-1 sister-product lands first)
ships its first paying customer using these workflows in production,
cut `1.0.0` on the next release that would otherwise be a `0.x.y`
bump. From that release onwards, the contract stabilises.

## Cross-references

- [RFC 0019 — DevOps Strategy](https://github.com/chthonicsystems/architecture/blob/main/rfcs/0019-devops-strategy.md) § 8
- [RFC 0002 — Shared Library Strategy](https://github.com/chthonicsystems/architecture/blob/main/rfcs/0002-shared-library-strategy.md)
