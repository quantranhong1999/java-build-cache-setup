package com.linagora.tmail.sample.it;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

import com.linagora.tmail.sample.app.DistributedServer;

// Like TMail's JMAP integration tests: slow, and depending on (almost) every module
class JmapIntegrationTest {
    // Stands for an expensive test: the time a cache hit saves
    private static final long SIMULATED_WORK_MILLIS = 4_000;

    @Test
    void bannerShouldWelcomeTheAdmin() throws Exception {
        Thread.sleep(SIMULATED_WORK_MILLIS);

        assertEquals("Hello, admin, your mailbox is ready | Hello, labels", DistributedServer.banner());
    }
}
