# FX gateway

Thin currency-conversion service with a stable contract for the Camunda REST connector
(Go stdlib, scratch image). The rate source sits behind a `RateProvider` interface; the
current implementation calls the public frankfurter.app API. Replacing it with the shared
currency-rate-service (see `docs/backlog.md`) must not change the contract below.

## Contract

```
GET /convert?from=USD&to=EUR&amount=1200
→ 200 {"from":"USD","to":"EUR","amount":1200,"rate":0.86,"converted":1032,"asOf":"2026-09-24"}
```

- `converted` — rounded to 2 decimal places; `rate` is returned as provided by the source;
- `from == to` — short-circuit: `rate: 1`, `converted = amount` (rounded), `asOf` = today
  (UTC), no provider call — so same-currency conversions work offline and for any code;
- `400` — malformed parameters (currencies must be 3-letter uppercase codes, amount > 0);
- `502` — provider unreachable, provider error, or unsupported currency pair;
- `GET /healthz` — liveness; the container healthcheck runs `/app -check` (scratch has no shell).

## Limitations

- Rates are ECB reference rates via the public frankfurter.app API: **outbound internet
  access is required**, and **RSD is not supported** (ECB does not publish it).
- One rate per day (`asOf` is the ECB publication date), no intraday updates.

## Run

Part of the `integrations` compose profile (`infra/docker-compose.yml`), built on the VM by
`make deploy`. Not published on the host — reachable as `http://fx:8080` inside the compose
network (`FX_BASE_URL` in `infra/.env.example`). `FRANKFURTER_BASE_URL` overrides the
provider URL (tests).
