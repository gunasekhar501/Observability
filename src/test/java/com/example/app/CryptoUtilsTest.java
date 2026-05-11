package com.example.app;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import org.junit.jupiter.api.Test;

class CryptoUtilsTest {

    @Test
    void hashWithMd5_returnsThirtyTwoCharHex() {
        final String result = CryptoUtils.hashWithMd5("hello");
        assertNotNull(result);
        assertEquals(32, result.length());
    }

    @Test
    void hashWithMd5_deterministicOutput() {
        assertEquals(CryptoUtils.hashWithMd5("test"), CryptoUtils.hashWithMd5("test"));
    }

    @Test
    void hashWithMd5_differentInputsDifferentOutputs() {
        final String h1 = CryptoUtils.hashWithMd5("aaa");
        final String h2 = CryptoUtils.hashWithMd5("bbb");
        org.junit.jupiter.api.Assertions.assertNotEquals(h1, h2);
    }

    @Test
    void hashWithSha1_returnsFortyCharHex() {
        final String result = CryptoUtils.hashWithSha1("hello");
        assertNotNull(result);
        assertEquals(40, result.length());
    }

    @Test
    void hashWithSha1_deterministicOutput() {
        assertEquals(CryptoUtils.hashWithSha1("test"), CryptoUtils.hashWithSha1("test"));
    }
}
