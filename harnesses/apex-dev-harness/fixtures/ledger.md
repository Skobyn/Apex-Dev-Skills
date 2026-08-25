> 18 LEGACY · 4 OOS · 7 RETIRED** (+8 STUDIO / −10 DUAL / +2 RETIRED from operator CRM flip).

## Status vocabulary

| Status | Meaning | What it implies for new work |
|---|---|---|
| **STUDIO** | Studio surface is canonical; legacy equivalent retired, redirecting, or strictly slated to die | Build in Studio. Touching the legacy twin is a smell |
| **DUAL** | Both surfaces live. Studio has the editor/workspace; legacy page is still in daily use | New features → the Studio side (unless a named parity gap blocks). Fixes → wherever the bug lives. Behavior changes must keep both sides consistent (surface-parity rule applies) |
| **LEGACY** | Studio hasn't arrived. The old page IS the product — **extend it guilt-free**. Per the owner's end-state direction, every LEGACY row is Studio-bound *eventually*; the status describes today, not destiny | Build in the legacy surface. If the ask is big, raise "is this the moment to port the domain?" before sinking the work in |
| **OOS** | Different **audience**, not a deferred port: staff portal, guest-facing, app shell, platform back-office. The only rows with no Studio destiny | Never a Studio TODO. These products evolve on their own track |
| **RETIRED** | Route redirects or surface is dead | Don't touch; delete when convenient |

