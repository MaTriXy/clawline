# Web Bubble Sizing Regression

## Status
Ready for Flynn verification on branch `clawline-web-parity-layout-batch`.

## Source Truth
Checked source docs on 2026-05-09:

- `/Users/mike/shared-workspace/clawline/ios-flow-layout-rules.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/bubble-sizing-v2.md`
- `/Users/mike/shared-workspace/clawline/implementation_details/efficient-flow-layout.md`

The relevant product rule is that even content-fit / wide markdown bubbles should preserve a comfortable max width instead of stretching to the full transcript viewport.

## Implementation Notes
`useVirtualMessageWindow` now caps wide and truncated estimated bubble width at the comfortable line cap instead of using the full container width. The change keeps row placement owned by the virtual layout while preventing wide bubbles from becoming fullscreen-width on desktop/tablet viewports.

## Evidence
Recorded 2026-05-09 10:05 PDT from `/Users/mike/src/worktrees/clawline-web-parity-layout-batch`:

- `npm run build`: PASS.
- `npm run test`: PASS, 23 files / 182 tests.
- `npm run test:e2e -- playwright/tests/phase5-flow-layout.spec.ts`: PASS, 5 tests, all using local `clawline_web_test` harness identity. Browser assertion verified a wide markdown bubble stayed `<= 620px` and substantially narrower than the transcript viewport.
