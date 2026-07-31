// Android view half of the nokre shell (see android.zig for the map).
// Thin by charter: surface + blit geometry, input forwarding, an
// InputConnection for the software keyboard + IME, TalkBack via an
// AccessibilityNodeProvider built from the flattened a11y snapshot. No
// timers — nokre repaints only when state changes; the one animation
// callback runs only while a fling is decelerating, the same bargain as
// the hidden UIScrollView on iOS (here the physics engine is
// OverScroller, the platform's own).
package dev.nokre.shell;

import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.net.Uri;
import android.graphics.Rect;
import android.os.Build;
import android.os.Bundle;
import android.os.LocaleList;
import android.view.Choreographer;
import android.view.GestureDetector;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityManager;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityNodeProvider;
import android.view.inputmethod.BaseInputConnection;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputMethodManager;
import android.widget.OverScroller;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;

public final class NokreView extends SurfaceView implements SurfaceHolder.Callback {
    // ---- shell.h mirrors (the Java side of the C contract) ----
    private static final int KEY_TAB = 1, KEY_ENTER = 2, KEY_SPACE = 3, KEY_ESCAPE = 4,
            KEY_BACKSPACE = 5, KEY_DELETE = 6, KEY_LEFT = 7, KEY_RIGHT = 8, KEY_UP = 9,
            KEY_DOWN = 10, KEY_HOME = 11, KEY_END = 12, KEY_PAGE_UP = 13, KEY_PAGE_DOWN = 14;
    private static final int MOD_SHIFT = 1, MOD_CTRL = 2, MOD_ALT = 4, MOD_META = 8;
    private static final int SCROLL_BEGIN = 1, SCROLL_MOVE = 2, SCROLL_END = 3;
    // Mirrors NOKRE_POINTER_* in src/platform/shell.h.
    private static final int P_DOWN = 0, P_MOVE = 1, P_UP = 2, P_CANCEL = 3;
    // nokre_accesskit.h mirrors.
    private static final int ROLE_DOCUMENT = 0, ROLE_STATIC_TEXT = 1, ROLE_HEADING = 2,
            ROLE_BUTTON = 5, ROLE_LINK = 6, ROLE_TOGGLE = 7, ROLE_TEXT_FIELD = 8,
            ROLE_CELL = 11, ROLE_STATUS = 16, ROLE_OPTION = 18,
            ROLE_MULTILINE_TEXT_FIELD = 19, ROLE_IMAGE = 20, ROLE_PASSWORD_FIELD = 21,
            ROLE_CHECKBOX = 22;
    private static final int A11Y_ACTION_CLICK = 1, A11Y_ACTION_FOCUS = 2;

    // ---- natives (registered by shell.c's JNI_OnLoad) ----
    private native boolean nativeBoot();
    private native void nativeSetSurface(android.view.Surface surface);
    private native void nativeRender(int logicalW, int logicalH, int safeBottom, int scale);
    private native void nativeTap(int x, int y);
    private native void nativePointer(int x, int y, int phase);
    private native boolean nativeWantsPointerStream(int x, int y);
    private native void nativeKey(int key, int mods);
    private native void nativeText(byte[] utf8);
    private native void nativeDeepLink(byte[] utf8);
    private native void nativeAuthResult(int status, byte[] utf8);
    private native void nativeScroll(int x, int y, int dx, int dy, int phase);
    private native boolean nativeBack();
    private native void nativeImeUpdate(byte[] utf8, int cursor);
    private native void nativeImeCommit(byte[] utf8);
    private native void nativeImeCancel();
    private native boolean nativeWantsFrame();
    private native boolean nativeWantsTextInput();
    private native void nativeAppearance(boolean dark);
    private native void nativeLocale();
    private native void nativeWindowFocus(boolean focused);
    private native int nativeA11yFill();
    private native void nativeA11yAction(long id, int action);

    private final InputMethodManager imm;
    private final AccessibilityManager a11yManager;
    private final GestureDetector gestures;
    private final OverScroller scroller;
    private final StringBuilder composing = new StringBuilder();

    private boolean surfaceReady;
    private int scale = 1;
    private int logicalW = 1;
    private int logicalH = 1;
    // Bottom band the OS draws over (gesture-nav bar), logical px;
    // NokreActivity feeds it from the window insets.
    private int safeBottom;
    private boolean keyboardShown;