**The routing algorithm:** find the surface's row → follow its status column. No row = the
ledger has a bug; add the row (don't guess).

**Flipping a row** (LEGACY → DUAL, DUAL → STUDIO) is an **owner decision**, recorded here with
a date. A Studio build shipping does NOT auto-flip a row — parity is declared, not inferred.

---

## 00 Overview & home

| Surface | Routes | Status | Notes / routing |
|---|---|---|---|
| Home dashboard | Studio landing board (root `/` + `/apex-studio/:venueSlug`) | **DUAL** | Studio `views/Dashboard.jsx` (GridBoard cockpit; per-vertical faces — `PracticeDashboard` for medical). Legacy twin = the old app home `components/home/HomeDashboard.js`, still served to non-Studio entry points. Wave-1 recompose 2026-07-06 (spec: `studio-overview-dashboard-redesign.md`): Now postures + pace/bands, Needs-you + reviews/lead-aging, Next-7-nights (books · staffing · events · PredictHQ in-town); killed the my-shift / my-week / website-pages panels (staff-portal content lives in the portal; the nav is the page directory). Row added 2026-07-06 — the surface predates it (ledger gap, not a new build). |

## 01 Brand & Business

| Surface | Routes | Status | Notes / routing |
|---|---|---|---|
| Brand book (tokens) | `/brand`, `/cms/brand` | **STUDIO** (flipped 2026-07-18, owner ruling — drain-plan batch #1) | Studio `brand-book-workspace` (nav row carries `brand-tokens-editor` for chat-embed parity) is canonical. **Flip pass — the middle shape was chosen:** legacy `BrandPage` (editor toolbar + drawer host) DELETED and the AppRail Brand row removed for everyone; `/brand` is retained **solely as the PDF print engine** (`BrandBookPrintPage`, mounted only for `?export=pdf` — Studio's "Export PDF" deep-link contract `/brand?export=pdf&venue=<slug>`; the `venue` param is the print target) until a Studio-native export exists — not an editing surface; every other `/brand` visit soft-redirects into the workspace (`LegacyToStudioRedirect`). A full port of the print flow INTO Studio was rejected for now: the print isolation relies on a whole-page `window.print()` + `@media print` visibility carve-out that would fight the Studio shell. KEPT: `useBrandTokens`, `VenueBrandShowcase` + `BrandEditDrawer` panes (public `/brands/:venue` showcase + the Studio workspace consume them — OOS/shared), `design_tokens` API, `/api/brand-showcase/{slug}/skill` (verified untouched) |
| Business profile (contact · hours · social identity) | Studio `business-profile-editor` — no legacy twin | **STUDIO** | **Re-scoped 2026-07-18 (owner ruling, drain-plan batch #1):** `/brand-settings` was never this surface's twin — it's a brand-research/voice/SEO page (own row, next). Contact/hours/social had no legacy page editor (assistant tool + MCP only, pre-Studio), so the native editor is effectively Studio-born. **Hours writes mirror to GBP from every surface (2026-06-11, dd9a7452c)** — the `business_profile` handler pushes hours/specialHours via `gbp_sync_service`; 2026-07-18 audit verified no unmirrored hours-write path exists anywhere |
| Brand research / voice / SEO defaults | `/brand-settings`, `/cms/brand-settings` | **LEGACY** | **Row added 2026-07-18 (re-file, owner ruling):** what `/brand-settings` actually is — brand-research collect/analyze, voice profile + personality build, competitor analysis, content guidelines, SEO defaults (default OG image + meta description). No Studio home yet; `brand-research/*` + `venue-personality/*` APIs + the SEO-defaults route live only here. Studio-bound long-horizon (voice authoring folds into the Brand book per this section's retired brand-voice note) |
| Brand assets / media | `/brand/assets`, `/cms/brand-assets` | **STUDIO** (flipped 2026-07-18, owner ruling — drain-plan batch #1) | Studio Media library covers the surface. Ledger-only flip — both routes were already redirect-only (`/brand/assets` and `/cms/brand-assets` → `/brand`, which now lands in the Studio brand-book-workspace), so there was nothing to delete |
| Brand voice | `/cms/brand-voice` | **RETIRED** | `App.js` redirects `/cms/brand-voice` → `/brand` (the standalone page is gone); voice authoring folds into the Studio Brand book over time |
| Public brand showcase | `/brands/:venue` | **OOS** (public) | Published artifact, not an operator surface |

## 02 Menus

| Surface | Routes | Status | Notes / routing |
|---|---|---|---|
| Menu Manager core (items / recipes / ingredients / online menu / event packages) | `/menu-manager`, `/menu-manager/{online-menu,event-packages,ingredients,recipes}` | **DUAL** | Studio Catalog (items·recipes·ingredients segments) + Menus manager (documents + Web face) + event-package editor are live. 2026-07-18 parity wave closed the named gaps: menu-membership editing (item-hub Placements → `online_menu` add_item/remove_item), add-item/recipe/ingredient from blank (Catalog create popovers), tag groups (Catalog rail hierarchy), specials (Menus-rail door → `weekly-specials-editor`), plus item-editor field parity (internal name · folder filing · tags/allergens/dietary). 2026-07-18 (later pass) closed the two remaining named gaps: **item IMAGES** — the item hub's Photos strip (`MenuItemPhotos` on the Item face: drag-drop + picker upload, two-step remove) writes the legacy `menu_unified` upload-image/remove-image endpoints behind the registered `menu-item-images` REST-write exception (**status `pending-decision`** — the owner still owes the ruling; the plausible split is house-guide-style: byte intake stays REST, the `images[]` remove migrates onto the `menu_item` spine); and the **Print/POS face build** — the menus passport grew a real face segment (Web · Print · POS): the Print face is the per-document projection (pieces referencing this menu, fact-bound + "New print sheet from this menu" seeding a `print_piece` create on the spine from the menu's sections, landing in `menu-print` compose), the POS face scores register-link coverage (explicit + folder-fed membership) with doors into each item's Placements face. `menu-print` itself stays rail-pulled (owner 7/11) — its entrances are the passport faces. Status flip to STUDIO is the owner's call |
| Menu item detail/edit | `/menu-items/:id`, `/menu-items/new`, `…/edit`, `…/recipe/create` | **STUDIO** (flipped 2026-07-18, Chris, ruling batch #2 at defaults) | Studio item workspace (Catalog row → `menu-item-editor` resolver → MenuItemWorkspace hub) is canonical; 07-18 field-parity wave in (internal name · folder filing · tags/allergens/dietary). DELETED: `MenuItemDetail.js` + `MenuItemEdit.js` + `RecipeCreate.js` + `components/menu/RecipeBuilder.js` (its only importer was RecipeCreate). All four routes soft-redirect via `LegacyToStudioRedirect` — a bookmarked item carries its id into the item workspace (recipe/create lands on the Recipe face; `/new` lands on the Catalog create popover). KEPT (shared organs): `/api/menu/*` (`menu_unified.py`), `menu_item_write.py` + the `menu_item` mutation spine, `menu_manager_data.py` recipes/ingredients. Named residual (item IMAGES blob machine) stays on the Menu Manager core row — does not block this row |
| QuickMenu (POSitouch) | `/menu/qmenu`, `/menu-manager-new` | **STUDIO** | Studio POSitouch → QuickMenu + POS Screens is the build (Saltwater-gated, bridge deploy contract). Legacy QMenu dashboard retires |
| POS / R365 mapping | `/menu/pos-mapping` (redirects → `/menu-manager`) | **DUAL** | 2026-07-23: the Studio `menu_mapping` queue grew into the R365 mapping COCKPIT — segments Map (unmapped + candidates) · Review (approve/reject pendings incl. pool-growth proposals) · Conversions (inline teach-in via payload-declared numeric input); handler ops `approve`/`demote`/`reject`/`set_conversion`/`designate_well_pour` on the spine; ingredient card shows the full substitution pool (costing marker, well-pour designation, live vendor-price annotation + basis alarm); `menu-item-cost` lines annotate moved vendor quotes. Remaining legacy-side: the Menu Manager ingredients-zone bulk tooling (`ui/src/components/menu/zones/`). Status flip is the owner's call |
| Menu analytics | `/menu/analytics` | **DUAL** | Studio item-sales + menu-item-performance cards cover the glance; deeper cuts legacy |
| Menu designer (Konva) | `/menu-designer` | **RETIRED** | 2026-07-18 owner ruling — Studio MenuPrintWorkspace is the print path; route redirects; Konva module retained in history |
| Menu builder / sales kit / weekly specials | `/menu-management/{main,menu-builder,sales-kit,weekly-specials}` | **LEGACY** | No Studio equivalent. Extend in place; print-face unification may absorb menu-builder later |
| Org-level menu rollup | `/org/menu-manager` | **LEGACY** | |

## 03 Guests & CRM

> **2026-06-12: Studio-side, the EVENT SPINE is one door** — the `events-desk` workspace
> (Overview · Pipeline · Calendar · All-events lenses) replaced the five rail rows that were all the
> same crm_event records (Leads, Lead inbox, Calendar, Events, Pipeline). Leads surface inside the
> Overview lens's "Needs you" attention surface — there is no separate Inbox lens (the form-janitor
> Inbox tab was retired in the "Overview landing" recompose). Contacts and Reviews keep their
> OWN rows — a first cut that lumped them behind the same tab strip ("guests-cockpit") was
> owner-rejected and decomposed the same day: consolidation is for surfaces sharing one JOB, not one
> drawer. Retired event-spine chat keys (`crm-pipeline`/`crm-calendar`/`crm_event`/`crm_lead`)
> reroute to the desk at their lens.
>
> **2026-07-09 CUTOVER BOUNDARY (owner "LFG"): Event CRM → Pure Studio.** New CRM *operator*
> UI work is **Studio-only** — do not extend `/crm/*` pages.
> **Phase 2–4 landed 2026-07-09 (soak skipped — owner: "Nobody uses the old CRM").**
> `/crm/*` is **redirect-only** (`CrmToStudioRedirect`, no legacy page mounts). AppRail
> **hides** the Events & CRM section for Studio-entitled users (CRM lives in Studio
> Guests & CRM). Deleted: `CrmHomePage`, `CrmEventDetailPage`, `CrmContactDetailPage`,
> `CrmContactsPage`, `CrmEventsListPage`, `CrmReportingPage`, `CrmSettingsPage`,
> `CrmDetailLayout`, plus `CrmHomeV2` / `CrmSettings` / `EventDetail` / `EventDetailV2`
> trees. Kept: `/event/:token`, `/sign/:token`, `/api/crm/*`, portal, `components/crm/*`
> shared by portal/signing/LivePos. Tripleseat feed stays **parallel**. Guestbook OOS
> of this cutover. Settings home = Studio `crm-settings`. Attention Brief on Events
> Overview (`useDashboardBrief` under `apexStudio/runtime/`).

| Surface | Routes | Status | Notes / routing |
