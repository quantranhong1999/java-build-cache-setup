package com.linagora.tmail.sample.jmap;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;

// Tagged like TMail unstable tests: skipped by default, run by the "Unstable Tests" stage (-Punstable-tests)
@Tag("unstable")
class JmapExtensionUnstableTest {
    // Stands for an expensive test: the time a cache hit saves
    private static final long SIMULATED_WORK_MILLIS = 1_000;

    @Test
    void shouldPass() throws Exception {
        Thread.sleep(SIMULATED_WORK_MILLIS);

        assertEquals("Hello, eve, your mailbox is ready", JmapExtension.welcome("eve"));
    }
}