    // One drag's bookkeeping (the iOS feeder's role): the anchor locks
    // core's routing for the gesture, carries keep sub-scale precision.
    private boolean scrolling;
    private int anchorX, anchorY;
    private float carryX, carryY;
    private boolean flinging;
    private int flingLastX, flingLastY;
    private boolean tapConsumedByFlingStop;

    public NokreView(Context context) {
        super(context);
        imm = (InputMethodManager) context.getSystemService(Context.INPUT_METHOD_SERVICE);
        a11yManager =
                (AccessibilityManager) context.getSystemService(Context.ACCESSIBILITY_SERVICE);
        scroller = new OverScroller(context);
        gestures = new GestureDetector(context, new GestureListener());
        gestures.setIsLongpressEnabled(false); // nokre has no long-press semantics
        setFocusable(true);
        setFocusableInTouchMode(true);
        getHolder().addCallback(this);
        if (!nativeBoot()) throw new IllegalStateException("nokre boot failed");
        // The locale service read its boot tag inside nativeBoot. Report
        // again here because an OS locale change recreates the Activity —
        // a new view over the same app — and that recreate is the only
        // notification the manifest's configChanges list leaves us. The
        // native side drops the report when the tag has not moved, so the
        // ordinary boot costs nothing.
        reportLocale();
    }

    // ---- frames ----

    void render() {
        if (!surfaceReady) return;
        nativeRender(logicalW, logicalH, safeBottom, scale);
    }

    private void maybeRender() {
        if (nativeWantsFrame()) render();
    }

    private void inputChanged() {
        syncKeyboard();
        maybeRender();
    }

    /** The system back — Android's gesture or button, routed by the
     *  Activity. Returns false when there was no screen to go back to,
     *  which is the Activity's cue to finish as it otherwise would.
     *
     *  This is Android's whole share of the back gesture: the OS owns
     *  both screen edges and hands over a decision, where iOS hands the
     *  shell a drag and lets core run its own threshold. */
    boolean handleBack() {
        boolean consumed = nativeBack();
        if (consumed) inputChanged();
        return consumed;
    }

    /** Called from shell.c (main thread) for out-of-stream dirty marks:
     *  a11y actions and worker deliveries mutate app state without a
     *  shell event — the iOS nokre_shell_request_frame twin. */
    void requestRenderFromNative() {
        inputChanged();
    }

    void setSafeBottomPx(int px) {
        int logical = px / scale;
        if (safeBottom != logical) {
            safeBottom = logical;
            render();
        }
    }

    void reportAppearance(boolean dark) {
        nativeAppearance(dark);
        maybeRender();
    }

    /** Asks the native side to re-read the device locale and tell the app
     *  if it moved (src/services/locale/locale.h). No maybeRender() twin:
     *  the repaint, if the tag changed, is requested through the pipe
     *  like every other out-of-stream mark. */
    void reportLocale() {
        nativeLocale();
    }

    /** The device locale as a BCP 47 tag, called back from shell.c.
     *  Configuration's LocaleList rather than Locale.getDefault(): it
     *  honors the Android 13 per-app language override, which is what
     *  this app's own resources — and therefore the user's expectation —
     *  already follow. An empty list answers null; the contract's
     *  "unknown" is the empty tag, and inventing a language is not the
     *  shell's decision. UTF-8 bytes, never GetStringUTFChars (see
     *  nativeText in shell.c). */
    byte[] localeTag() {
        LocaleList locales = getResources().getConfiguration().getLocales();
        if (locales.isEmpty()) return null;
        return locales.get(0).toLanguageTag().getBytes(StandardCharsets.UTF_8);
    }

    void windowFocus(boolean focused) {
        nativeWindowFocus(focused);
    }

    /** A deep link the Activity received (App Link intent). The native
     *  side routes it to the app's handler and requests a repaint through
     *  the pipe, so a link that lands before the surface is ready still
     *  paints once the app boots. */
    void deepLink(String url) {
        if (url == null) return;
        nativeDeepLink(url.getBytes(StandardCharsets.UTF_8));
    }

