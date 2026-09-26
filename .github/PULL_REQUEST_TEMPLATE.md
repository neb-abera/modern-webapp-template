<!--- A general summary of the change goes in the title above -->

## Description
<!--- What changed -->

## Motivation and Context
<!--- Why it is needed and what problem it solves. Link the issue it fixes. -->

## How Has This Been Tested?
<!--- A test that fails without the change comes first (TDD). List the -->
<!--- commands you ran and what each showed, and the environment you ran -->
<!--- them in. The local merge gate is `./scripts/verify.sh`, or -->
<!--- `make check` in a repository without one. -->

## Screenshots (if appropriate):

## Types of changes
<!--- Put an `x` in every box that applies: -->
- [ ] Bug fix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to change)

## Migration review (delete if this change has no database migration)
<!--- Indexes are the part of a migration nobody tests and everybody pays for. -->
- [ ] Every new query's `WHERE` + `ORDER BY` pair has an index that serves both (equality columns first, then the sort column).
- [ ] Composite keys: if the second column is ever filtered on its own, it has its own index. A composite index only serves its leading column(s).
- [ ] Every foreign key column is indexed.
- [ ] The previous release still runs against the new schema (migrations apply before the new revision serves, and destructive changes wait a release).
- [ ] No `GRANT` was needed: the runtime role's default privileges cover new tables.

## Checklist:
<!--- Put an `x` in every box that applies. Ask if one is unclear. -->
- [ ] My code follows the code style of this project.
- [ ] My change requires a change to the documentation.
- [ ] I have updated the documentation accordingly.
- [ ] I have read the **CONTRIBUTING** document.
- [ ] I have added tests to cover my changes.
- [ ] All new and existing tests passed, and the local merge gate is green.
