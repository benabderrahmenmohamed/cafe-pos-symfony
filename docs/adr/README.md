# Architecture decision records

Why this codebase is shaped the way it is. Each record says what was decided, what it costs, and what was
rejected; the code is the authority, and a record that disagrees with it is a bug in the record.

Phases are those of the first plan unless marked v3, the café model in [docs/spec.md](../spec.md) that
replaced it.

| #                                                   | Decision                                                                                                                                                                              | Phase       |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| [0001](0001-feature-folders.md)                     | Feature folders with ports, adapters, lib and routes, instead of the export's pages and contexts; a layout per face.                                                                  | 2, v3 3     |
| [0002](0002-money-in-millimes.md)                   | Money is integer millimes: a branded type, rounding in one place, shares that add up, parsing that rejects.                                                                           | 2–3, v3 3   |
| [0003](0003-ports-and-adapters.md)                  | The UI reaches a backend only through ports; two adapters, one composition root, one contract suite, lint boundaries.                                                                 | 2–5, v3 3   |
| [0004](0004-per-terminal-receipt-sequence.md)       | The device allocates `seq` with the record, the server enforces `last_seq + 1`, the epoch fences a replaced device, and a hopeless record is voided rather than skipped.              | 3–4, v3 3   |
| [0005](0005-offline-outbox.md)                      | Records queue before any network call and drain in ordinal order under a Web Lock, retrying without limit and stopping at a conflict.                                                 | 4, v3 4     |
| [0006](0006-append-only-ledger.md)                  | Sales, lines and stock movements are never updated or deleted; refunds are new documents, and nothing at run time turns the triggers’ switch on.                                      | 3, 5, v3 3  |
| [0007](0007-open-orders-are-working-state.md)       | What is on the tables is working state beside the ledger: opened by the server, stamped and never deleted, queued on the device, and discardable where money is not.                  | v3 3–4      |
| [0008](0008-terminals-are-payment-devices.md)       | A terminal is a device the admin registered to take payment; roles say who may sell, the registration says which device numbers the receipt.                                          | 3, v3 3–4   |
| [0009](0009-the-server-is-symfony-over-postgres.md) | The service behind the REST contract is Symfony over the same Postgres schema: the rules stay in the database, the server carries records to them, and the app’s own suites prove it. | Symfony 0–6 |

## When to add one

Add a record when a decision constrains code that will be written later and the reason will not be obvious
from reading that code — a boundary somebody could cross by accident, an invariant several files depend on, or
a trade-off that was argued and settled. A decision that is visible in one file belongs in a comment in that
file, not here. Number the next record in sequence, do not renumber or delete the ones before it, and when a
decision changes, amend its record and say what was revised and why.
