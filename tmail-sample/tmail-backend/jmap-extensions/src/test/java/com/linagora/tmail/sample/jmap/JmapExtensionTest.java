package com.linagora.tmail.sample.jmap;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

class JmapExtensionTest {
    // Stands for an expensive test: the time a cache hit saves
    private static final long SIMULATED_WORK_MILLIS = 2_000;

    @Test
    void shouldPass() throws Exception {
        Thread.sleep(SIMULATED_WORK_MILLIS);

        assertEquals("Hello, bob, your mailbox is ready", JmapExtension.welcome("bob"));
    }
}
