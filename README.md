# Reality Merge — v1

Location-unlocked social Drops. See `reality-merge-v1.md` (the blueprint doc)
for the product scope. This repo is the v1 implementation of that scope only
— no AR, no dating, no marketplace.

## Setup

1. **Create a Supabase project** at https://supabase.com/dashboard.
2. Run `supabase/schema.sql` in the Supabase SQL editor, then run
   `supabase/v2-migration.sql`, `supabase/v2.1-migration.sql`,
   `supabase/v3-migration.sql`, `supabase/v4-migration.sql`, and
   `supabase/v5-migration.sql` in that order. Together these create all
   tables, RLS policies, and RPC functions (`nearby_drops`,
   `attempt_unlock`, `grant_drop_access`, `list_conversations`,
   `mark_conversation_read`) that the app depends on. `v5-migration.sql`
   also creates the `avatars` storage bucket itself, so you don't need to
   create that one by hand (unlike `drop-media` below).
3. In Supabase Storage, create a public bucket named `drop-media` (used for
   Drop photos/videos/documents).
4. **Disable email confirmation for now** (dev convenience, not a code
   change): Authentication -> Providers -> Email -> turn off "Confirm
   email". With it off, `signUp` logs the user in immediately. With it on,
   Supabase won't create a session until the user clicks a confirmation
   link — the current sign-up screen doesn't yet handle that "check your
   email" state, so leave it off until that's added, and turn it back on
   before any real launch.
5. Copy `.env.example` to `.env` and fill in `SUPABASE_URL` /
   `SUPABASE_ANON_KEY` from Project Settings -> API.
6. Install Flutter dependencies:
   ```
   flutter pub get
   ```
7. Run on a device or simulator (location permissions require a real device
   or a simulator with a mocked location — the iOS Simulator and most
   Android emulators support this):
   ```
   flutter run
   ```

## What's actually implemented here

- Email/password auth (username login is stubbed — see the note in
  `supabase_service.dart`; needs a `resolve_login_email` RPC before it's
  usable, left as a TODO so nothing about auth security is faked)
- Feed of nearby Drops with location + media thumbnail on top of each post,
  locked (distance only) vs. unlocked (full content)
- Server-verified unlock: the `attempt_unlock` RPC recalculates distance
  server-side — the client's claimed GPS position is never trusted alone
- Creating a Drop at your current location, with photo/video/document +
  caption + a configurable unlock radius. Photos are resized/re-encoded and
  videos are compressed client-side before upload (via the `image` and
  `video_compress` packages) to keep uploads small; a "Data saver" toggle
  in Profile settings makes both more aggressive
- Compass tab: device-heading compass that also points toward the nearest
  locked Drop
- Chats tab: 1:1 direct messages between users, with realtime updates
- Reactions & comments on Drops (unlimited comments per user per Drop)
- Profile stats: Drops created, places visited
- Profile picture upload (Storage bucket + RLS in `v5-migration.sql`)

## What's intentionally not here

Per the v1 blueprint: AR camera mode, dating, marketplace, world room,
sponsored locations, multiple content layers, AI features. Don't add these
until the core loop above is retaining users in a real launch geography —
see the blueprint's "Success metrics" section for what to check first.

## A note on `video_compress`

The `video_compress` package (used for client-side video compression before
upload) hasn't seen frequent updates upstream. It's built against fairly
old native Android APIs and *should* still work fine against this project's
`compileSdk`/`minSdk`, but if a CI build ever fails specifically on that
plugin's Android module (as opposed to a Dart/Gradle error elsewhere), that
package is the first thing to suspect — check its GitHub issues for a
known fix, or fall back to skipping video compression (upload the original
file — see `_compressVideo` in `create_drop_screen.dart`, it already
falls back gracefully if compression throws) while keeping photo
compression, which uses the pure-Dart `image` package and carries no such
risk.

## Seeding a launch area

Before opening this to real users, seed 30-50 Drops manually at high-traffic
points in your launch geography (campus entrances, plazas, popular spots).
There's no seed script in this repo yet — for v1, writing these by hand as
a real user (or a small ambassador group) is more valuable than automating
it, since the content itself needs to be genuinely worth walking to.
