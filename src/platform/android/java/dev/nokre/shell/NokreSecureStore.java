// Keystore backend for the secure_store service — the Android leg of
// docs/internals/secure_store.md ("Android (Keystore)"). A per-namespace
// AES-256-GCM key lives in the AndroidKeyStore; the ciphertext
// (iv ‖ tag+ct), base64, lives in an app-private SharedPreferences file.
// The OS owns both the key and the file: this class holds no plaintext
// and no state between calls, matching the stateless-native charter the
// C/ObjC/Win32 legs also keep. Called from android.c over JNI, on the
// main thread, synchronously (a boot read decides the first screen).
//
// Static and context-free by design: the store is process-global like
// the secret it holds. The application context is handed in once by
// NokreActivity before the app boots (attach), so no view/activity
// plumbing reaches a boot-time read inside build. The key is generated
// lazily on the first set — an app that never writes creates nothing.
//
// Deliberately no androidx.security EncryptedSharedPreferences: that is
// a Jetpack dependency, and nokre's Android shell carries none. The
// primitive it wraps — a Keystore AES-GCM key over private prefs — is
// exactly what this rolls by hand, no more.
package dev.nokre.shell;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;

import java.security.KeyStore;
import java.util.Set;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

public final class NokreSecureStore {
    private static final String KEYSTORE = "AndroidKeyStore";
    private static final String TRANSFORM = "AES/GCM/NoPadding";
    private static final int GCM_IV_BYTES = 12; // AndroidKeyStore GCM IV length
    private static final int GCM_TAG_BITS = 128;

    // The application context: process-global, outlives every activity,
    // so holding it statically leaks nothing.
    private static Context appContext;

    private NokreSecureStore() {}

    /** Handed in by NokreActivity before the app boots, so a boot-time read
     *  inside build has a context without any view plumbing. */
    public static void attach(Context context) {
        appContext = context;
    }

    // Prefs file and Keystore alias are per-namespace. ns and key are
    // ASCII [a-z0-9._-] (Zig-validated): the key is a valid prefs key
    // verbatim, and the join needs no escaping.
    private static SharedPreferences prefs(String ns) {
        return appContext.getSharedPreferences("nokre.ss." + ns, Context.MODE_PRIVATE);
    }

    // The namespace's AES-256-GCM key, created on first use. No
    // user-authentication or unlocked-device requirement: boot reads work
    // whenever the app can run (the AfterFirstUnlockThisDeviceOnly
    // posture the Apple leg states), and per-key biometry is a refusal of
    // this service (docs/internals/secure_store.md, Refusals). GCM forces
    // a fresh random IV per encryption (setRandomizedEncryptionRequired
    // defaults true), so the IV is read back from the cipher, never set.
    private static SecretKey key(String ns) throws Exception {
        KeyStore ks = KeyStore.getInstance(KEYSTORE);
        ks.load(null);
        String alias = "nokre.ss." + ns;
        KeyStore.Entry entry = ks.getEntry(alias, null);
        if (entry instanceof KeyStore.SecretKeyEntry) {
            return ((KeyStore.SecretKeyEntry) entry).getSecretKey();
        }
        KeyGenerator gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE);
        gen.init(new KeyGenParameterSpec.Builder(alias,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build());
        return gen.generateKey();
    }

    /** Value bytes, or null if absent; throws on a Keystore/crypto
     *  failure (android.c maps a thrown exception to UNAVAILABLE). An
     *  empty value round-trips as a zero-length array, never null. */
    public static byte[] get(String ns, String key) throws Exception {
        String stored = prefs(ns).getString(key, null);
        if (stored == null) return null;
        byte[] blob = Base64.decode(stored, Base64.NO_WRAP);
        if (blob.length < GCM_IV_BYTES) throw new IllegalStateException("corrupt entry");
        Cipher cipher = Cipher.getInstance(TRANSFORM);
        cipher.init(Cipher.DECRYPT_MODE, key(ns),
                new GCMParameterSpec(GCM_TAG_BITS, blob, 0, GCM_IV_BYTES));
        return cipher.doFinal(blob, GCM_IV_BYTES, blob.length - GCM_IV_BYTES);
    }

    /** Upsert; false on a Keystore/crypto/storage failure (→ UNAVAILABLE).
     *  commit(), not apply(): the write must be durable before returning,
     *  and its boolean is the outcome the sync contract reports. */
    public static boolean set(String ns, String key, byte[] value) {
        try {
            Cipher cipher = Cipher.getInstance(TRANSFORM);
            cipher.init(Cipher.ENCRYPT_MODE, key(ns));
            byte[] iv = cipher.getIV();
            byte[] ct = cipher.doFinal(value);
            byte[] blob = new byte[iv.length + ct.length];
            System.arraycopy(iv, 0, blob, 0, iv.length);
            System.arraycopy(ct, 0, blob, iv.length, ct.length);
            return prefs(ns).edit()
                    .putString(key, Base64.encodeToString(blob, Base64.NO_WRAP))
                    .commit();
        } catch (Exception e) {
            return false;
        }
    }

    /** Idempotent: deleting an absent key succeeds. false only on a real
     *  storage failure. The namespace's Keystore key is left in place —
     *  other entries share it, and an orphaned key is harmless. */
    public static boolean delete(String ns, String key) {
        try {
            return prefs(ns).edit().remove(key).commit();
        } catch (Exception e) {
            return false;
        }
    }

    /** The namespace's keys (order unspecified — Zig sorts), or null on
     *  failure. A fresh install returns an empty array, never null. */
    public static String[] list(String ns) {
        try {
            Set<String> keys = prefs(ns).getAll().keySet();
            return keys.toArray(new String[0]);
        } catch (Exception e) {
            return null;
        }
    }
}
