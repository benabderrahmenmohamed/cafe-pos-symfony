# Error contract

Every failure that crosses a port is an error with one of the codes below. Clients decide what to do from the **code alone**, never from message text. The database functions in `api/migrations`, the Symfony server that carries them (`contracts/openapi.yaml`) and every adapter implement this table.

## Codes

| Code                   | HTTP | Class     | Raised when                                                                                                                                                                                                                        | `details`                                                        |
| ---------------------- | ---- | --------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `NETWORK_ERROR`        | —    | retriable | The request never got a response (client only).                                                                                                                                                                                    | —                                                                |
| `SERVER_ERROR`         | 5xx  | retriable | Any 5xx, including database serialization failures and deadlocks.                                                                                                                                                                  | —                                                                |
| `RATE_LIMITED`         | 429  | retriable | The server asks the client to slow down.                                                                                                                                                                                           | —                                                                |
| `UNAUTHENTICATED`      | 401  | auth      | No session, or it expired. Checked before anything else.                                                                                                                                                                           | —                                                                |
| `FORBIDDEN`            | 403  | conflict  | No shop membership, wrong role, a record of another shop, a terminal not registered in the caller's shop, a session of another terminal, or a record's actor outside the shop.                                                     | `{ terminal_code }`, `{ session_id }`, `{ actor_user_id }`       |
| `NOT_FOUND`            | 404  | conflict  | A product, session or sale named by a request that does not exist in the caller's shop.                                                                                                                                            | `{ product_id }`, `{ session_id }`, `{ sale_id }`                |
| `VALIDATION_ERROR`     | 422  | conflict  | A malformed payload, or a business rule: totals that do not match the lines, a payment that breaks the tender rules, a refund above what is left, or a refund of a line's last units that does not pay exactly what is left of it. | `{ field }`, or `{ line_no, remaining_qty, remaining_millimes }` |
| `IDEMPOTENCY_CONFLICT` | 409  | conflict  | A record id already stored with a different `payload_hash`.                                                                                                                                                                        | `{ id }`                                                         |
| `SEQUENCE_GAP`         | 409  | conflict  | `seq` is not the terminal's `last_seq + 1`.                                                                                                                                                                                        | `{ expected_seq, received_seq }`                                 |
| `SESSION_CLOSED`       | 409  | conflict  | The record's session was closed before the record arrived.                                                                                                                                                                         | `{ session_id }`                                                 |
| `SESSION_ALREADY_OPEN` | 409  | conflict  | Opening a session on a terminal that already has one.                                                                                                                                                                              | `{ open_session_id }`                                            |
| `TERMINAL_SUPERSEDED`  | 409  | conflict  | The device's terminal registration was replaced by a newer one.                                                                                                                                                                    | `{ terminal_code, current_epoch }`                               |
| `ORDER_CHANGED`        | 409  | conflict  | The open order moved under the request: a line names an item that is already paid, removed, or no longer matches its product, quantity or unit price; or a cancel names an order with a paid item.                                 | `{ table_id }`, `{ item_id }`, `{ line_no }`                     |
| `ORDER_CLOSED`         | 409  | conflict  | The table has no open order any more: it was paid or cancelled before the record arrived.                                                                                                                                          | `{ table_id }`, `{ order_id }`                                   |
| `ITEM_NOT_FOUND`       | 404  | conflict  | The order item a remove or a prepare names does not exist in the caller's shop.                                                                                                                                                    | `{ item_id }`                                                    |
| `TABLE_INACTIVE`       | 409  | conflict  | The table is not active, so nothing may be added to it.                                                                                                                                                                            | `{ table_id }`                                                   |
| `CONFIG_ERROR`         | —    | conflict  | The client is misconfigured, e.g. a missing environment variable (client only).                                                                                                                                                    | —                                                                |
| `UNKNOWN`              | —    | conflict  | Anything else the client cannot classify.                                                                                                                                                                                          | —                                                                |

**Classes** decide what the offline outbox does with a record:

- **retriable**: keep the record pending and retry with backoff, without limit. A register must not give up on a real sale.
- **auth**: pause the queue without touching the record or its attempt count; resume when a session exists again.
- **conflict**: stop the queue at this record and show it to a person. Later records stay pending.

**Discarding.** A record stopped in conflict returns to `pending` only after a person reviews it. Order kinds (`order_item_add`, `order_item_remove`, `order_send`, `order_item_prepare`, `order_cancel`) may also be discarded with a reason into the device's dead-letter list, which the admin sees: a stale item on a table the caisse already closed must not block a waiter's phone for ever. Ledger kinds (`sale`, `refund`, `session_open`, `session_close`) can never be discarded — one that reached the server must not be dropped, and one that did not has to be looked at.

