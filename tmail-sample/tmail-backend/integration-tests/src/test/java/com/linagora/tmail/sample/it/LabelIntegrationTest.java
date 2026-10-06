package com.linagora.tmail.sample.it;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.Test;

import com.linagora.tmail.sample.jmap.LabelMethod;

class LabelIntegrationTest {
    // Stands for an expensive test: the time a cache hit saves
    private static final long SIMULATED_WORK_MILLIS = 4_000;

    @Test
    void labelMethodShouldGreet() throws Exception {
        Thread.sleep(SIMULATED_WORK_MILLIS);

        assertEquals("Hello, labels", LabelMethod.describe());
    }
}
