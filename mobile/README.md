# Agent Monitor (mobile)

Read-only Android companion to the [menu bar app](../menubar) - see what your
agents are doing from your phone. Expo SDK 57, TypeScript, React Native Paper
(Material 3 / Material You).

## Run it

```bash
cd mobile
npm install
npx expo run:android    # builds and installs on a connected device/emulator
```

Or, without a native build, using Expo Go on your phone:

```bash
npx expo start
```

(Expo Go works for this app since it uses no custom native modules beyond what
Expo already bundles.)

## Setup

On first launch the app takes you straight to Settings. Paste the same
Supabase project URL and **anon** key the menu bar app uses (Project Settings
→ API in your Supabase dashboard) - never the `service_role` key.

There is no `local` or `cosmos` backend option here: `local` is a file on one
Mac, unreachable from a phone, and shipping a Cosmos master key to a mobile
app is a materially worse trade than the already-scoped-down Supabase anon
key. If you need Cosmos from mobile, put a thin proxy in front of it rather
than embedding the master key in the app.

## What it does

- Polls the same `agent_tasks` table as the menu bar app (default every 5s)
- Groups tasks by status: needs you / working / failed / done
- Flags a `working` task stale after 30 minutes of no update, matching the
  desktop app's threshold
- Material You: on Android 12+, the theme is derived from your device's
  wallpaper color; elsewhere it falls back to a fixed seed color

## What it deliberately does not do (yet)

- **No push notifications.** This is a foreground viewer - open the app to
  see current status. The desktop app already covers "notify me when
  something needs me"; adding that here means standing up Firebase Cloud
  Messaging plus a Supabase trigger to call it, real infrastructure most
  people wouldn't need to check a status list. Worth doing if you actually
  want push, not worth building by default.
- **No realtime subscription.** `backends/supabase/schema.sql` already
  enables Realtime on the table, so a websocket-based instant-update version
  is a natural upgrade over polling - just not implemented here.

## Verification

Verified on this machine: strict-mode TypeScript compiles clean
(`npx tsc --noEmit`), and `npx expo export --platform android` bundles all
823 modules with no resolution errors. Not verified: an actual on-device or
emulator screenshot - the only Android system image already present here is
a legacy `x86` build, not viable on Apple Silicon without a fresh arm64
image download. Run `npx expo run:android` on your own machine to see it for
real; if something doesn't render as expected, that's the gap to report.