**A late add is not an error.** `order_item_add` for a table whose order was closed opens a new order with that item, so a waiter's offline event arriving after the caisse paid shows up as an unpaid item rather than being lost. Because of its table, only `TABLE_INACTIVE` and `FORBIDDEN` refuse an add; `ORDER_CLOSED` never does.

## Wire formats

**Keys.** RPC parameters and results, REST bodies and error `details` use snake_case keys (`payload_hash`, `terminal_code`, `lines[].unit_price_millimes`). The ports use camelCase; adapters rename keys at any depth with `src/lib/caseConversion.ts` and change nothing else. `payload_hash` is computed over the port record (see `src/lib/payloadHash.ts`) and sent unchanged, so the renaming never affects replays.

**Database.** The functions in `api/migrations` raise with SQLSTATE `PTxyz`, where `xyz` is the HTTP status, through `private.raise_error` (the ledger's triggers raise the same shape themselves): the message is the code, the detail is the JSON object as text, and the hint is a sentence for people — SQLSTATE `PT409`, message `SEQUENCE_GAP`, detail `{"expected_seq": 42, "received_seq": 43}`, hint `Expected receipt T1-42.` The Symfony server reads those back (`api/src/Api/DatabaseErrors.php`) and answers HTTP `xyz` with the REST body below: the code, the hint as its `message`, the detail as its `details`. A row a policy refuses, or a missing grant (SQLSTATE `42501`), answers `FORBIDDEN`; anything else the database raises is `SERVER_ERROR`.

**REST (`/api/v1`).** `{ "error": { "code": "SEQUENCE_GAP", "message": "Expected receipt T1-42.", "details": { "expected_seq": 42, "received_seq": 43 } } }`.

**Responses without a contract code** (a proxy error page, say) are classified by HTTP status: 401 `UNAUTHENTICATED`, 403 `FORBIDDEN`, 404 `NOT_FOUND`, 400/409/422 `VALIDATION_ERROR`, 429 `RATE_LIMITED`, 5xx `SERVER_ERROR`. A failed connection is `NETWORK_ERROR`.

**Signing in** follows that classification: `POST /api/v1/auth/token` answers a wrong password and an unknown e-mail alike, with 401 `UNAUTHENTICATED`, so a bad password pauses a queue instead of stopping it at the record, and a request without an e-mail or a password with 422 `VALIDATION_ERROR`. There is no token refresh: an expired token is answered 401 `UNAUTHENTICATED`, like a missing one.

## Record outcomes

A successful write returns a status instead of an error:

| Operation                       | Statuses                                                                                                               |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `record_sale` / `POST /sales`   | `created` (HTTP 201), `replayed` (200: already stored with the same hash), `voided` (200: an admin voided this record) |
| `open_session`, `close_session` | `created` (201), `replayed` (200). A replayed close returns the Z-report stored at close time.                         |
| `void_receipt`                  | `voided` (201), `replayed` (200), `recorded` (200: the record reached the ledger after all; treat it as acknowledged)  |

## Order of checks

`record_sale`, `open_session` and `close_session` run in one READ COMMITTED transaction, in this order. The order is part of the contract: a replay must return its stored outcome even when a later check would now fail.

1. Caller: `UNAUTHENTICATED`, then `FORBIDDEN` for no membership.
2. Lock the caller's terminal row by `(shop_id, terminal_code)`: `FORBIDDEN` if it does not exist. Every later read sees the committed result of earlier requests for this terminal.
3. Idempotency by record id: another shop's record is `FORBIDDEN`; the same hash returns the stored outcome (`replayed`, or `voided`); a different hash is `IDEMPOTENCY_CONFLICT`. A unique-key clash on a record id also maps to `IDEMPOTENCY_CONFLICT`.
4. Registration: `TERMINAL_SUPERSEDED` if the payload's `epoch` is not the terminal's.
5. Session: `NOT_FOUND` if no session has that id, `FORBIDDEN` if it belongs to another shop or another terminal, then `SESSION_CLOSED` or `SESSION_ALREADY_OPEN`.
6. Numbering: `SEQUENCE_GAP` unless `seq = last_seq + 1`.
7. Document rules, recomputed from the lines, in this order: `FORBIDDEN` when the record's actor is not a member of the shop, `NOT_FOUND` for a product or a refunded sale that is not in the caller's shop, then `VALIDATION_ERROR` for the amounts, the payment and the refund limits. A refund first takes a lock on the sale it refunds, then sums earlier refunds.
8. Write the document, its lines and stock movements (products locked in id order), then set `last_seq = seq`.
