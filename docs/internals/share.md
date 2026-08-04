# Share

Consumer contract: [services.md](../services.md#share-the-sheet-is-the-users).
This file is the wiring: five native sheets and the Web Share API behind
one verb, and how `available`'s answer is produced per platform.

## One hook, and who exports it

The whole native surface is one outbound call, `nokre_share_show(text,
len)` ([share.h](../../src/services/share/share.h)), fired only after
the Zig-side checks passed — so every leg below receives text already
known to be non-empty and under the cap, and none of them reports back.
Which shells export it is a comptime fact
([share.zig](../../src/services/share/share.zig)'s `has_shell_hook`):
macOS, iOS, Windows, Android, and the web. Unlike clipboard's
blanket-`.linux` switch, share's omits the Linux desktop deliberately —
the Wayland shell has no sheet to host — and since Android's OS tag *is*
`.linux`, the abi is what tells the two apart.

## The five sheets

**macOS** — `NSSharingServicePicker`, shown relative to the center of
the app's one view, arrowless: the service API carries no geometry, so
the menu anchors app-level rather than to whichever control the app
happened to wire the action to. The picker is held in a static and
replaced at the next share, because the menu does not retain the picker
itself — a local released at the end of the hook tears the menu down
mid-gesture. UI lifetime, not app state.

**iOS** — `UIActivityViewController`, presented from the *topmost*
presented controller rather than the root: a share can be asked for
while a system sheet the shell cannot see is already up, and presenting
from a covered controller is a silent no-op. iPad draws this as a
popover and requires an anchor, so the same center-of-view, arrowless
answer applies; iPhone ignores the popover controller and presents the
sheet.

**Android** — `ACTION_SEND` wrapped in `Intent.createChooser`, always:
the chooser is what makes the user pick from everything installed
rather than whatever won the last "always". The text crosses JNI as a
byte array (`NokreView.showShare`), and `ActivityNotFoundException` is
swallowed — fire-and-forget has no error lane. The binder transaction
buffer this intent crosses is what set the 64 KiB cap on the Zig side.

**Windows** — the share pane is WinRT UI, reached from Win32 through
`IDataTransferManagerInterop`, the OS's own bridge for exactly this
HWND-hosted case, with no packaging identity required — which is why
iap answers false on Windows and share does not. Two costs are taken in
the open ([shell.c](../../src/platform/windows/shell.c)):

- mingw ships no `Windows.ApplicationModel.DataTransfer` header and no
  combase import library, so the combase entry points bind at first use
  and the interfaces are declared in the shell, answering to the SDK
  IDL with uuids copied digit-for-digit. The one GUID the IDL cannot
  state — the parameterized
  `TypedEventHandler<DataTransferManager, DataRequestedEventArgs>` — is
  the RFC 4122 v5 hash the WinRT pinterface rules define. A machine
  without `combase.dll` simply never shows the pane.
- the pane *pulls*: `ShowShareUI` raises `DataRequested` and the
  handler fills the data package after the hook has returned, so the
  text is copied into one pending slot the static handler serves —
  in-flight call data at file scope, the deep_link-pending shape,
  replaced at the next share and never read by anything else.

**The web** — `navigator.share({ text })`, with both of its refusals
folded into the contract's silence
([services.js](../../src/render/dom/services.js)): `AbortError` is the
user closing the sheet, which is their business, and `NotAllowedError`
is a call that outlived its transient activation — the browser refuses
a sheet nobody asked for, and so does the contract. The activation
window is why the consumer doc says to share from the action itself,
never from an async callback.

## `available`'s wiring

Native targets answer at comptime — `has_shell_hook` *is* the answer,
cached into the service's one release-half bool at `App.init`. The web
asks the page once at the same moment: `nokre_share_available` reads
`navigator.share`'s presence synchronously, so the cached answer is
warm before the first `build` and no init-order concern arises (a value
query that fires into nothing — locale's fire-into-services problem is
not this). The Linux desktop never reaches either path: no hook, so
`available` is false by construction.
