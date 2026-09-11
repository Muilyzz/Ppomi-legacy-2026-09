# playbook-kr-cert

Content package for a **사업자 공동인증서 발급 준비** fixture. Scenario and screen data only.

This is not `playbook-content`, `playbook-core`, or a second `playbook-runtime`.

## Layers

| Package | Role here |
| --- | --- |
| `playbook-kr-cert` | Steps + Windows fixture window |
| `playbook-runtime` | Runs mapped steps; fail-closes submit/payment-like clicks |
| `adapter-windows` | `OsAdapter` over `app_open` / `screen_read` / `ui_tap` / `ui_type` (tests use the fixture tools) |

`payment` and `submit` steps stay in the content (`결제하기`, `제출`) so a run that reaches them must stop without `ui_tap`. Preparation steps (focus, read purpose, 다음, 사업자 구분, read fee) may complete on the fixture.

No device-approval / Mac-approver gate. No secrets, resident-registration numbers, OTP, or certificate passwords. This package does not choose an issuer or complete issuance.

## Tests

```sh
npm --prefix packages/playbook-kr-cert test
```
