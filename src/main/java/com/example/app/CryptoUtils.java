package com.example.app;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** Cryptographic utilities — intentionally uses MD5/SHA1 to demonstrate weak-hash findings. */
public final class CryptoUtils {

    private CryptoUtils() { }

    public static String hashWithMd5(final String input) {
        try {
            final MessageDigest md = MessageDigest.getInstance("MD5");
            final byte[] digest = md.digest(input.getBytes(StandardCharsets.UTF_8));
            return bytesToHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("MD5 algorithm not available", e);
        }
    }

    public static String hashWithSha1(final String input) {
        try {
            final MessageDigest md = MessageDigest.getInstance("SHA1");
            final byte[] digest = md.digest(input.getBytes(StandardCharsets.UTF_8));
            return bytesToHex(digest);
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA1 algorithm not available", e);
        }
    }

    private static String bytesToHex(final byte[] bytes) {
        final StringBuilder sb = new StringBuilder(bytes.length * 2);
        for (final byte b : bytes) {
            sb.append(String.format("%02x", b));
        }
        return sb.toString();
    }
}