    /** An oauth flow ended (NokreOAuth): the redirect URL arrived, or the
     *  user backed out of the Custom Tab. The native side routes it to
     *  the app's handler and requests a repaint through the pipe, the
     *  deep-link path's shape. */
    void authResult(int status, byte[] utf8) {
        nativeAuthResult(status, utf8);
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        // surfaceChanged always follows with the real size.
    }

    @Override
    public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
        // Integer scale (125% → 1, 150% → 2 — the Windows/web policy) so
        // glyphs never resample; logical is the ceiling so the frame
        // covers the buffer and the remainder crops at the edge.
        scale = Math.max(1, Math.round(getResources().getDisplayMetrics().density));
        logicalW = (width + scale - 1) / scale;
        logicalH = (height + scale - 1) / scale;
        nativeSetSurface(holder.getSurface());
        surfaceReady = true;
        render();
    }

    @Override
    public void surfaceDestroyed(SurfaceHolder holder) {
        surfaceReady = false;
        nativeSetSurface(null);
    }

    // ---- touch ----

    // A gesture core claimed at touch-down (nativeWantsPointerStream):
    // its whole life is forwarded raw and the GestureDetector never sees
    // it, so tap detection, scrolling and flings are untouched for
    // everything else. Only fixed chrome with nothing scrollable beneath
    // it is ever claimed, which is why bypassing the detector here costs
    // no arbitration.
    private boolean streamingPointer;

    @Override
    public boolean onTouchEvent(MotionEvent event) {
        int action = event.getActionMasked();
        int x = (int) (event.getX() / scale), y = (int) (event.getY() / scale);
        if (action == MotionEvent.ACTION_DOWN && nativeWantsPointerStream(x, y)) {
            // A fling still running is halted here, because the detector
            // — which normally does it in onDown — never sees a claimed
            // gesture. Unlike the detector's version this does not also
            // swallow the press: core claims only fixed chrome with
            // nothing scrollable beneath it, so the finger landed where
            // the user aimed rather than on whatever drifted under it
            // (the iOS pressDrag exemption, same reasoning).
            if (flinging) {
                scroller.forceFinished(true);
                flinging = false;
                endScrollGesture();
            }
            streamingPointer = true;
            nativePointer(x, y, P_DOWN);
            inputChanged();
            return true;
        }
        if (streamingPointer) {
            switch (action) {
                case MotionEvent.ACTION_MOVE:
                    nativePointer(x, y, P_MOVE);
                    break;
                case MotionEvent.ACTION_UP:
                    streamingPointer = false;
                    nativePointer(x, y, P_UP);
                    break;
                case MotionEvent.ACTION_CANCEL:
                    streamingPointer = false;
                    nativePointer(x, y, P_CANCEL);
                    break;
                default:
                    return true;
            }
            inputChanged();
            return true;
        }
        gestures.onTouchEvent(event);
        if ((action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL)
                && scrolling && !flinging) {
            endScrollGesture();
        }
        return true;
    }

    private final class GestureListener extends GestureDetector.SimpleOnGestureListener {
        @Override
        public boolean onDown(MotionEvent e) {
            // A touch during a fling stops the fling, like a real scroll
            // view — and must not also activate whatever it lands on
            // (the iOS shouldReceiveTouch refusal).
            tapConsumedByFlingStop = flinging;
            if (flinging) {
                scroller.forceFinished(true);
                flinging = false;
                endScrollGesture();
            }
            return true;
        }

        @Override
        public boolean onSingleTapUp(MotionEvent e) {
            if (tapConsumedByFlingStop) return true;
            nativeTap((int) (e.getX() / scale), (int) (e.getY() / scale));
            inputChanged();
            return true;
        }

        @Override
        public boolean onScroll(MotionEvent e1, MotionEvent e2, float dx, float dy) {
            // GestureDetector's distances are previous − current: a
            // finger moving up yields positive dy, and a positive delta
            // scrolls the content down — the feeder convention shared by
            // every touch shell.
            if (!scrolling) {
                scrolling = true;
                carryX = 0;
                carryY = 0;
                anchorX = (int) (e1.getX() / scale);
                anchorY = (int) (e1.getY() / scale);
                // BEGIN locks core's routing to the scrollers under the
                // anchor for the whole gesture, momentum included.
                nativeScroll(anchorX, anchorY, 0, 0, SCROLL_BEGIN);
            }
            sendScrollDeltas(dx, dy);
            return true;
        }

        @Override
        public boolean onFling(MotionEvent e1, MotionEvent e2, float vx, float vy) {
            if (!scrolling) return false;
            // Position advances along the velocity; negated, its deltas
            // keep the drag's sign. The span is wide enough that no
            // fling reaches an edge (the feeder-span argument).
            int span = 1 << 28;
            flingLastX = 0;
            flingLastY = 0;
            scroller.fling(0, 0, (int) -vx, (int) -vy, -span, span, -span, span);
            flinging = true;
            Choreographer.getInstance().postFrameCallback(flingFrame);
            return true;
        }
    }

    private final Choreographer.FrameCallback flingFrame = new Choreographer.FrameCallback() {
        @Override
        public void doFrame(long frameTimeNanos) {
            if (!flinging) return;
            scroller.computeScrollOffset();
            int x = scroller.getCurrX(), y = scroller.getCurrY();
            sendScrollDeltas(x - flingLastX, y - flingLastY);
            flingLastX = x;
            flingLastY = y;
            if (scroller.isFinished()) {
                flinging = false;
                endScrollGesture();
            } else {
                Choreographer.getInstance().postFrameCallback(this);
            }
        }
    };

    private void sendScrollDeltas(float dxPx, float dyPx) {
        // Physical px → logical with sub-scale remainders carried over,
        // so slow drags never truncate away.
        float fx = dxPx / scale + carryX;
        float fy = dyPx / scale + carryY;
        int dx = (int) fx;
        int dy = (int) fy;
        carryX = fx - dx;
        carryY = fy - dy;
        if (dx != 0 || dy != 0) {
            nativeScroll(anchorX, anchorY, dx, dy, SCROLL_MOVE);
            maybeRender();
        }
    }

    private void endScrollGesture() {
        if (!scrolling) return;
        scrolling = false;
        nativeScroll(anchorX, anchorY, 0, 0, SCROLL_END);
        maybeRender();
    }

    // ---- hardware keyboard ----

    private static int mapKey(int keyCode) {
        switch (keyCode) {
            case KeyEvent.KEYCODE_TAB: return KEY_TAB;
            case KeyEvent.KEYCODE_ENTER:
            case KeyEvent.KEYCODE_NUMPAD_ENTER: return KEY_ENTER;
            case KeyEvent.KEYCODE_SPACE: return KEY_SPACE;
            case KeyEvent.KEYCODE_ESCAPE: return KEY_ESCAPE;
            case KeyEvent.KEYCODE_DEL: return KEY_BACKSPACE;
            case KeyEvent.KEYCODE_FORWARD_DEL: return KEY_DELETE;
            case KeyEvent.KEYCODE_DPAD_LEFT: return KEY_LEFT;
            case KeyEvent.KEYCODE_DPAD_RIGHT: return KEY_RIGHT;
            case KeyEvent.KEYCODE_DPAD_UP: return KEY_UP;
            case KeyEvent.KEYCODE_DPAD_DOWN: return KEY_DOWN;
            case KeyEvent.KEYCODE_MOVE_HOME: return KEY_HOME;
            case KeyEvent.KEYCODE_MOVE_END: return KEY_END;
            case KeyEvent.KEYCODE_PAGE_UP: return KEY_PAGE_UP;
            case KeyEvent.KEYCODE_PAGE_DOWN: return KEY_PAGE_DOWN;
            default: return 0;
        }
    }

    private static int mapMods(int metaState) {
        int mods = 0;
        if ((metaState & KeyEvent.META_SHIFT_ON) != 0) mods |= MOD_SHIFT;
        if ((metaState & KeyEvent.META_CTRL_ON) != 0) mods |= MOD_CTRL;
        if ((metaState & KeyEvent.META_ALT_ON) != 0) mods |= MOD_ALT;
        if ((metaState & KeyEvent.META_META_ON) != 0) mods |= MOD_META;
        return mods;
    }

    @Override
    public boolean onKeyDown(int keyCode, KeyEvent event) {
        // Mid-composition the IME owns every key (the iOS bargain).
        if (composing.length() > 0) return super.onKeyDown(keyCode, event);
        int key = mapKey(keyCode);
        // Space is both a control key and a character, so it goes down one
        // leg per press (shell.h): the text path below while a field has
        // focus, a key everywhere else, where it is activation.
        if (key == KEY_SPACE && nativeWantsTextInput()) key = 0;
        if (key != 0) {
            nativeKey(key, mapMods(event.getMetaState()));
            inputChanged();
            return true;
        }
        int uni = event.getUnicodeChar(event.getMetaState());
        if (uni >= 32 && (uni & KeyCharacterMap.COMBINING_ACCENT) == 0) {
            nativeText(new String(Character.toChars(uni)).getBytes(StandardCharsets.UTF_8));
            inputChanged();
            return true;
        }
        return super.onKeyDown(keyCode, event);
    }

    // ---- software keyboard + IME ----

    private void syncKeyboard() {
        boolean wants = nativeWantsTextInput();
        if (wants) {
            if (!hasFocus()) requestFocus();
            if (!keyboardShown) {
                keyboardShown = true;
                imm.restartInput(this);
            }
            // Repeated shows are no-ops; keeping the call here re-raises
            // the keyboard while an editable stays focused, matching the
            // first-responder behavior of the iOS shell.
            imm.showSoftInput(this, 0);
        } else if (keyboardShown) {
            keyboardShown = false;
            composing.setLength(0);
            imm.hideSoftInputFromWindow(getWindowToken(), 0);
        }
    }

    @Override
    public boolean onCheckIsTextEditor() {
        return nativeWantsTextInput();
    }

    @Override
    public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
        // The keyboard gets no document context — the connection's world
        // is only the in-progress composition, so every "smart" mutation
        // must be off or typing stops being faithful (the bargain every
        // shell makes).
        outAttrs.inputType = EditorInfo.TYPE_CLASS_TEXT
                | EditorInfo.TYPE_TEXT_FLAG_NO_SUGGESTIONS;
        outAttrs.imeOptions = EditorInfo.IME_ACTION_NONE | EditorInfo.IME_FLAG_NO_FULLSCREEN
                | EditorInfo.IME_FLAG_NO_EXTRACT_UI;
        composing.setLength(0);
        return new NokreInputConnection();
    }

    private final class NokreInputConnection extends BaseInputConnection {
        NokreInputConnection() {
            super(NokreView.this, true);
        }

        @Override
        public boolean setComposingText(CharSequence text, int newCursorPosition) {
            String s = text.toString();
            if (s.isEmpty() && composing.length() > 0) {
                composing.setLength(0);
                nativeImeCancel();
            } else {
                composing.setLength(0);
                composing.append(s);
                byte[] utf8 = s.getBytes(StandardCharsets.UTF_8);
                // Caret at the end of the composition — where Android
                // IMEs keep it (newCursorPosition is relative placement
                // of the *next* commit, not a caret inside the text).
                nativeImeUpdate(utf8, utf8.length);
            }
            inputChanged();
            return true;
        }

        @Override
        public boolean commitText(CharSequence text, int newCursorPosition) {
            String s = text.toString();
            if (composing.length() > 0) {
                composing.setLength(0);
                nativeImeCommit(s.getBytes(StandardCharsets.UTF_8));
            } else if (s.equals("\n")) {
                // The software keyboard's return key arrives as text.
                nativeKey(KEY_ENTER, 0);
            } else if (!s.isEmpty()) {
                nativeText(s.getBytes(StandardCharsets.UTF_8));
            }
            inputChanged();
            return true;
        }

        @Override
        public boolean finishComposingText() {
            // InputConnection semantics: finishing commits (like
            // UITextInput's unmark, unlike AppKit's cancel).
            if (composing.length() > 0) {
                byte[] utf8 = composing.toString().getBytes(StandardCharsets.UTF_8);
                composing.setLength(0);
                nativeImeCommit(utf8);
                inputChanged();
            }
            return true;
        }

        @Override
        public boolean setComposingRegion(int start, int end) {
            // There is no committed text to re-compose over; the value
            // lives in core (shells may not know it).
            return true;
        }

        @Override
        public boolean deleteSurroundingText(int beforeLength, int afterLength) {
            if (composing.length() > 0) return true; // the IME edits its own composition
            for (int i = 0; i < beforeLength; i++) nativeKey(KEY_BACKSPACE, 0);
            // afterLength deletes forward of the caret; with no document
            // context the caret is at the end of what the IME can see,
            // so there is nothing forward to eat.
            inputChanged();
            return true;
        }

        @Override
        public boolean sendKeyEvent(KeyEvent event) {
            if (event.getAction() == KeyEvent.ACTION_DOWN) {
                onKeyDown(event.getKeyCode(), event);
            }
            return true;
        }

        // No document context, by design (see onCreateInputConnection).
        @Override
        public CharSequence getTextBeforeCursor(int n, int flags) {
            return "";
        }

        @Override
        public CharSequence getTextAfterCursor(int n, int flags) {
            return "";
        }

        @Override
        public CharSequence getSelectedText(int flags) {
            return null;
        }
    }

    // ---- clipboard (called from shell.c's nokre_shell_write_clipboard) ----

    void writeClipboard(byte[] utf8) {
        ClipboardManager clipboard =
                (ClipboardManager) getContext().getSystemService(Context.CLIPBOARD_SERVICE);
        if (clipboard == null) return;
        clipboard.setPrimaryClip(
                ClipData.newPlainText("", new String(utf8, StandardCharsets.UTF_8)));
    }

    // ---- open_url (called from shell.c's nokre_open_url_open) ----

    void openUrl(byte[] utf8) {
        // ACTION_VIEW to the default handler — the browser for https,
        // the mail app for mailto. The scheme allowlist already ran on
        // the Zig side; what can still fail here is a device with no
        // handler at all (ActivityNotFoundException), and fire-and-forget
        // has no error lane, so that is swallowed like a failed xdg-open.
        try {
            getContext().startActivity(
                    new Intent(Intent.ACTION_VIEW, Uri.parse(new String(utf8, StandardCharsets.UTF_8))));
        } catch (ActivityNotFoundException ignored) {
        }
    }

    // ---- share (called from shell.c's nokre_share_show) ----

    void showShare(byte[] utf8) {
        // ACTION_SEND behind the system chooser, so the user picks from
        // everything installed rather than whatever won the last
        // "always" — the sheet is the user's (share.h). The caps
        // already ran on the Zig side; a device with no send handler at
        // all still shows an (empty) chooser, and fire-and-forget has
        // no error lane, so the catch mirrors openUrl's.
        Intent send = new Intent(Intent.ACTION_SEND)
                .setType("text/plain")
                .putExtra(Intent.EXTRA_TEXT, new String(utf8, StandardCharsets.UTF_8));
        try {
            getContext().startActivity(Intent.createChooser(send, null));
        } catch (ActivityNotFoundException ignored) {
        }
    }

    // ---- accessibility (semantic snapshot → AccessibilityNodeInfo) ----

    private static final class A11yNode {
        long id;
        int role;
        String label, value;
        int x, y, w, h;
        int parent;
        boolean focusable, focused, disabled, modal, clickable, busy;
        int checked, selected, headingLevel;
    }

    private final ArrayList<A11yNode> a11yNodes = new ArrayList<>();
    private boolean a11yDirty = true;
    private boolean[] a11yExposed = new boolean[0];
    private int a11yFocusedVirtualId = Integer.MIN_VALUE;
    // Core's focused node in the last fill, and the one TalkBack's
    // cursor was last steered to — kept apart so a fill reporting the
    // same focus does not re-fire the event.
    private long a11yFillFocusId;
    private long a11yFollowedFocusId;
    private final A11yProvider a11yProvider = new A11yProvider();

    @Override
    public AccessibilityNodeProvider getAccessibilityNodeProvider() {
        return a11yProvider;
    }

    /** Called from shell.c after a frame renders while the snapshot may
     *  be stale — the iOS a11yInvalidate twin. */
    void a11yChanged() {
        a11yDirty = true;
        if (a11yManager.isEnabled()) {
            sendAccessibilityEvent(AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED);
            a11yFollowCoreFocus();
        }
    }

    /** Steers the TalkBack cursor when core moved its own focus
     *  (keyboard navigation, a dialog opening) — what the AccessKit
     *  shells get from the tree update's focus id. Routed through the
     *  provider's ACTION_ACCESSIBILITY_FOCUS plumbing so the
     *  highlight, the event, and the focus ring stay one code path;
     *  the plumbing's echo into core is a no-op there (focus already
     *  stands where core put it). */
    private void a11yFollowCoreFocus() {
        a11yRefresh();
        if (a11yFillFocusId == a11yFollowedFocusId) return;
        a11yFollowedFocusId = a11yFillFocusId;
        for (int i = 0; i < a11yNodes.size(); i++) {
            if (a11yNodes.get(i).id != a11yFillFocusId) continue;
            if (a11yExposed[i] && i != a11yFocusedVirtualId) {
                a11yProvider.performAction(
                        i, AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS, null);
            }
            return;
        }
    }

    /** shell.c fill callbacks (nativeA11yFill walks the snapshot). */
    void a11yBegin(int count, long focusId) {
        a11yNodes.clear();
        a11yNodes.ensureCapacity(count);
        a11yFillFocusId = focusId;
    }

    void a11yNode(long id, int role, byte[] label, byte[] value, int x, int y, int w, int h,
            int parent, boolean focusable, boolean focused, boolean disabled, boolean modal,
            boolean clickable, int checked, int selected, int headingLevel, boolean busy) {
        A11yNode n = new A11yNode();
        n.id = id;
        n.role = role;
        n.label = label == null ? null : new String(label, StandardCharsets.UTF_8);
        n.value = value == null ? null : new String(value, StandardCharsets.UTF_8);
        n.x = x;
        n.y = y;
        n.w = w;
        n.h = h;
        n.parent = parent;
        n.focusable = focusable;
        n.focused = focused;
        n.disabled = disabled;
        n.modal = modal;
        n.clickable = clickable;
        n.checked = checked;
        n.selected = selected;
        n.headingLevel = headingLevel;
        n.busy = busy;
        a11yNodes.add(n);
    }

    private void a11yRefresh() {
        if (!a11yDirty) return;
        a11yDirty = false;
        nativeA11yFill();
        // A modal overlay makes everything outside it inert; expose only
        // the topmost modal's subtree, like the core input path and
        // every other shell's bridge.
        int modal = -1;
        for (int i = 0; i < a11yNodes.size(); i++) {
            if (a11yNodes.get(i).modal) modal = i;
        }
        a11yExposed = new boolean[a11yNodes.size()];
        for (int i = 0; i < a11yNodes.size(); i++) {
            A11yNode n = a11yNodes.get(i);
            if (n.role == ROLE_DOCUMENT) continue;
            if (!n.focusable && !n.clickable && n.label == null && n.value == null) continue;
            if (modal >= 0) {
                int p = i;
                while (p >= 0 && p != modal) p = a11yNodes.get(p).parent;
                if (p != modal) continue;
            }
            a11yExposed[i] = true;
        }
    }

    private static String a11yClassName(int role) {
        switch (role) {
            case ROLE_BUTTON:
            case ROLE_LINK: return "android.widget.Button";
            case ROLE_TOGGLE: return "android.widget.ToggleButton";
            case ROLE_CHECKBOX: return "android.widget.CheckBox";
            case ROLE_OPTION: return "android.widget.RadioButton";
            case ROLE_TEXT_FIELD:
            case ROLE_MULTILINE_TEXT_FIELD:
            case ROLE_PASSWORD_FIELD: return "android.widget.EditText";
            case ROLE_IMAGE: return "android.widget.ImageView";
            default: return "android.view.View";
        }
    }

    private final class A11yProvider extends AccessibilityNodeProvider {
        @Override
        public AccessibilityNodeInfo createAccessibilityNodeInfo(int virtualViewId) {
            a11yRefresh();
            if (virtualViewId == HOST_VIEW_ID) {
                AccessibilityNodeInfo info = AccessibilityNodeInfo.obtain(NokreView.this);
                onInitializeAccessibilityNodeInfo(info);
                for (int i = 0; i < a11yExposed.length; i++) {
                    if (a11yExposed[i]) info.addChild(NokreView.this, i);
                }
                return info;
            }
            if (virtualViewId < 0 || virtualViewId >= a11yNodes.size()
                    || !a11yExposed[virtualViewId]) {
                return null;
            }
            A11yNode n = a11yNodes.get(virtualViewId);
            AccessibilityNodeInfo info =
                    AccessibilityNodeInfo.obtain(NokreView.this, virtualViewId);
            info.setPackageName(getContext().getPackageName());
            info.setClassName(a11yClassName(n.role));
            info.setParent(NokreView.this);
            info.setVisibleToUser(true);
            info.setEnabled(!n.disabled);
            // TalkBack has no busy state to read, and "disabled" alone
            // would say the control is unavailable rather than working.
            // A state description is the framework's own slot for the
            // words a state is announced with; below API 30 there is no
            // such slot, and the node stays merely disabled.
            if (n.busy && Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                info.setStateDescription("in progress");
            }
            // Flat list under the host, the iOS element-list shape —
            // TalkBack reads document order, which the snapshot is in.
            int[] loc = new int[2];
            getLocationOnScreen(loc);
            info.setBoundsInScreen(new Rect(loc[0] + n.x * scale, loc[1] + n.y * scale,
                    loc[0] + (n.x + n.w) * scale, loc[1] + (n.y + n.h) * scale));
            if (n.label != null) info.setContentDescription(n.label);
            if (n.value != null) {
                info.setText(n.value);
            }
            if (n.checked >= 0) {
                info.setCheckable(true);
                info.setChecked(n.checked == 1);
            }
            if (n.selected == 1) info.setSelected(true);
            if (n.headingLevel > 0) info.setHeading(true);
            if (n.clickable) {
                info.setClickable(true);
                info.addAction(AccessibilityNodeInfo.ACTION_CLICK);
            }
            if (n.focusable) info.setFocusable(true);
            if (virtualViewId == a11yFocusedVirtualId) {
                info.setAccessibilityFocused(true);
                info.addAction(AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS);
            } else {
                info.addAction(AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS);
            }
            return info;
        }

        @Override
        public boolean performAction(int virtualViewId, int action, Bundle arguments) {
            if (virtualViewId == HOST_VIEW_ID) {
                return performAccessibilityAction(action, arguments);
            }
            a11yRefresh();
            if (virtualViewId < 0 || virtualViewId >= a11yNodes.size()) return false;
            A11yNode n = a11yNodes.get(virtualViewId);
            switch (action) {
                case AccessibilityNodeInfo.ACTION_CLICK:
                    if (n.clickable) {
                        nativeA11yAction(n.id, A11Y_ACTION_CLICK);
                    } else if (n.focusable) {
                        nativeA11yAction(n.id, A11Y_ACTION_FOCUS);
                    } else {
                        return false;
                    }
                    inputChanged();
                    return true;
                case AccessibilityNodeInfo.ACTION_ACCESSIBILITY_FOCUS:
                    a11yFocusedVirtualId = virtualViewId;
                    sendVirtualEvent(virtualViewId,
                            AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUSED);
                    // Keep nokre's focus ring under the TalkBack cursor,
                    // matching every other shell's bridge.
                    if (n.focusable) {
                        nativeA11yAction(n.id, A11Y_ACTION_FOCUS);
                        inputChanged();
                    }
                    return true;
                case AccessibilityNodeInfo.ACTION_CLEAR_ACCESSIBILITY_FOCUS:
                    if (a11yFocusedVirtualId == virtualViewId) {
                        a11yFocusedVirtualId = Integer.MIN_VALUE;
                    }
                    sendVirtualEvent(virtualViewId,
                            AccessibilityEvent.TYPE_VIEW_ACCESSIBILITY_FOCUS_CLEARED);
                    return true;
                default:
                    return false;
            }
        }

        private void sendVirtualEvent(int virtualViewId, int type) {
            if (!a11yManager.isEnabled() || getParent() == null) return;
            AccessibilityEvent event = AccessibilityEvent.obtain(type);
            event.setPackageName(getContext().getPackageName());
            event.setSource(NokreView.this, virtualViewId);
            getParent().requestSendAccessibilityEvent(NokreView.this, event);
        }
    }
}
